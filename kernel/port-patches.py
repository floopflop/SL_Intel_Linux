#!/usr/bin/python3 -I
"""Apply the Surface Laptop 7 (Intel) fixes to pristine kernel sources.
Usage: port-patches.py <src-root>   (src-root holds drivers/..., sound/... as fetched by build.sh)
Edits are anchor based so they survive line-number drift between stable releases."""
import sys, os
root = sys.argv[1]

def edit(rel, pairs):
    p = os.path.join(root, rel); s = open(p).read()
    for old, new in pairs:
        if s.count(old) != 1:
            sys.exit(f"{rel}: anchor found {s.count(old)}x, expected 1:\n{old[:120]}")
        s = s.replace(old, new)
    open(p, "w").write(s); print("patched", rel)

# ---- 1. SAM registry: MSHW0551 match + Intel group with battery/AC + ambient light sensor
edit("drivers/platform/surface/surface_aggregator_registry.c", [
("""	&ssam_node_hid_sam_keyboard,
	/* TODO: evaluate thermal sensors devices when we get a driver for that */
	NULL,
};
""", """	&ssam_node_hid_sam_keyboard,
	/* TODO: evaluate thermal sensors devices when we get a driver for that */
	NULL,
};

/* Devices for Surface Laptop 7 (Intel, MSHW0551): battery and AC are SAM devices here. */
static const struct software_node *ssam_node_group_sl7_intel[] = {
	&ssam_node_root,
	&ssam_node_bat_ac,
	&ssam_node_bat_main,
	&ssam_node_tmp_perf_profile_with_fan,
	&ssam_node_fan_speed,
	&ssam_node_hid_sam_keyboard,
	&ssam_node_hid_sam_sensors,
	NULL,
};
"""),
("""	/* Surface Laptop Go 1 */
	{ "MSHW0118", (unsigned long)ssam_node_group_slg1 },
""", """	/* Surface Laptop 7 (Intel) */
	{ "MSHW0551", (unsigned long)ssam_node_group_sl7_intel },

	/* Surface Laptop Go 1 */
	{ "MSHW0118", (unsigned long)ssam_node_group_slg1 },
"""),
])

# ---- 2. Webcam: proper 12 MHz external clock support (PLL multipliers 400 -> 640 on both PLLs)
edit("drivers/media/i2c/ov02c10.c", [
("#define OV02C10_MCLK\t\t\t19200000\n",
 "#define OV02C10_MCLK\t\t\t19200000\n#define OV02C10_MCLK_12MHZ\t\t12000000\n"),
("static const struct reg_sequence sensor_1928x1092_30fps_setting[] = {",
 """/*
 * The mode tables below are written for a 19.2 MHz external clock and set both
 * PLL feedback multipliers (PLL1/MIPI at 0x0304-0x0305, PLL2/system at
 * 0x0315-0x0316) to 400. With a 12 MHz clock the same VCO frequencies, and
 * therefore the same link frequency and frame rate, need a multiplier of
 * 400 * 19.2 / 12 = 640 on both PLLs. Nothing else in the tables depends on
 * the external clock.
 */
static const struct reg_sequence ov02c10_pll_12mhz[] = {
\t{0x0304, 0x02},
\t{0x0305, 0x80},
\t{0x0315, 0x02},
\t{0x0316, 0x80},
};

static const struct reg_sequence sensor_1928x1092_30fps_setting[] = {"""),
("\tstruct clk *img_clk;\n",
 "\tstruct clk *img_clk;\n\n\t/* External clock specific PLL settings, NULL for 19.2 MHz */\n\tconst struct reg_sequence *pll_regs;\n\tunsigned int pll_regs_len;\n"),
("""\tret = __v4l2_ctrl_handler_setup(ov02c10->sd.ctrl_handler);
\tif (ret)
\t\tgoto out;

\tret = cci_write(ov02c10->regmap, OV02C10_REG_STREAM_CONTROL, 1, NULL);""",
 """\tif (ov02c10->pll_regs) {
\t\tret = regmap_multi_reg_write(ov02c10->regmap, ov02c10->pll_regs,
\t\t\t\t\t     ov02c10->pll_regs_len);
\t\tif (ret) {
\t\t\tdev_err(ov02c10->dev, "failed to write PLL settings\\n");
\t\t\tgoto out;
\t\t}
\t}

\tret = __v4l2_ctrl_handler_setup(ov02c10->sd.ctrl_handler);
\tif (ret)
\t\tgoto out;

\tret = cci_write(ov02c10->regmap, OV02C10_REG_STREAM_CONTROL, 1, NULL);"""),
("""\tfreq = clk_get_rate(ov02c10->img_clk);
\tif (freq != OV02C10_MCLK)
\t\treturn dev_err_probe(ov02c10->dev, -EINVAL,
\t\t\t\t     "external clock %lu is not supported",
\t\t\t\t     freq);
""", """\tfreq = clk_get_rate(ov02c10->img_clk);
\tswitch (freq) {
\tcase OV02C10_MCLK:
\t\tbreak;
\tcase OV02C10_MCLK_12MHZ:
\t\tov02c10->pll_regs = ov02c10_pll_12mhz;
\t\tov02c10->pll_regs_len = ARRAY_SIZE(ov02c10_pll_12mhz);
\t\tbreak;
\tdefault:
\t\treturn dev_err_probe(ov02c10->dev, -EINVAL,
\t\t\t\t     "external clock %lu is not supported",
\t\t\t\t     freq);
\t}
"""),
])

# ---- 3. Audio: skip ACPI-declared SoundWire peripherals that never attach (ghost RT1320)
edit("sound/soc/sdw_utils/soc_sdw_utils.c", [
("""int asoc_sdw_parse_sdw_endpoints(struct device *dev,
				 struct asoc_sdw_mc_private *ctx,
""", """/*
 * Some BIOSes declare SoundWire peripherals that are not populated on the
 * board. The Surface Laptop 7 (Intel) declares two RT1320 amplifiers on link
 * 0 (same part and unique_id, different class_id), but only one ever answers
 * enumeration; the other stays SDW_SLAVE_UNATTACHED forever. Building such a
 * ghost into the DAI links produces duplicate DAI link names (probe fails
 * with -EEXIST/-ENOMEM) or stream prepare failures (-ENODATA). Detect ACPI
 * declared peripherals that are not attached so the caller can skip them.
 */
#define ASOC_SDW_GHOST_WAIT_MS	1500

struct asoc_sdw_adr_probe {
	u64 adr;
	bool attached;
};

static int asoc_sdw_adr_probe_fn(struct device *dev, void *data)
{
	struct asoc_sdw_adr_probe *probe = data;
	struct sdw_slave *slave;

	if (!is_sdw_slave(dev))
		return 0;

	slave = dev_to_sdw_dev(dev);

	if (slave->id.mfg_id != SDW_MFG_ID(probe->adr) ||
	    slave->id.part_id != SDW_PART_ID(probe->adr) ||
	    slave->id.class_id != SDW_CLASS_ID(probe->adr))
		return 0;

	/* 0xf is a wildcard in the _ADR unique_id field */
	if (SDW_UNIQUE_ID(probe->adr) != 0xf &&
	    slave->id.unique_id != SDW_UNIQUE_ID(probe->adr))
		return 0;

	/*
	 * The machine driver can probe while enumeration on a freshly
	 * started link is still in progress. Give an unattached peripheral
	 * a moment to show up before calling it a ghost.
	 */
	if (slave->status == SDW_SLAVE_UNATTACHED)
		wait_for_completion_timeout(&slave->enumeration_complete,
					    msecs_to_jiffies(ASOC_SDW_GHOST_WAIT_MS));

	if (slave->status != SDW_SLAVE_UNATTACHED)
		probe->attached = true;

	return 1;
}

static bool asoc_sdw_adr_is_attached(u64 adr)
{
	struct asoc_sdw_adr_probe probe = { .adr = adr, .attached = false };

	/* No matching device on the bus at all: change nothing */
	if (!bus_for_each_dev(&sdw_bus_type, NULL, &probe, asoc_sdw_adr_probe_fn))
		return true;

	return probe.attached;
}

/* Count ACPI-declared peripherals that never attached to the bus */
static int asoc_sdw_count_ghosts(struct snd_soc_acpi_mach_params *mach_params)
{
	const struct snd_soc_acpi_link_adr *adr_link;
	int ghosts = 0;
	int total = 0;
	int i;

	for (adr_link = mach_params->links; adr_link->num_adr; adr_link++) {
		for (i = 0; i < adr_link->num_adr; i++) {
			total++;
			if (!asoc_sdw_adr_is_attached(adr_link->adr_d[i].adr))
				ghosts++;
		}
	}

	/* Nothing attached at all: the bus is not up, don't guess */
	if (ghosts == total)
		return 0;

	return ghosts;
}

int asoc_sdw_parse_sdw_endpoints(struct device *dev,
				 struct asoc_sdw_mc_private *ctx,
"""),
("""	struct asoc_sdw_endpoint *soc_end = soc_ends;
	int num_dais = 0;
	int i, j;
	int ret;

	for (adr_link = mach_params->links; adr_link->num_adr; adr_link++) {
		int num_link_dailinks = 0;
""", """	struct asoc_sdw_endpoint *soc_end = soc_ends;
	int num_dais = 0;
	int amp_renum = 0;
	int ghosts;
	int i, j;
	int ret;

	ghosts = asoc_sdw_count_ghosts(mach_params);
	if (ghosts)
		dev_warn(dev, "%d SoundWire peripheral(s) declared in ACPI never attached, skipping them\\n",
			 ghosts);

	for (adr_link = mach_params->links; adr_link->num_adr; adr_link++) {
		int num_link_dailinks = 0;
"""),
("""			struct asoc_sdw_codec_info *codec_info;
			const char *codec_name;
			bool check_sdca = false;

			if (!adr_dev->name_prefix) {
				dev_err(dev, "codec 0x%llx does not have a name prefix\\n",
					adr_dev->adr);
				return -EINVAL;
			}

			codec_info = asoc_sdw_find_codec_info_part(adr_dev->adr);
			if (!codec_info)
				return -EINVAL;

""", """			struct asoc_sdw_codec_info *codec_info;
			const char *codec_name;
			const char *dev_prefix;
			bool check_sdca = false;

			if (!adr_dev->name_prefix) {
				dev_err(dev, "codec 0x%llx does not have a name prefix\\n",
					adr_dev->adr);
				return -EINVAL;
			}

			codec_info = asoc_sdw_find_codec_info_part(adr_dev->adr);
			if (!codec_info)
				return -EINVAL;

			if (ghosts && !asoc_sdw_adr_is_attached(adr_dev->adr)) {
				dev_warn(dev, "codec 0x%llx (%s) declared but not attached, skipping\\n",
					 adr_dev->adr, adr_dev->name_prefix);
				*num_devs -= adr_dev->num_endpoints;
				continue;
			}

			/*
			 * Amps are numbered "<prefix>-<n>" in ACPI order (see
			 * find_acpi_adr_device() in sof/intel/hda.c). When a ghost
			 * amp was dropped the remaining real amps may be numbered
			 * -2, -3, ... but asoc_sdw_rt_amp_spk_rtd_init() and the
			 * alsa-ucm speaker configs expect a dense -1, -2 sequence.
			 * Renumber attached amps in order; a no-op without ghosts.
			 */
			dev_prefix = adr_dev->name_prefix;
			if (ghosts && codec_info->is_amp) {
				size_t plen = strlen(codec_info->name_prefix);

				if (!strncmp(dev_prefix, codec_info->name_prefix, plen) &&
				    dev_prefix[plen] == '-') {
					dev_prefix = devm_kasprintf(dev, GFP_KERNEL, "%s-%d",
								    codec_info->name_prefix,
								    ++amp_renum);
					if (!dev_prefix)
						return -ENOMEM;
					if (strcmp(dev_prefix, adr_dev->name_prefix))
						dev_info(dev, "codec 0x%llx renumbered %s -> %s\\n",
							 adr_dev->adr, adr_dev->name_prefix,
							 dev_prefix);
				}
			}

"""),
("""				dev_dbg(dev, "Adding prefix %s for %s\\n",
					adr_dev->name_prefix, codec_name);

				soc_end->name_prefix = adr_dev->name_prefix;
""", """				dev_dbg(dev, "Adding prefix %s for %s\\n",
					dev_prefix, codec_name);

				soc_end->name_prefix = dev_prefix;
"""),
])
print("all patches applied")
# ---- 4. Webcam: IPU7 ISYS capture buffers are written by a DMA that does not snoop the CPU caches;
#         flush them around every DMA (stale 64-byte chunks of old frames otherwise trail moving objects)
edit("drivers/staging/media/ipu7/ipu7-isys-queue.c", [
("""	ivb->dma_addr = sg_dma_address(sg->sgl);

	return 0;
}
""", """	ivb->dma_addr = sg_dma_address(sg->sgl);

	return 0;
}

/*
 * The ISYS writes capture buffers through the IPU MMU without snooping the
 * CPU caches, and the buffers are only flushed once, when they are mapped.
 * Cache lines filled by the CPU from the previous frame in the same buffer
 * would otherwise survive the next DMA and be returned as stale data.
 */
static void ipu7_isys_buf_cache_sync(struct vb2_buffer *vb)
{
	struct ipu7_isys *isys = vb2_get_drv_priv(vb->vb2_queue);
	struct sg_table *sg = vb2_dma_sg_plane_desc(vb, 0);

	if (sg)
		ipu7_dma_sync_sgtable(isys->adev, sg);
}
"""),
("""	vb2_set_plane_payload(vb, 0, bytesperline * height);

	return 0;
}
""", """	vb2_set_plane_payload(vb, 0, bytesperline * height);

	/* Nothing stale may remain in the caches before the DMA fills the buffer. */
	ipu7_isys_buf_cache_sync(vb);

	return 0;
}

static void ipu7_isys_buf_finish(struct vb2_buffer *vb)
{
	/* Drop whatever the caches hold for the buffer now that the DMA is done. */
	ipu7_isys_buf_cache_sync(vb);
}
"""),
("""	.buf_prepare = ipu7_isys_buf_prepare,
	.buf_cleanup = ipu7_isys_buf_cleanup,""", """	.buf_prepare = ipu7_isys_buf_prepare,
	.buf_finish = ipu7_isys_buf_finish,
	.buf_cleanup = ipu7_isys_buf_cleanup,"""),
])
