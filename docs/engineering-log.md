<!-- Development log, kept verbatim. Paths such as webcam/tools/... and ipu7/... refer to the development tree this repository was distilled from; the shipped equivalents are listed in README.md. -->

# OV02C10 on Surface Laptop 7 (Intel): findings log

## 2026-10-27 baseline
- libcamera `cam` capture: 1928x1092, 18.78 fps (sensor PLLs tuned for 19.2 MHz, fed 12 MHz).
- ACPI (DSDT, \_SB_.PC00.I2C5.CAMF): _HID OVTI02C1, _CRS lists I2C 0x36 (sensor) AND 0x50
  (module EEPROM) at 400 kHz on I2C5 (Linux i2c-3). _DEP ICL0 (INT3472, GPIOs GPI5 pins 0x17/0x16,
  GPI0 pin 0x25). SSDB (108 bytes) has u32 12000000 at offset 0x56 = declared MCLK 12 MHz.
- Windows driver store: ov02c10.inf (Intel sensor driver, no sensor parameters in INF/registry),
  ov02c10_extension.inf "Surface Camera Front Extension" with OV02C10_MSHW0550_LNL.aiqb/.cpf and
  graph_settings_OV02C10_MSHW0550_LNL.bin; iacamera64 (IPU7 AVStream), iaisp64 (ISP, PCI 8086:645D).
- .aiqb (CPFF container, tools/cpff.py): general_data = 1928x1092, 10 bit. Records present:
  black_level, black_level_global, optics_and_mechanics, lens_shading_4x4 (+ratio),
  chromaticity_response, nvm_info, analog_gain_conversion, digital_gain, advanced_color_matrices,
  hdr, noise. Tuning project "MSFT_Lodgepole_LNL_OV02C10.IPU7X", IQStudio 24.40.
- graph settings blob: output streams NV12 1920x1080 @ 30 fps and 1280x720; sensor 1928x1092.
  => Windows uses the same sensor frame at 30 fps: the delta is purely the PLL for 12 MHz.
- Linux driver (7.2.11): PLL regs written: 0x0301=08 0x0303=06->05 0x0304=01 0x0305=e0->90
  0x0313=40 0x0316=90 0x031c=4f 0x3016=32 (2 lane); HTS 0x0474 VTS 0x0918 -> ~79.6 MHz SCLK @30fps.
  Measured 18.78 fps = 30 * 12/19.2 exactly, so the frame clock scales with MCLK (no fixed ref).

## 2026-10-27 PLL registers read back (dump_regs=1, after mode + 2-lane tables, 12 MHz MCLK)
    0x0300: 70 08 00 05 01 90 70 00
    0x0308: 00 10 00 05 01 68 00 05
    0x0310: 01 01 00 40 04 01 90 02
    0x0318: 03 01 01 00 4f 01 09 00
    timing: 3016=32 380c=04 380d=74 380e=09 380f=18 3808=07 3809=88 380a=04 380b=44 4800=64 4837=10
Both PLL feedback multipliers are 0x0190 = 400: PLL1 (MIPI) at 0x0304:0x0305, PLL2 (system/pixel
clock) at 0x0315:0x0316. Frame rate is governed by PLL2, which is why the earlier blind attempt on
0x0304/0x0305 alone changed nothing.

## Experiment 1: both multipliers 400 -> 640 (= 400 * 19.2/12)
    reg_override=0x0304=0x02,0x0305=0x80,0x0315=0x02,0x0316=0x80
Result: 30.05 fps (was 18.78), frames 1928x1092 SGRBG10 intact (no duplicated rows, coherent
image), only the usual single "Short packet discarded" at stream start. Same VCO frequencies as
the 19.2 MHz design, so link frequency (400 MHz) and all timing registers stay valid.
Implemented as ov02c10_pll_12mhz[] selected by clk_get_rate() in probe: ov02c10-12mhz-clock.patch.

## Module EEPROM (I2C 0x50, 16-bit addressing, powered via runtime PM 'on')
First 512 bytes: 16-byte header (01 06 00 00 0a 02 db 59 c0 67 0b 07 05 67 3d 28) then
shading-like planes: values ~0 at the optical centre rising to ~130 at edges, period 11 columns.
Full size/layout still to be read (eeprom 4096).

## Installed: driver with built-in 12 MHz PLL table -> 30.05 fps without any override parameter.
Module: ~/surface-sl7-patches/out/ov02c10.ko (also carries the reg_override/dump_regs debug knobs,
both off by default). Clean patch for upstream: ov02c10-12mhz-clock.patch (applies to v7.2.11).
EEPROM: >= 4096 bytes used (read ended mid-data), 16-byte header, shading-like region, 0xff gap,
second data region. Decode pending (needs 8192-byte read); only relevant for per-unit LSC tuning.

## 2026-10-27 colour tuning
- Stock libcamera 0.7.2 soft ISP: algorithms BlackLevel/Awb/Ccm/Adjust/Agc only, no lens shading,
  no CameraSensorHelper for ov02c10 (so AGC treats gain codes 16..248 as 16x..248x). Result: dark,
  flat, desaturated image (before.png).
- Tuning container (.aiqb, tools/cpff.py) decoded with own parser:
  * black_level: per-gain table 16378..16651 (16-bit units) = 64 DN at 10 bits -> blackLevel 4096.
  * advanced_color_matrices: 7 illuminants 2300/2745/2775/3606/4711/5929/6740 K, rows sum to 1.0.
  * lens_shading_4x4: header 46 B (u16 sets=6, channels=4, 63x47 at +16; set 0 chromaticity floats
    at +28), per set 4 grids Q5.11 (2048 = unity, min at centre) + 22-byte descriptor holding the
    next set's chromaticity. Channel order is the sensor's Bayer order Gr,R,B,Gb (grids 0 and 3
    agree to 0.015; red has the strongest falloff, corner gains R 4.2-5.2, G 3.9, B 3.7-4.0).
  * analog_gain_conversion record is empty; gain model taken from the kernel driver: code/16.
- Radial polynomial fit (libipa LscPolynomial, r normalised to frame corner, 16:9 geometry):
  RMS 0.02-0.04 gain units per channel. Generated tuning/ov02c10.yaml (tools/gen-ov02c10-tuning.py).
- libcamera patch (libcamera-0.7.2-lsc-ov02c10.patch): cschalle's soft-ISP lens shading + AWB
  8-bit statistics normalisation ported to 0.7.2 (4 hunks redone, 12P debayer variants added),
  plus CameraSensorHelperOv02c10 {blackLevel 4096, AnalogueGainLinear{1,0,0,16}}.
  RPMs: ~/rpmbuild (release 2.sl7). Install: tools/04-install-tuning.sh.

## Colour cast on first install (2.sl7): AWB disabled by double normalisation
First patched build gave R/G/B 127/129/56 (yellow-green) with IPASoftAwb logging gains 1/1/1 and
8890 K. Cause: cschalle's "Normalise statistics sums to 8 bits" fix is for 0.7.1; 0.7.2 already does
`sharedStats_->sum_ >>= sumShift_` in SwStatsCpu::finishFrame, so the ported hunk divided the sums a
second time, they fell below the black-level offset, were clamped and every gain came out 1.0.
Fix: dropped that part (swstats_cpu.cpp back to stock) -> build 3.sl7.
Also: LIBCAMERA_IPA_CONFIG_PATH is not an override in 0.7.2; use LIBCAMERA_SIMPLE_TUNING_FILE=<yaml>.

## 3.sl7: AWB works (R 1.05 / B 2.56, 3052 K) but LSC adds a blue-magenta cast + purple corners
Variants via LIBCAMERA_SIMPLE_TUNING_FILE: full 123/113/145, no-CCM 124/120/135, no-LSC 81/80/78
(neutral, darker). So the cast and the extra brightness come from LSC. Reason: the soft ISP takes
AWB/AE statistics from the raw frame (pre-LSC), so per-channel differences in the grids' frame means
re-shift the balance AWB already set, and the ~1.9x mean gain brightens past the AE target.
Fix in lsc.cpp (4.sl7): equalise each channel grid's mean to the green mean (keeps spatial colour
shading, leaves the global balance to AWB) and publish meanGain; agc.cpp maps histogram levels by
meanGain so exposure is judged on the corrected output.

## 4.sl7: blue cast persists; synthetic single-channel shading probes show the real bug
Flat / only-b / only-g / only-r polynomial sets (LIBCAMERA_SIMPLE_TUNING_FILE): channel isolation
is right (only-b moves only blue), but the applied gain is 3-7x too strong in linear terms, and
only-g lifts R and B at the image centre too. The soft ISP runs the GPU debayer here (Xe, EGL),
and the fuzzed shader hunk had put `rgb *= 1 + lsc` BEFORE `rgb = (rgb - blacklevel) / ...`, so
the pedestal was multiplied too; in a dim room (signal near black) that explodes the correction
and the mean-equalisation of R/B then shows up as a centre colour shift.
Fix (5.sl7): multiply after black-level removal, with a dedicated lscCoord varying (textureIn)
instead of the stride-scaled center.xy.

## 5.sl7 result (installed)
Synthetic probes now behave: only-b lifts only blue at the corners (x1.11 gamma-space over the
corner region), only-r only red, only-g green plus the intended uniform mean-equalisation on R/B.
Real capture: AWB R 1.06 / B 2.53 at 3077 K; centre B/G 0.96 vs 0.91 without LSC, corners B/G
0.92-1.10 vs 0.94-1.11 without LSC (no colour cast), corner brightness x1.6 (gamma space) =
the intended vignetting correction. Frame means 79/78/75 (neutral). Scene is dim: AE pinned at
exposure 2320 lines / gain 15.5x, so images stay dark and noisy in this room; the soft IPA does
not lengthen vblank to trade frame rate for exposure (same limitation the X1 project noted).
Installed: libcamera 0.7.2-5.sl7 (RPMs in ~/rpmbuild/RPMS/x86_64, version-locked),
/usr/share/libcamera/ipa/simple/ov02c10.yaml. Patch: libcamera-0.7.2-lsc-ov02c10.patch.

## 2026-10-28 low-light work (6.sl7)
Noise analysis in a moderately lit room: raw stream clean (120 frames, no drops/glitches/flicker),
AE at exposure max 2320 lines with ~10x analogue gain; corner crops show chroma speckle = gain
noise x LSC corner gain. Changes:
- simple pipeline: V4L2_CID_VBLANK added to DelayedControls (vblankDelay) so the IPA may set it.
- IPA: configure() reads the VBLANK range; frame length extendable to 2x default (30 -> 15 fps);
  exposure limit tracked as frameHeight + vblank - margin (margin from default range = 8 lines);
  processStats reads/sets VBLANK; FrameDuration metadata published.
- AGC order (dark): exposure -> gain to 4x -> frame length to 2x -> remaining gain. Bright: mirror.
  Exposure is never raised above the limit of the frame length already applied (the driver
  re-ranges the exposure control only when the new blanking takes effect).
- LSC: strength 1.0 up to 4x gain, fading linearly to 0.5 at max gain (recomputed on 0.05 change).

## 7.sl7: constant-brightness rebalance between gain and frame length
6.sl7 only extended the frame when the scene was too dark; a satisfied loop at 10x gain never
moved. 7.sl7 adds a rebalance at steady state: gain > 4x -> lengthen frame 8%/step and move the
gain into exposure (two-phase: frame first, exposure next frame once the driver re-ranges);
frame extended and gain < 4x/1.08 -> shorten frame and take the difference back as gain.
Result in the test room: 30 fps/10x -> 15.05 fps, exposure 4648 of 4656 lines, gain 4.75x.

## Magenta horizontal line in GNOME Camera (1920x1080 output): stock GPU debayer bug
Reproduced with cam at 1920x1080 (rows 240 and 720) and 1280x720 (row 400), also with LSC
disabled; absent at the native 1928x1092. In bayer_unpacked.frag the sample position (center.xy)
and the pixel index used for the Bayer phase (center.zw) are interpolated separately; with a
scaled output their rounding disagrees on some rows and the row is demosaiced with the wrong
phase. Fix (8.sl7): snap the sample position and the neighbour taps to the centre of the texel
floor(center.zw) refers to, using tex_step. Worth sending upstream on its own.
8.sl7 verified: no anomalous rows/columns at 1920x1080 or 1280x720; at native 1928x1092 only the
two rightmost columns (1923-1924) deviate slightly (border tap clamping, pre-existing, invisible).
Reminder: after `systemctl --user restart wireplumber`, wait before any cam capture or the libcamera
camera node is skipped ("no camera found") until the next restart.

## 9.sl7 (2026-10-28): GPU chroma denoise
Second render pass in DebayerEGL: the debayer shader renders into an RGBA8 texture at the output
size (SWAP_BLUE moved to the last pass), then shaders/denoise.frag writes the DMA-BUF: 7x7
bilateral in BT.601 YCbCr of the gamma encoded image; chroma weights = spatial x chroma distance
x luma guidance (guide sigma = max(3 luma sigma, 2 chroma sigma); with a 0 guide sigma the
filter silently became a pass-through, found via a passthrough tuning variant); luma gets its own
bilateral blended by lumaStrength. New IPA algorithm "Denoise" (algorithms/denoise.cpp) maps the
analogue gain to sigmas (piecewise linear in log gain; falls back to activeState.agc.again when
the frame context has no gain yet, which is the normal case at prepare() time), via new
DebayerParams.denoise and a denoiseEnabled flag in soft.mojom init -> SoftwareIsp -> Debayer::
configure (CPU debayer ignores it with a warning). Cost: 5.4 -> 8.3 ms/frame at 1920x1092 (Xe).
Tuning (gen-ov02c10-tuning.py): chroma 3/10/22 at gain 1/4/16, luma 0/2/5, lumaStrength 0.5.
Measurement (tools/noise.py <label> <frames>: temporal std per Y/Cb/Cr with per-frame mean removed,
spatial chroma high-pass std, 1:1 crops noise-<label>-{centre,corner}.png), static ceiling corner
at gain 5.5x: spatial chroma HP 5.26/3.92 -> 1.51/1.03, temporal Cb/Cr 6.19/4.84 -> 2.99/2.35,
luma 5.76 -> 5.35. Ceiling grid lines and centre detail intact.
Methodology trap: the build-tree libcamera (LD_LIBRARY_PATH to ref/libcamera-work/build) loads
src/ipa/simple/data/uncalibrated.yaml unless LIBCAMERA_SIMPLE_TUNING_FILE is set; always pin
the tuning file when comparing against the installed build.
Dev loop that avoids rpmbuild: ninja -C ref/libcamera-work/build, then run cam/noise.py with
LD_LIBRARY_PATH=$B/src/libcamera:$B/src/libcamera/base (the build tree's signed IPA is picked up).

## 10.sl7 (2026-10-28 evening): user report after 9.sl7 -> two pre-existing bugs, one install trap
User saw in GNOME Camera: green cast, worse colour noise, and after moving "a cascade of noise where
I was before that pulses and flickers before dying down". Journal showed Snapshot's PipeWire node
runs inside wireplumber, which still had the OLD libcamera 8.sl7 + old IPA mapped ("(deleted)" in
/proc/<pid>/maps): the denoiser was not even running. 04-install-tuning.sh now restarts wireplumber
for $SUDO_USER (and picks the newest RPM release when several coexist).
- Pulsing: tools/aetrace.py (per-frame exposure/gain/frame duration + mean Y of a static region +
  a banding metric) showed +5/-5 Y pulses at every gain<->exposure rebalance step: exposure landed
  one frame before the gain drop. The default sensor delays (exposure 2, gain 1) are wrong for the
  OV02C10; gain also takes 2 frames. Added an "ov02c10" entry to camera_sensor_properties.cpp
  (unit cell 1.116 um per OmniVision's OV02C brief, delays 2/2/2/2). Verified: steps now +-0.4 Y.
- Green cast: CCM rows all sum to 1, so it is AWB: grey world over the whole frame is biased by the
  person/warm objects and the CCM amplifies the residual (ceiling Cb/Cr -4/-9 at ~4300 K fluorescent).
  Stats now carry per-luma-bin colour sums (SwIspStats::binSum_[64], accumulated in the stats
  macros, merged/shifted in finishFrame); Awb gained tuning keys lumaWeight (exponent on luminance
  above black; 0 = old behaviour) and clipBins (top histogram bins excluded as clipped). Measured on
  the ceiling: plain -3.5/-10.7; w=1 -3.0/0.0; w=2 +3.5/-7.0; w=3 +3.8/-10.5 (higher exponents hand
  the balance to the fluorescent tube); w=1 + clipBins 16: -0.2/-0.4 -> chosen.
- Mains flicker (120 Hz) banding is measurable but small (band metric 0.5-2.5 vs ~4 at startup) and
  depends on exposure mod 8.33 ms; an anti-banding exposure quantisation would be the next AE step.

## 11.sl7: motion blur from the frame-length extension; threshold made tunable
With 10.sl7 in GNOME Camera the cast was better but "significant motion induced artifacts" remained.
aetrace + crops (AETRACE_SAVE=dir keeps 480x360 centre crops around brightness jumps) showed the AE
at 66 ms exposure / 15 fps in the user's room (gain ~6x > the 4x long-exposure threshold), with the
face visibly smeared on movement. Also the AE target (MSV 2.5 of 5 on the raw histogram, stock
libcamera) is bright: the ceiling sits at Y~195, so the AE keeps asking for more light.
Change: Agc tuning key longExposureGain (default 4.0 = previous behaviour); the OV02C10 tuning sets
12.0, so the frame stays at 33 ms/30 fps until 12x gain and only then lengthens. Gotcha found on the
way: IPASoftSimple::configure() does `context_.configuration = {}`, so tuning values read in init()
must be copied into the session configuration in the algorithm's configure(), not in init().
Verified by trace: exposure pinned at 33060 us, gain ramps 6 -> 12x over ~150 frames, frame length
untouched until the gain limit. Ideas left: lower/tunable AE target (MSV), faster convergence,
anti-banding exposure quantisation.

## 12.sl7: shading-aware white balance (from the adversarial code review)
A 5-lens review of the denoise change (workflow, 23 agents) confirmed three defects in the earlier
LSC work and one deployment trap:
- LSC texture name kept across stop()/start(): start() creates a new EGL context each time, so the
  grid silently stopped applying after the first reconfigure (GNOME Camera reopen). stop() now
  deletes the texture (11.sl7).
- The 8-bit grid encoding (gain-1)/scale clamped gains below 1 to 1.0 - the mean-equalised red grid
  was below 1 over the centre. Encoding is now (gain-min)/scale with an lscOffset uniform.
- The LSC gain fade and the Denoise gain lookup read frameContext.sensor.gain, which is 0 at
  prepare() time (processStats() fills it later); Denoise already fell back to activeState.agc.again;
  the LSC fade never engaged and is removed (the denoiser handles corner noise).
- Mean-equalising the per-channel grids to green keeps the frame-average colour but shifts the centre
  (face) by the centre/mean ratio of the relative colour shading. Replaced by making AWB evaluate the
  corrected image: SwIspStats now carries 8x8 zone x 4 luma-band colour sums + counts and the stats
  window position (the GPU path's stats window is now the real centred window, not the top-left
  corner); Awb weights each zone by the LSC gains at the zone centre (grids published in
  activeState.lsc) and each band by (band+0.5)^lumaWeight, excluding clipBins/16 top bands; LSC
  applies the polynomial grids as they are. Result: ceiling top -1.7/+1.7 Cb/Cr, centre +1.5/+0.7,
  30 fps at 9.5x gain in the evening room. The extreme corner keeps a warm residual (-7.5/+3.6) that
  is identical to before: colour shading set choice (CT estimate 3700 K vs ~4200 K light) or
  polynomial fit; next candidate for tuning.
Review findings judged not worth acting on: unsynchronised shared-params copy (pre-existing design),
IPA ABI without version guard (inherent), CPU debayer LSC grid stretched over the crop (CPU path
unused here), intermediate FBO completeness not propagated (logged by eGL already).
Correction to the 12.sl7 numbers above: noise.py/aetrace.py assumed R,G,B byte order; for XRGB8888
(what Snapshot negotiates) memory is B,G,R, so every XRGB measurement before this note had Cb/Cr
roles mixed and the crops showed a purple face. Fixed (format-aware). Re-measured, correct order,
1920x1080 XRGB: 12.sl7 tree top +2.8/-1.5, corner +5.6/-7.4, centre -0.1/+1.0; installed 10.sl7
top +3.2/-2.5, corner +6.0/-8.0, centre -1.2/+6.7. The corner keeps a cyan residual in both (the
generic aiqb shading tables under-correct this unit's corner colour; the per-unit EEPROM data is the
real fix). The centre differs because 10.sl7's equalised-then-clamped grids boosted red by ~15%
there; 12.sl7 applies the tables as designed. LscPolynomial samples are centre-normalised (centre
gain exactly 1, corner 5.1/3.9/3.95/3.83 for r/gr/gb/b at 2300 K), so the clamp only ever bit the
equalised grids.

## Review workflow outcome (62 agents, 5 lenses x 3 refuters per finding)
Confirmed (and status): LSC texture across stop/start -> fixed 11.sl7; LSC gain fade reads unset
frameContext.sensor.gain -> fade removed 12.sl7; Denoise reads the same unset field -> now takes the
gain of the last frame with statistics via Denoise::process() (activeState.denoise.gain), AGC request
as fallback; CPU debayer LSC grid normalised to the crop window instead of the sensor frame -> fixed
in tree (GPU path was already right: lscCoord spans the input texture).
Refuted by the verifiers: the 8-bit LSC encoding clamp (grids are centre-normalised >= 1, so only
the old equalised grids were affected; offset encoding kept anyway), mean-equalisation cast (removed
regardless in favour of shading-aware AWB), unsynchronised shared-params copy and IPA ABI versioning
(pre-existing design), FBO completeness not propagated (eGL logs it), intermediate bound while a
render target (not referenced by the debayer program; unbound anyway now), member destruction order.

## 14.sl7: YUYV output from the GPU software ISP (Zoom and other V4L2 clients)
Zoom (RPM) reads V4L2 directly; the IPU7 nodes are raw Bayer. With the pipewire-v4l2 bridge
(`pw-v4l2 zoom`, launcher override ~/.local/share/applications/Zoom.desktop -> tools/zoom-camera.sh)
Zoom lists the camera, negotiated 640x480 ARGB8888, and showed black: the bridge delivers real
frames (gst v4l2src through pw-v4l2 captured 1920x1080 XR24 with mean byte 182), so Zoom simply does
not render 32-bit RGB. The soft ISP only offered RGB formats. Added formats::YUYV to DebayerEGL:
pack_yuyv.frag is a final pass over the processed RGB intermediate (two source pixels per fragment,
BT.601, full or limited range from the stream's ColorSpace), rendering into the YUYV DMA-BUF imported
as a half-width ARGB8888 texture (so memory Y0 U Y1 V = .b .g .r .a). Chain: debayer -> intermediate
-> [denoise -> intermediate2] -> pack -> output. Verified with cam at 1280x720-YUYV/sYCC: 30 fps,
byte0/2 mean 154 std 16 (Y), byte1 131 / byte3 126 std 4-5 (U/V), decoded crop correct.
PipeWire maps YUYV to YUY2, pw-v4l2 to V4L2_PIX_FMT_YUYV; Firefox/WebRTC also accept YUY2.

## Root cause of the motion trails: IPU7 ISYS capture buffers are not cache coherent
User (Zoom and GNOME Camera): "flickering short horizontal lines left behind when my face moves".
Motion capture via cam (tools/motion.sh + tools/specks.py / frames2png.py) showed, in the direct
libcamera path too, 21-22 output px long runs of saturated garbage = exactly 64 bytes (32 sensor
pixels) of raw data. Raw path test (tools, chunk-level): ~300 live 64 B chunks per frame are
bit-identical to the frame exactly 4 back = the previous use of the same buffer (4 buffers in flight):
the camera DMA's new data is not seen for those cache lines. The staging IPU7 driver
(drivers/staging/media/ipu7/ipu7-isys-queue.c, kernel 7.2.11) maps each vb2 buffer once in
buf_init via ipu7_dma_map_sgtable (which clflushes once, and with DMA_TO_DEVICE for a capture
buffer) and never syncs again per frame: no clflush in buf_prepare or before vb2_buffer_done. The
IPU writes memory without snooping the CPU caches, so any line cached since the last DQBUF (CPU
stats, CPU debayer, or the GPU through the shared LLC) stays stale -> old-frame chunks, visible as
trails wherever the scene changed. Invisible on static scenes, hence missed by every earlier test.
Workaround in libcamera (Debayer::invalidateInputCache): clflushopt over the whole input buffer
before each frame is processed (GPU and CPU debayer), x86 only, disable with
LIBCAMERA_SOFTISP_NOFLUSH=1. Diagnostic: LIBCAMERA_SOFTISP_RAWCHECK=1 renders the input texture
unchanged and counts 64 B chunks that differ between the GPU's and the CPU's view of the frame.
Proper fix: kernel patch adding ipu7_dma_sync_sgtable() to buf_prepare (and buffer done) in the
ISYS queue; worth reporting upstream (linux-media, Intel IPU7 staging driver).
Refinement (same evening): LIBCAMERA_SOFTISP_STALECHECK=1 (Debayer::staleCheck) compares each input
buffer with its own previous content, as seen through the CPU cache, after clflushopt, and 15/30/60 ms
later. Typical static run: most frames 0; bursts such as seq 4: 7834 old chunks in the cached view,
442 in memory right after the flush, 278 still after 15 ms; seq 49: 1097 / 814 / 561. So two effects:
(a) CPU cache lines stale versus the IPU's non-snooped DMA (the bulk; fixed by the clflushopt before
each frame), and (b) a smaller, sporadic set of 64 B chunks the ISYS has not written to memory yet when
PIN_DATA_READY hands the buffer over, landing over tens of ms (IPU-side write buffering with no flush
at frame end). (b) can only be fixed in the IPU7 driver/firmware; a one-frame processing delay would
hide it. Also learned: on this machine the EGL dma-buf import of the raw input fails (DRM_FORMAT_RG88),
so the stock GPU debayer has always used the CPU upload path (glTexSubImage2D of the mapped buffer),
which is why the GPU output shows exactly the CPU cache staleness.

## 16.sl7: green flicker every 4 frames = LSC set / shading-aware AWB limit cycle
With 15.sl7 the user saw a regular green flash. tools/colortrace.py (per-frame ceiling colour + AWB
gains/ct + LSC set from the debug log) showed the ct estimate oscillating 3600 <-> 3680 K around the
3606 K set boundary: hard set switch -> colour changes (4711 set: ceiling Cr +3.9, 3606 set: Cr 0)
-> shading-aware AWB moves the estimate back -> switch again, every statistics period. Fix in lsc.cpp:
follow an IIR-smoothed ct (0.7/0.3) and blend the two neighbouring sets linearly in ct instead of
picking one (resample on >= 25 K change). Result: gains constant 1.28/2.20, ct 3620-3632 K, 0 set
changes, colour jumps 3/150 (startup only). Note this loop existed since 12.sl7 but only bites when
the light sits near a set boundary.

## Kernel-side fix: ipu7/ipu7-isys-coherency.patch (intel-ipu7-isys built out of tree)
After 16.sl7 the user still saw rare thin flashes = the ISYS handing over buffers before all writes
landed. Patch to drivers/staging/media/ipu7 (v7.2.11): (1) ipu7_dma_sync_sgtable (clflush over the
buffer) in buf_prepare and in a new buf_finish, both process context (QBUF/DQBUF), module param
isys_cache_sync; (2) deferred completion: ipu7_isys_queue_buf_ready parks the buffer on a new
aq->pending list; it is completed when the next buffer of the queue is ready (isys_defer_done=2,
default, +1 frame latency) or at the stream's next FRAME_SOF (=1); return_buffers() drains pending
on stop. Built with ipu7/build-isys.sh (fetches the staging dir from kernel.org for the running
kernel, Kbuild with obj-m for the isys module only; depends on the in-tree intel-ipu7 core via
Module.symvers). Activate: sudo ipu7/reload-isys.sh. Verify: LIBCAMERA_SOFTISP_STALECHECK=1 cam ...
should show memory 0 everywhere; latency +33 ms with mode 2.
Verified with the patched module loaded from /lib/modules/.../updates (isys_cache_sync=Y,
isys_defer_done=2): 150 frames at 30.05 fps, 146 checked, 0 old-content chunks in the cached view,
in memory, or after 15 ms; user confirms the motion flicker is gone in Zoom and GNOME Camera.

## Module EEPROM decoded (per-unit shading)
Layout of this unit's 24C64 (tools/eeprom_nvm.py): 13-byte header; 8 coarse 7x11 8-bit shading
planes (0 at centre, 90-134 at corners; 4 channels x 2 lights); misc block with 8 u16 values,
module info, a 55 aa marker, three 18-entry Q7 radial gain profiles (128 -> ~574 = 4.5x), optical
centres (960,545) and residual triplet grids; then at 0xa20 a 16-byte header, "02 11 0d" (version 2,
17x13) and 17x13 u16 planes of relative sensor response, 1023 at the optical centre: gain = 1023 /
value. Plane order R, Gr, Gb, B; two lights expected (planes 4-7 need the 8 KB read).
Against the aiqb: plane 0 matches the absolute R grid within 3 % rms (corner x1.02), the greens are
6-13 % stronger at the corners on this unit than on the golden module. The aiqb "ratio" record (33,
same layout as 28, values ~1.0-1.07) is Intel's per-unit multiplier: applied gain = ratio x (1023 /
NVM response); on this unit that gives ~20 % more corner gain than the generic grids in all channels.
Soft ISP side: LensShadingCorrection now accepts `type: grid` (width/height + per-channel value
lists spanning the full frame, bilinearly resampled to the 17x17 backend grid); validated by
resampling the polynomial sets to 17x13 grids (gen-ov02c10-tuning.py --grid-from-poly): identical
rendering. Generator mode --eeprom=<dump> emits the Intel-formula grids per aiqb set, choosing for
each set the EEPROM light whose colour shading matches the set's golden NVM (absolute / ratio).
Full 8 KB read (eeprom-20261028-164624.txt): both lights present; each light's 4 planes are
followed by a 2-byte checksum. Light 0 corner B/G ~1.08 (incandescent-like), light 1 ~1.00 =
the aiqb's golden pattern (absolute/ratio is the same colour pattern for all six sets, so the ratio
record is one golden flat-field's illuminant table). Camera comparison, corner minus top-of-frame
ceiling colour (Cb/Cr) and corner/top luminance, fluorescent room ~3650 K:
  generic polynomial (aiqb)         +1.9 / -7.3   0.88
  Intel formula ratio x NVM light 1 +1.6 / -7.1   0.90
  Intel formula ratio x NVM light 0 +2.4 / -6.7   0.91
  NVM light 1 alone (no ratio)      +2.7 / -2.0   0.92   <- chosen
The ratio record's illuminant adjustment (made with blackbody-like lamps) is what tints this unit's
corners under fluorescent light; the unit's own flat field under light 1 is the best match here.
tuning/ov02c10.yaml is now generated with --eeprom=<dump> --light=1 --no-ratio (one grid set);
variants/generic-polynomial.yaml keeps the previous tuning, variants/eeprom-intel*.yaml the others.
Open: under incandescent light, light 0 (or the Intel formula) may be the better set; untested.
Installed 17.sl7 + EEPROM grid tuning; user confirms the corners look clean.

## Touchpad (2026-10-28 evening): "intermittent detection problems" in scroll/swipe/hold
capture2.sh (now with a read-and-get-ready countdown per phase) + iptsd-replay + tools/hmstats.py:
no raw-node fallback, iptsd healthy, contact signal strong (dip ~115-125 vs threshold 24), noise
floor fine. Symptom = contact count flickering 2/1/2 (49 times) and 3/2/3 during two-finger scroll
and the two-finger hold: in those frames the two fingers (~3 cells = 14 mm apart) were spanned as
ONE long contact (major axis ~0.3), because the span on the blurred heatmap bridges the valley
between close fingers. 26 Oct capture had 0 such frames (fingers further apart then). Fixes
evaluated by replay: merge-before-padding code change alone 49 -> 49; DeactivationThreshold 30
-> 4; PeakSuppressionRadius 1 / Factor 0.5 -> 44; PeakSuppressionRadius 2 / Factor 0.3 -> 0 with
0 long contacts, 0 false splits on either capture, position shift median 0.07 mm. Config now sets
PeakSuppressionRadius = 2, PeakSuppressionFactor = 0.3 (iptsd commit 3ed74c8 also merges clusters
before padding). Lesson: replay frame index is not time (frames only arrive while touching).
User confirmed: close-finger scroll/hold fixed by PeakSuppressionRadius 2 / Factor 0.3 (installed).
Touchpad: TwoFingerMotionScale 0.45 added (separate from MultiFingerMotionScale 0.6 for 3+ fingers); user confirms scroll speed good.

## 18.sl7: fast AE convergence
User: at home under incandescent light the picture started very dark and the gain rose slowly.
tools/sensor-reset.py sets the sensor to exposure 4 lines / gain 1x (the driver keeps the last
session's values, so a normal restart starts where it left off). Dark-start traces (aetrace):
stock controller (0.04 proportional, 0.15 max step, one update per 4 frames) reached only 2 ms
exposure after 8 s; raising to 0.16 / 0.5 alone reached 22 ms after 8 s, because the MSV error
saturates (~0.7, the lscGain level mapping pushes a black frame into bins 1-2) so the step stays
~10 %. Fix: when |error| > 1 the step is the measured brightness ratio (target = middle of the
level range / mean level)^0.7, clamped to [0.25, 4] per update; the proportional law (now tunable:
Agc proportionalGain 0.16, maxStep 0.5) finishes near the target. Result: 57 us -> 33 ms by frame
20, gain 1 -> 9x by frame 28 (~0.9 s), no overshoot, steady afterwards.
User confirms (18.sl7 installed): camera comes up to brightness quickly under incandescent light.
Incandescent check (home, ct ~2700 K), corner minus top Cb/Cr and corner/top Y: light 1 alone (installed)
-0.3/+0.2 0.93; light 0 alone -0.1/+2.3 0.88; Intel ratio x light 1 -1.7/-1.9; Intel ratio x light 0
-0.1/-2.0; generic polynomial -1.4/-3.6. Light 1 alone stays the best under both lights; no change.

## 2026-10-29: deferral switched off (latency 58 -> 23 ms)
Capture-start to delivery (tools/latency.py, 1280x720): defer 2 58 ms; defer 0 23 ms. Stale-chunk
check with the kernel cache sync and defer 0: 596 frames idle and 1496 frames under 4 memory-
thrashing processes, 0 old-content chunks in memory at dequeue. The "late writes" seen before the
kernel patch do not recur with the kernel-side clflush, so isys_defer_done=0 is the default via
configs/etc/modprobe.d/intel-ipu7-isys.conf; ipu7/isys-param.sh switches it at runtime.
User confirms (2026-10-29): webcam delay much better with isys_defer_done=0 persistent.

## 19.sl7 (2026-10-29): anti-banding (mains flicker) in the soft IPA AGC
Mains lighting flickers at twice the line frequency (8333 us at 60 Hz, 10000 us at 50 Hz); with a
rolling shutter any exposure that is not a whole number of periods shows as horizontal bands drifting
through the picture. For a sinusoidal light component the ripple relative to the modulation depth is
about |E - nearest multiple| / E, so 33060 us (3.967 periods, this sensor's longest exposure at the
nominal frame rate) rings at 0.8 % of the modulation, while 12 ms (1.44 periods) rings at 22 %.
Implementation (agc.cpp, tuning key `Agc: flickerPeriod` in us, 0/absent = off; our ov02c10.yaml
sets 8333):
- quantiseExposure() runs inside store(): of the two neighbouring multiples of the period it takes the
  one that changes the gain the least while staying within the exposure range and [againMin, againMax];
  the product exposure x gain is kept. Below one period at gain 1 (bright light) nothing can be done;
  in the dark, when neither multiple is reachable at <= 15.5x, the light wins over the quantisation.
  2 % tolerance: when the nearest multiple is out of reach and the exposure is already within 2 % of it,
  the other multiple's gain cost is not paid.
- The control law now starts each update from the canonical split of the measured total (longest
  exposure, least gain), the state it converges to anyway. Without that the quantised exposure stayed
  below exposureMax forever, so the "exposure first, then gain to 12x, then frame length" ordering
  never reached the frame-length step and the gain ran to 15.5x in the dark.
- The satisfied (|error| <= 0.2) path now always ends in store(). Before, it returned the measured
  values untouched, so the quantiser only ran when the AE moved: steady frames stayed unquantised and
  the exposure flip-flopped 2320/2340 lines from one update to the next.
- Frame fit: at 30 fps the longest exposure (2320 lines = 33060 us) is 20 lines short of four periods
  (2340 lines). applyFlickerPeriod() raises the nominal vblank from 1236 to 1256 (frame 2348 lines,
  33459 us, 29.89 fps instead of 30.14) when the extension is <= 5 % of the frame, so the dim-office
  operating point is exactly four periods at the lowest gain (9.0x) rather than three periods at 12x
  or unquantised. updateExposure() lifts a vblank below the nominal one (sensor default) on the first
  update.
- Controls: AeFlickerMode (Off / Manual) and AeFlickerPeriod are advertised; Manual without a period
  uses the tuning value. Tested with a small libcamera client (scratchpad flicker-test.cpp): tuning
  60 Hz -> 33345 us (4 x 585 lines, 13 us residual from line rounding) gain 8.9, frame 33459;
  FlickerOff -> 33060 us gain 9.0 frame 33174; Manual 10000 -> 30010 us (3 x 702 lines) gain 9.9;
  back to Manual -> 33345 us. Dark start (sensor-reset.py) settles by frame 27 (~0.9 s), passing
  through 8336 us / 1.75x on the way. Line duration verified exact: cam measures 30.14 fps = 2328
  lines x 14.25 us.
Not measurable here: the band metric sits at the noise floor (0.55-0.6) with and without the change,
because the dim office already puts the exposure within 1 % of a multiple. The bright regime
(1-3 periods) is exercised only during convergence; a daylight/brighter-room check is still worth doing.
Generator: gen-ov02c10-tuning.py writes `flickerPeriod: 8333`. Patch regenerated, Release 19.sl7.
Installed 2026-10-29: system trace (installed library + /usr/share tuning) shows 33345 us / 9.7x / frame 33459 us; WirePlumber holds no stale mapping.

## 20.sl7 (2026-10-29): AE brightness target (exposure compensation) and tighter hysteresis
Stock soft-IPA target is a mean sample value of 2.5 on the linear, pre-gamma histogram, which after
the gamma curve puts a white wall at the clip: full-frame mean 166/255, 4.9 % of pixels at >= 250.
Implementation (agc.cpp): tuning `Agc: exposureValue` (stops, default 0) plus the standard
ExposureValue control (advertised -8..8, added to the tuned value). The AE judges the histogram levels
scaled by 2^-EV (same place as the lens-shading mean-gain mapping), so the MSV law, its band and the
far-from-target ratio step all stay consistent. Snapshots (snap.py, half-size PNGs in the scratchpad)
at EV 0 / -0.3 / -0.5 / -0.7 / -1.0: mean 166 / 158 / 147 / 135 / 128, clipped 4.9 / 1.1 / 0 / 0 / 0 %.
Chosen default -0.5: wall no longer clips, face natural; -1.0 already looks subdued.
Approach-direction spread: with the stock +-0.2 MSV band the AE settled at gain 5.50 from a dark start
but 6.75 from a bright start (23 % brightness difference, both "satisfied"). New tuning `Agc: hysteresis`
(default 0.2); at 0.1 the spread is 6.00 vs 6.69 (11 %) with no late wobble (0.1 of meanY), dark start
settled by frame 47, bright by 23. proportionalGain 0.3 was also tried: overshoot and wobble (2.5) from
the dark side, so it stays at 0.16. The last ~1 s of a dark start is a proportional crawl (gain 4.4 -> 6.0
over 30 frames) because the ratio step only acts at |error| > 1; left alone (ratio target is the
half-range mean, not the MSV target, so letting it closer risks fighting).
Runtime control test (scratchpad ev-test.cpp): tuning -0.5 -> gain 6.2; ExposureValue +1 -> 11.5;
-1 -> 3.2; 0 -> 5.8. Generator writes exposureValue -0.5 and hysteresis 0.1. Release 20.sl7.
Installed 2026-10-29 (20.sl7): system trace confirms the lower target with the installed library.

## 21.sl7 (2026-10-29): temporal denoise in the GPU software ISP
New pass after the spatial denoise: shaders/temporal.frag blends the previous output (kept in two
ping-pong history textures, units 4/5) into the current frame where the picture is static, and
renders into the other history texture; pack_yuyv.frag (YUYV) or the new copy.frag (RGB outputs)
writes the output buffer from there. Chain: debayer -> intermediate -> denoise -> intermediate2 ->
temporal -> history -> pack|copy -> output. Blue swap for XBGR stays in the denoise shader (the copy
pass never swaps). History is invalid on the first frame after start() and whenever the pass is off
(strength 0): that frame passes through. LIBCAMERA_SOFTISP_NOTEMPORAL=1 disables it for A/B.
Motion test: mean absolute RGB difference between frame and history over 3x3 (27 samples), compared
with sigma-scaled thresholds (smoothstep motionLow..motionHigh sigmas): full history weight below,
none above. Trails are bounded by the noise level by construction (an edge blends only if its
contrast is below a few sigma). Weight w gives noise x sqrt((1-w)/(1+w)).
Tuning (Denoise block): `temporal` curve {gain, sigma} = per-pixel temporal noise in 8-bit codes
measured with the new tools/tnoise.py (per-pixel std over 40 frames, binned by luma; static wall:
2.5 @1.3x, 2.8-4.4 @5.75x, ~6 @12x) -> {1: 2.5, 4: 3.5, 16: 6.5}; `temporalStrength` 0.75;
`temporalMotionLow` 1.5; `temporalMotionHigh` 3.5. Measured on the static wall (bin 160-175) at
gain ~6: off 2.82 -> 0.75: 1.07 (theory 0.38x: 1.07), 0.60: 1.53, 0.85: 0.79; thresholds 2.5/5.0
help only in the bins that contain the (moving) person. Chroma std drops the same way (2.60 -> 0.95).
GPU/CPU time per frame 7.58 -> 8.01 ms at 1080p. YUYV, XBGR8888 and XRGB8888 paths verified
(frames delivered, channel order right). Snapshot clean. Ghosting on real motion still to be judged
by the user (waving a hand in front of the wall is the test); 0.85 is the next step up if more
smoothing is wanted, lower motion thresholds if trails show.
User feedback on 21.sl7 (installed): "needs less smoothing, all motion looks a bit weird". The recursive
filter lets a slowly moving smooth surface show only (1 - w) of each change per frame while edges
update at once: at w = 0.75 that lag (4 frames) is visible in luma. 22.sl7: separate luma and chroma
weights in temporal.frag (YUV split, BT.601), tuning temporalStrength 0.5 (luma) and new
temporalChromaStrength 0.75 (chroma lag is hardly perceived, and colour blotches are what the pass
removes best), temporalMotionHigh 3.0. tnoise, static wall bin 160-175 at gain ~6: off sigmaY 2.90 /
Cb 2.72 -> luma 0.5 / chroma 0.75: 1.69 / 1.04 (0.58x and 0.38x, as theory); luma 0.4: 1.89; chroma
0.5: 1.59. Next steps if still weird: luma 0.3-0.4, or temporalStrength 0 with chroma only.
User confirms (2026-10-29, 22.sl7 installed): motion looks better with luma 0.5 / chroma 0.75.

## Upstreaming (2026-10-29): kernel patches prepared
upstream/media = linux-media `next` (sparse clone, head d7e7bca7 2026-10-09), branch sl7-upstream with two
commits: "media: staging/ipu7: flush capture buffers around each DMA" (minimal form of the coherency
fix: ipu7_dma_sync_sgtable in buf_prepare and a new buf_finish; no module params, no deferral; Fixes:
a516d36bdc3d) and "media: i2c: ov02c10: support a 12 MHz external clock" (rebased: next has CCI_REG24
chip id, v4l2_subdev_client_info pad-op arg, devm_v4l2_sensor_clk_get; context only). Kernel rules
(Documentation/process/coding-assistants.rst): assistant adds `Assisted-by: LLM`, must not add
Signed-off-by or send; so author is a placeholder until the user runs upstream/kernel/sign.sh with
their name (adds DCO sign-off, writes upstream/kernel/out/*.patch). checkpatch --strict: clean apart
from the expected missing Signed-off-by. ipu7 patch compile-tested against 7.2.11 headers with W=1 (the
file is identical in next). ov02c10 patch applies on next but cannot be compiled here (no next headers).
Maintainers: ipu7 -> Sakari Ailus + linux-media (+ linux-staging/Greg KH); ov02c10 -> Hans de Goede,
Bryan O'Donoghue (R), linux-media. Instructions: upstream/kernel/README.md.
iptsd upstreaming: all 8 local commits conflict with linux-surface/iptsd master (fork rewrote touch.hpp,
config.hpp, config-loader.hpp), so the PR goes to alex-lentz/iptsd (fork last pushed 2026-07-17, owner
merges PRs). upstream/iptsd/{README.md,PR.md,prepare.sh} (re-authors the "local <local@localhost>" commits
and creates branch sl7-touchpad; user forks, pushes, opens the PR). No gh CLI installed.
libcamera upstreaming: master = v0.7.2-202 (2026-10-29): soft IPA renamed src/ipa/softisp, LSC landed via
libipa (lsc_polynomial / lsc_table with ct sets), AWB/CCM on libipa algorithms, libipa agc_msv helper, no
vblank in the simple pipeline's DelayedControls, no zoned stats, no denoise/YUV passes in debayer_egl, no
flicker/EV in the soft AGC. Branch upstream/libcamera sl7-upstream: commits "ipa: libipa:
camera_sensor_helper: Add OV02C10 support" and "libcamera: camera_sensor_properties: Add OV02C10 sensor
properties" (delays 2/2/2/2). Build of master with them running; checkstyle via utils/checkstyle.py.
Order for the rest: simple pipeline VBLANK delayed control + IPA frame-length extension; AE law
(proportional + ratio step, tunables, hysteresis, ExposureValue); anti-banding; zoned stats + shading-aware
AWB; LSC grid on libipa lsc_table; denoise passes; YUYV pack. Tuning file: needs the user's decision
(aiqb/EEPROM-derived data).

## 2026-10-29 afternoon: first end-to-end run of install.sh on the laptop broke keyboard, camera and the new kernel
Symptoms after `sudo ./install.sh all` (running 7.2.11) and a reboot: a second kernel 7.2.13 appeared in the
boot menu on which nothing worked (no camera, no audio, patched modules "Unknown symbol"), and on both kernels
the internal keyboard, battery and power button were gone (`surface_serial_hub serial0-0: error -EINVAL:
failed to setup IRQ`, first seen in the 11:16 boot and in every boot since) while on 7.2.11 the camera also
died (`intel-ipu7: Direct firmware load for intel/ipu/ipu7_fw.bin failed with error -2` at 1.3 s).
Three independent causes, none in the patched code:

1. **Half-installed kernel.** `install.sh deps` installed `dkms`, which Requires
   `(kernel-devel-matched if kernel-core)`. dnf satisfied that with the newest available version (7.2.13) and
   pulled kernel-core + kernel-modules-core 7.2.13 along, but not kernel-modules / kernel-modules-extra / the
   `kernel` meta package (dnf history 35: 5 packages). Without kernel-modules there is no videodev, no v4l2
   core, no soundwire/sof, no Bluetooth; depmod produced empty dependency lists for ov02c10,
   intel-ipu7-isys and snd-soc-sdw-utils in that tree (`modules.dep`: `extra/ov02c10.ko.xz:` with nothing),
   hence "Unknown symbol ... (err -2)". The 118-package GNOME Software update at 10:34 only updated
   kernel-tools. Fix: `dnf install kernel-7.2.13 kernel-modules-7.2.13 kernel-modules-extra-7.2.13`;
   `install.sh deps` now asks for `kernel-devel-matched-$(uname -r)` explicitly and completes any kernel-core
   that lacks kernel-modules (complete_fedora_kernels); `status` reports such kernels.
2. **SAM in the initramfs before its GPIO controller.** Fedora's dkms runs `dracut --regenerate-all --force`
   after every transaction (/etc/dkms/framework.conf post_transaction). dracut's 70kernel-modules-extra
   module includes every module in the depmod search directories other than the kernel's own (updates/,
   and extra/ since our depmod.d search line), plus dependencies, and 11systemd-modules-load includes
   /etc/modules-load.d. So the regenerated initramfs carried surface_aggregator_registry + surface_hid and
   loads them via systemd-modules-load at 0.90 s, before udev's coldplug (1.07 s) has probed the Lunar Lake
   pin controller (pinctrl_intel_platform, INTC105D devices; gpio-keys appear at 1.31 s). In
   drivers/platform/surface/aggregator/controller.c ssam_irq_setup() does
   `gpiod_get(dev, "ssam_wakeup-int")`, and on *any* error (including -EPROBE_DEFER) falls back to
   `fwnode_irq_get(fwnode, 0)`, which for an ACPI node without an Interrupt resource returns -EINVAL. The
   probe fails for good: no SAM bus, so no keyboard, battery, AC, power button. Before, the modules-load
   file was not in the initramfs (stock images predate it), SAM loaded via udev after pinctrl, and it worked.
   Fix: `configs/etc/modprobe.d/surface-sam.conf`: `softdep surface_aggregator pre: pinctrl_intel_platform`
   (honoured by modprobe, systemd-modules-load and dracut-install; the pinctrl probe is synchronous).
   Upstream-worthy kernel fix: return early when gpiod_get() yields -EPROBE_DEFER instead of falling back.
3. **Camera driver in the initramfs.** Same dracut rule: intel-ipu7-isys (ours, in extra/) pulled intel-ipu7,
   ipu-bridge and the v4l2 stack into the initramfs; the IPU7 PCI driver probed there at 1.26 s, found no
   firmware (not in the initramfs), failed with -ENOENT and is never re-probed; ov02c10 then waits forever
   for its fwnode graph endpoint. Fix: `configs/etc/dracut.conf.d/surface-laptop-7-intel.conf` omits
   intel_ipu7_isys, intel_ipu7, ipu_bridge, ov02c10 and snd_soc_sdw_utils (surface_aggregator_registry stays,
   for LUKS keyboards). Verified by building a test initramfs as a normal user with `dracut --debug`: the
   70kernel-modules-extra instmods call listed all four extra/ modules.
Also: the old dev-tree installer had copied 7.2.11-built modules into the 7.2.13 tree (version magic
errors) at 11:12; it now refuses mismatched vermagic. install.sh installs the config files before DKMS
builds (so the dkms-triggered dracut run sees them), rebuilds the initramfs itself when dkms does not,
and `configs` rebuilds it too; uninstall.sh rebuilds after removing the files. Lesson: on Fedora any
out-of-tree module ends up in the initramfs after a DKMS build, with all consequences of early loading.
Still open from this day: the MOK key is enrolled (`mokutil --list-enrolled`) but the modules still log
"module verification failed" with Secure Boot off; check `sudo keyctl list %:.machine` before enabling it.

## 2026-10-29 evening: Secure Boot pre-flight
State: SecureBoot disabled, firmware in Setup Mode (PK/KEK/db cleared earlier), MOK list holds the Fedora CA and
the DKMS key (`mokutil --list-enrolled`), MokListTrustedRT present (MOK trusted for the machine keyring), no
pending MOK requests. All four modules for 7.2.11 and 7.2.13 carry a sha512 signature by "DKMS module signing
key". The persistent `module verification failed` log line with Secure Boot off is explained by
security/integrity/platform_certs/load_uefi.c in 7.2: `if (!arch_get_secureboot()) return 0;` before the
MokListXRT/MokListRT loading, so MOK keys are never loaded while Secure Boot is off (confirmed: no
"integrity: Loading X.509 certificate: UEFI:MokListRT" line this boot). Under Secure Boot the DKMS certificate
(CA:TRUE but no keyUsage extension; dkms 3.4.4 only adds extendedKeyUsage=codeSigning) fails Fedora's
CONFIG_INTEGRITY_CA_MACHINE_KEYRING(_MAX) restriction (restrict_link_by_ca needs keyCertSign) and falls back to
the .platform keyring (add_to_machine_keyring); Fedora's patch-7.2-redhat.patch makes mod_verify_sig() retry
with VERIFY_USE_PLATFORM_KEYRING, so the modules will verify. Fedora shim-x64 16.1-7 is dual-signed
(Microsoft Corporation UEFI CA 2011 and Microsoft UEFI CA 2023; read from the PE certificate table of the
RPM's shimx64.efi), boot entry Boot0005 = \EFI\fedora\shimx64.efi, swap is zram without resume= (lockdown's
hibernation block is irrelevant).
Plan: Surface UEFI > Security > Secure Boot > Change configuration > "Microsoft & 3rd party CA" (also
installs the default keys, leaving Setup Mode), then verify with `sudo ./install.sh status` (new line:
secure boot state + which kernel keyring holds the DKMS key) and `journalctl -kb | grep -iE 'Loaded X.509|verification|lockdown'`.
Result (2026-10-29): Secure Boot enabled via "Microsoft & 3rd party CA"; firmware left Setup Mode (PK/KEK/db/dbx
present, db carries the Microsoft 2011 and 2023 CAs), kernel lockdown = integrity, the MOK list was loaded
("integrity: Loaded X.509 cert 'DKMS module signing key: 45a13fe9...'"), all four patched modules load with no
verification failure, SAM up with 6 devices, camera and audio working. Only lockdown message: hibernation
restricted (zram swap only, not used). User confirmed everything keeps working.

## 2026-10-29 night: fresh-machine review of install.sh (Secure Boot on)
Gaps found by walking a fresh Fedora 44 + Secure Boot install through `install.sh all`: (1) nothing enrolled
the DKMS key, so on a Secure Boot machine every patched module would be refused after the reboot, and because
depmod points at extra/ the stock copies would not load either (camera, audio worse than stock); now
ensure_mok_key() before the builds (dkms generate_mok) and ensure_mok_enrolled() after them (mokutil
--test-key / --list-new; with Secure Boot on and a terminal: mokutil --import with a one-time password, final
message explains the MOK manager steps; off: prints how to prepare). dkms itself only modprobes quietly after
install, so an unenrolled key causes no error at install time. (2) deps lacked git (iptsd clone), libcamera +
pipewire-plugin-libcamera (cmd_libcamera refuses without libcamera installed), guidelines-support-library-devel
(iptsd otherwise downloads GSL as a meson wrap), mokutil/keyutils/openssl. (3) cmd_kernel aborted when the
running kernel had no headers although another installed kernel had them (typical right after `install.sh
deps` pulled a newer kernel); now builds for every kernel with headers and warns to reboot into one of them;
module-resolution check is per kernel with modinfo -k; the no-dkms path warns that unsigned modules are refused
under Secure Boot. dkms ships /usr/lib/kernel/install.d/40-dkms.install, so new kernels are built at package
installation (network present); the boot-time dkms.service is only the fallback. README gained a "Before you
start" list (external keyboard needed until the first reboot, network, slow libcamera build, MOK manager
steps). Not verified on an actual fresh machine; the dkms/MOK/mokutil pieces were checked individually here.

## 2026-10-29 evening: first run on a second, fresh Surface Laptop 7 (model 2108, Secure Boot on)
Outcome: everything installed except the kernel modules. tools/report.sh (new) made the cause obvious:
`fetch-sources.sh: line 75: I: unbound variable` in the DKMS pre_build. `I=drivers/staging/media/ipu7` was
defined inside the "fetch from kernel.org" branch but used after it for the Kbuild layout, so every run that
took the "using cached sources" branch died under `set -u`. The first run fetched and cached the sources,
then failed later for an unrelated reason (the machine was rebooted/updated in between), and all retries hit
the cache. Never seen here because this machine's cache was created after the first successful builds.
Fixed by defining I at the top; verified both paths: the cached path for 7.2.13 and a full kernel/build.sh
from the cache (four modules, vermagic 7.2.13). Everything downstream of the missing modules matched the
report: stock registry (no SAM devices, "dropping unexpected command message"), stock ov02c10 ("external
clock 12000000 is not supported"), stock sdw-utils (sof_sdw probe failed with a duplicate SmartMic
kobject), DKMS status "added" only. What did work on the fresh machine: deps (127 + 210 packages), MOK key
generation + mokutil --import + MOK manager enrolment (key in the .platform keyring under Secure Boot),
configs, iptsd (/usr/local/sbin/iptsd running), libcamera 0.7.2-2.sl7 RPMs, initramfs rebuild with the
softdep and the omit list (lsinitrd shows pinctrl-intel-platform + SAM, no camera modules). install.sh now
tracks a failed build for the running kernel and ends "all" with NOT DONE instead of "All done".
Result: with the fetch-sources.sh fix, `sudo ./install.sh kernel` on the second machine built and installed the
modules; after the reboot everything works there too (user-confirmed 2026-10-29). First successful end-to-end
install on a fresh Fedora 44 + Secure Boot machine: deps -> configs -> kernel (DKMS, MOK enrolment) -> iptsd ->
libcamera, two reboots (MOK manager, then normal).

## 2026-10-29 night: second fresh install lost Wi-Fi: dkms.service ordering cycle
Cause: Fedora's dkms.service is `Before=network-pre.target graphical.target`; the drop-in added earlier today
(`After=network-online.target`, so the boot-time autoinstall can fetch sources) closes a cycle
dkms -> network-pre -> NetworkManager -> network.target -> NetworkManager-wait-online -> network-online -> dkms.
systemd breaks it by deleting one job, and which one varies per boot: here the journal shows
network-online.target, network-pre.target, dkms.service and, in the 12:50 boot, NetworkManager.service
("Job NetworkManager.service/start deleted to break ordering cycle"). On the second machine that was the
resolution after the fresh install, hence no Wi-Fi. Fix: the drop-in now resets `Before=` (so dkms no longer
orders itself before network-pre.target and does not hold up graphical.target behind NetworkManager-wait-
online's timeout) and keeps After/Wants=network-online.target. Immediate recovery on an affected boot:
`systemctl start NetworkManager`. tools/report.sh gained a network section (NM state, cycle messages, rfkill,
iwlwifi log). Lesson: check `journalctl -b | grep 'ordering cycle'` after adding any unit ordering.
Follow-up (third clean install, 17:07 boot): Wi-Fi lost again and the report showed the cycle unchanged:
systemd.unit(5) states that dependencies (After=, Before=, ...) cannot be reset to an empty list in a drop-in,
so `Before=` did nothing. Replaced the drop-in with our own unit, configs/etc/systemd/system/
surface-laptop-7-intel-dkms.service (After/Wants network-online.target, ConditionPathExists on the dkms
tree, `dkms autoinstall --kernelver %v`, no ordering against graphical.target); install.sh removes the old
drop-in wherever it exists (enable_dkms_fallback, called from kernel and configs) and enables the unit;
Fedora's dkms.service is left untouched (it may fail early without network; the new unit retries).
Second finding from the same run: mokutil's "input password:" prompts never appeared because the user ran
`install.sh all | tee`; mokutil writes prompts to stdout, which is fully buffered on a pipe, while reading
the password from the terminal. ensure_mok_enrolled now prints the instructions to /dev/tty and runs mokutil
with stdin/stdout/stderr on /dev/tty (falls back to a message when no tty). report.sh shows NM/dkms/fallback
unit states, any leftover drop-in, and dkms.service ordering. Camera, speakers, SAM (battery, charger, fan,
platform profile), iptsd all fine on that machine.
Result: `install.sh configs` from the new tarball on both machines; user confirms Wi-Fi back and no ordering
cycle in the journal (2026-10-29 evening). Three clean installs on the second machine in total; the install
path is now considered validated including the Secure Boot / MOK flow.
