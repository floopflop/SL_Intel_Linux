#!/usr/bin/python3 -I
"""Generate a libcamera software-ISP tuning file for the OV02C10 module of the Surface
Laptop 7 (Intel) from the module's Intel CPFF tuning container (.aiqb).

Records used (layouts verified against the data, see FINDINGS.md):
  black_level              : 64 DN at 10 bits -> 4096 in the 16-bit units BlackLevel expects
  lens_shading_4x4         : header 46 B (u16 sets/channels/W/H at offset 16, first set's
                             chromaticity at 28), then per set 4 grids of WxH u16 (Q5.11, 2048 =
                             unity) in the sensor's Bayer order Gr, R, B, Gb, followed by a 22-byte
                             descriptor carrying the NEXT set's chromaticity (floats at +4)
  advanced_color_matrices  : u16 light-source count, u16 sector count, u32 table, then per light
                             source a 24-byte header (chromaticity at +4, CCT at +20) and
                             (sectors+1) 3x3 float matrices, the first being the base CCM
Shading grids are fitted to libipa's radial polynomial gain = 1 + sum k_i r^(2i+2), r normalised
to the frame corner, using the 16:9 frame geometry (pure-python least squares)."""
import os, struct, sys, math, statistics
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cpff

FRAME_W, FRAME_H = 1928, 1092
OPTS = {a.split("=", 1)[0]: (a.split("=", 1)[1] if "=" in a else True) for a in sys.argv[1:] if a.startswith("--")}
sys.argv = [a for a in sys.argv if not a.startswith("--")]
GRID_ORDER = sys.argv[3].split(",") if len(sys.argv) > 3 else ["gr", "r", "b", "gb"]   # SGRBG sensor: grids in its Bayer order
NVM_W, NVM_H = 17, 13

def records(buf):
    out = {}
    for tag, off, size in cpff.walk(buf):
        if tag == 'LCMC':
            for ro, rs, fmt, key, name in cpff.records(buf, off + 32):
                out[name] = buf[ro + 8: ro + rs]
    return out

def sample_grid(g, W, H, u, v):
    x = u * (W - 1); y = v * (H - 1); x0 = min(int(x), W - 2); y0 = min(int(y), H - 2); fx = x - x0; fy = y - y0
    return (g[y0 * W + x0] * (1 - fx) + g[y0 * W + x0 + 1] * fx) * (1 - fy) + \
           (g[(y0 + 1) * W + x0] * (1 - fx) + g[(y0 + 1) * W + x0 + 1] * fx) * fy

def poly_gain(k, u, v):
    """Gain of a fitted radial polynomial at normalised frame position (u, v)."""
    X = (u - 0.5) * FRAME_W; Y = (v - 0.5) * FRAME_H
    rr = math.hypot(X, Y) / math.hypot(FRAME_W / 2, FRAME_H / 2)
    return 1.0 + sum(k[i] * rr ** (2 * (i + 1)) for i in range(5))

def nvm_lsc_sets(dump, abs_sets, ratio_sets, W, H):
    """Per-unit shading sets: Intel's formula gain = ratio_record x (1023 / NVM response)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("eeprom_nvm", os.path.join(os.path.dirname(os.path.abspath(__file__)), "eeprom_nvm.py"))
    nvm = importlib.util.module_from_spec(spec); spec.loader.exec_module(nvm)
    e = nvm.parse(nvm.load(dump))
    lights = e["lights"]
    if not lights:
        raise SystemExit("EEPROM dump holds no complete light set (need the full 8 KB read)")
    names = ["r", "gr", "gb", "b"]
    def colour_pattern(gain_of):
        """log(R/G) and log(B/G) at the NVM nodes, relative to the centre."""
        out = []
        for j in range(NVM_H):
            for i in range(NVM_W):
                u = i / (NVM_W - 1); v = j / (NVM_H - 1)
                g = {n: gain_of(n, u, v) for n in names}
                G = (g["gr"] + g["gb"]) / 2
                out.append((math.log(g["r"] / G), math.log(g["b"] / G)))
        return out
    light_patterns = []
    for light in lights:
        gains = {n: nvm.gains(light[n]) for n in names}
        light_patterns.append(colour_pattern(lambda n, u, v, gains=gains: sample_grid(gains[n], NVM_W, NVM_H, u, v)))
    out = []
    report = []
    for ct, chrom, grids_abs, grids_ratio in zip([a[0] for a in abs_sets], [a[1] for a in abs_sets], [a[2] for a in abs_sets], ratio_sets):
        idx = {n: GRID_ORDER.index(n) for n in names}
        # golden NVM of this set = absolute / ratio; match the light with the closest colour shading
        golden = colour_pattern(lambda n, u, v: sample_grid(grids_abs[idx[n]], W, H, u, v) / sample_grid(grids_ratio[idx[n]], W, H, u, v))
        best = min(range(len(lights)), key=lambda l: sum((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 for a, b in zip(light_patterns[l], golden)))
        if "--light" in OPTS:
            best = int(OPTS["--light"])
        light = lights[best]
        tables = {}
        for n in names:
            vals = []
            for j in range(NVM_H):
                for i in range(NVM_W):
                    u = i / (NVM_W - 1); v = j / (NVM_H - 1)
                    r = 1.0 if "--no-ratio" in OPTS else sample_grid(grids_ratio[idx[n]], W, H, u, v) / 2048.0
                    g = 1023.0 / light[n][j * NVM_W + i]
                    vals.append(r * g)
            tables[n] = vals
        out.append((ct, tables))
        report.append((ct, best, {n: round(max(tables[n]), 2) for n in names}))
    return out, report, len(lights)

def grid_sets_from_poly(poly_sets):
    out = []
    for ct, comps in poly_sets:
        tables = {}
        for n, k in comps.items():
            tables[n] = [poly_gain(k, i / (NVM_W - 1), j / (NVM_H - 1)) for j in range(NVM_H) for i in range(NVM_W)]
        out.append((ct, tables))
    return out

def emit_grid_sets(L, grid_sets):
    # identical tables for every set (one light, no ratio record): a single set is enough
    if len(grid_sets) > 1 and all(gs[1] == grid_sets[0][1] for gs in grid_sets[1:]):
        grid_sets = [(4000, grid_sets[0][1])]
    L += ['  - LensShadingCorrection:', '      type: grid', f'      width: {NVM_W}', f'      height: {NVM_H}', '      sets:']
    for ct, tables in grid_sets:
        L.append(f'        - ct: {ct}')
        for n in ("r", "gr", "gb", "b"):
            vals = ", ".join(f"{v:.4f}" for v in tables[n])
            L.append(f'          {n}: [ {vals} ]')

def fit_radial(g, W, H):
    cy, cx = (H - 1) / 2, (W - 1) / 2
    m = math.hypot(FRAME_W / 2, FRAME_H / 2)
    A = []; y = []
    for r in range(H):
        for x in range(W):
            X = (x - cx) / (W - 1) * FRAME_W; Y = (r - cy) / (H - 1) * FRAME_H
            rr = math.hypot(X, Y) / m
            A.append([rr ** (2 * (i + 1)) for i in range(5)]); y.append(g[r * W + x] / 2048 - 1)
    N = [[sum(A[k][i] * A[k][j] for k in range(len(A))) for j in range(5)] for i in range(5)]
    b = [sum(A[k][i] * y[k] for k in range(len(A))) for i in range(5)]
    M = [N[i] + [b[i]] for i in range(5)]
    for i in range(5):
        p = max(range(i, 5), key=lambda r: abs(M[r][i])); M[i], M[p] = M[p], M[i]
        for r in range(5):
            if r != i:
                f = M[r][i] / M[i][i]; M[r] = [a - f * c for a, c in zip(M[r], M[i])]
    k = [M[i][5] / M[i][i] for i in range(5)]
    rms = math.sqrt(statistics.mean((sum(k[i] * A[j][i] for i in range(5)) - y[j]) ** 2 for j in range(len(A))))
    return k, rms

def main(aiqb, out):
    buf = open(aiqb, 'rb').read(); rec = records(buf)
    # --- CCMs
    d = rec[25]; ls, sec = struct.unpack_from('<HH', d, 0); p = 4 + 4 * sec; ccms = []
    for _ in range(ls):
        chrom = struct.unpack_from('<2f', d, p + 4); cct, = struct.unpack_from('<I', d, p + 20); p += 24
        m = struct.unpack_from('<9f', d, p); p += 36 * (sec + 1)
        ccms.append((cct, chrom, m))
    ccms.sort()
    # --- LSC
    d = rec[28]; NS, NC, W, H = struct.unpack_from('<4H', d, 16)
    G = W * H * 2; SET = NC * G + 22; base = 46
    chroms = [struct.unpack_from('<2f', d, 28)]
    for s in range(1, NS):
        chroms.append(struct.unpack_from('<2f', d, base + s * SET - 22 + 4))
    sets = []
    for s in range(NS):
        grids = [struct.unpack_from(f'<{W*H}H', d, base + s * SET + c * G) for c in range(NC)]
        for g in grids:
            assert min(g) == 2048, "grid minimum is not unity"
        # colour temperature: nearest CCM illuminant by chromaticity
        cct = min(ccms, key=lambda c: math.hypot(c[1][0] - chroms[s][0], c[1][1] - chroms[s][1]))[0]
        sets.append([cct, chroms[s], grids])
    # make ct keys unique (the algorithm keys sets by ct)
    sets.sort(key=lambda t: t[0]); used = set()
    for t in sets:
        while t[0] in used: t[0] += 1
        used.add(t[0])
    L = ['# SPDX-License-Identifier: CC0-1.0', '%YAML 1.1', '---',
         '# OmniVision OV02C10 front camera of the Surface Laptop for Business 7th Edition with Intel.',
         '# Generated by gen-ov02c10-tuning.py from the module tuning data shipped with the Windows',
         '# driver package (configuration data, no code). Black level 64 DN at 10 bits = 4096 in the',
         '# 16-bit units BlackLevel expects. Shading sets and colour matrices are keyed by colour',
         '# temperature; sets were matched to the matrix illuminants by chromaticity.',
         'version: 1', 'algorithms:', '  - BlackLevel:', '      blackLevel: 4096']
    report = []
    # the "ratio" record (33) has the same layout as the absolute record (28); keep both aligned with sets
    d33 = rec[33]
    ratio_by_chrom = {}
    for s_ in range(NS):
        chrom_ = struct.unpack_from('<2f', d33, 28) if s_ == 0 else struct.unpack_from('<2f', d33, base + s_ * SET - 22 + 4)
        ratio_by_chrom[tuple(round(c, 5) for c in chrom_)] = [struct.unpack_from(f'<{W*H}H', d33, base + s_ * SET + c * G) for c in range(NC)]
    ratio_sets = [ratio_by_chrom[tuple(round(c, 5) for c in chrom)] for _, chrom, _ in sets]
    poly_sets = []
    for cct, chrom, grids in sets:
        comps = {}
        for key in ("r", "gr", "gb", "b"):
            g = grids[GRID_ORDER.index(key)]
            k, rms = fit_radial(g, W, H); report.append((cct, key, rms, max(g) / 2048)); comps[key] = k
        poly_sets.append((cct, comps))
    if "--eeprom" in OPTS:
        grid_sets, nvm_report, nlights = nvm_lsc_sets(OPTS["--eeprom"], sets, ratio_sets, W, H)
        L += ['  # Per-unit shading from the module EEPROM (17x13 measured response per channel and light),',
              '  # combined with the tuning container\'s ratio record as the Windows stack does:',
              '  # gain = ratio x 1023 / response. Grids span the full frame.']
        emit_grid_sets(L, grid_sets)
        print(f"EEPROM: {nlights} light(s); per set (ct, light, max gain r/gr/gb/b):")
        for r in nvm_report: print("  ", r)
    elif "--grid-from-poly" in OPTS:
        L += ['  # Polynomial sets resampled as 17x13 grids (validation of the grid path).']
        emit_grid_sets(L, grid_sets_from_poly(poly_sets))
    else:
        L += ['  - LensShadingCorrection:', '      type: polynomial', '      sets:']
        for cct, comps in poly_sets:
            L.append(f'        - ct: {cct}')
            for key in ("r", "gr", "gb", "b"):
                k = comps[key]
                L.append(f'          {key}:'); L.append('            cx: 0.5'); L.append('            cy: 0.5')
                for i in range(5): L.append(f'            k{i}: {k[i]:.6f}')
    L += ['  # Luminance weighted grey world: the bright, unclipped part of the frame sets the',
          '  # balance, so a face or coloured clothing filling the frame does not tint the walls.',
          '  - Awb:', '      lumaWeight: 1.0', '      clipBins: 16',
          '  - Ccm:', '      ccms:']
    for cct, chrom, m in ccms:
        L.append(f'        - ct: {cct}')
        L.append(f'          ccm: [ {m[0]: .4f}, {m[1]: .4f}, {m[2]: .4f},')
        L.append(f'                 {m[3]: .4f}, {m[4]: .4f}, {m[5]: .4f},')
        L.append(f'                 {m[6]: .4f}, {m[7]: .4f}, {m[8]: .4f} ]')
    L += ['  - Adjust:',
          '  # Keep the nominal frame rate (33 ms exposure) until the analogue gain reaches this',
          '  # value; only then lengthen the frame (down to half the frame rate). Motion blur at',
          '  # long exposures is more visible on a video call than the gain noise the denoiser removes.',
          '  # Faster convergence than the stock 0.04 / 0.15: from a dark start the gain climbs in about a',
          '  # second instead of several; near the target the error-proportional step is still small.',
          '  # Anti-banding for 60 Hz mains lighting: exposure held to multiples of 8333 us, remainder in gain.',
          '  # exposureValue: brightness target in stops from the controller default (which clips white walls);',
          '  # hysteresis: half-width of the MSV band in which the exposure is left alone (0.2 = stock).',
          '  - Agc:', '      longExposureGain: 12.0', '      proportionalGain: 0.16', '      maxStep: 0.5', '      flickerPeriod: 8333',
          '      exposureValue: -0.5', '      hysteresis: 0.1',
          '  # Spatial denoise (GPU debayer only). Sigmas are 8-bit output code values of the gamma',
          '  # encoded image, interpolated in log(analogue gain). Chroma speckle is the visible',
          '  # artefact at high gain; luma is only lightly filtered to keep detail.',
          '  - Denoise:',
          '      chroma:',
          '        - { gain: 1.0, sigma: 3.0 }',
          '        - { gain: 4.0, sigma: 10.0 }',
          '        - { gain: 16.0, sigma: 22.0 }',
          '      luma:',
          '        - { gain: 1.0, sigma: 0.0 }',
          '        - { gain: 4.0, sigma: 2.0 }',
          '        - { gain: 16.0, sigma: 5.0 }',
          '      lumaStrength: 0.5',
          '      # Temporal (recursive) filter: per-pixel temporal noise by gain (8-bit codes, tools/tnoise.py),',
          '      # luma / chroma weights of the previous frame where nothing moved (luma kept low: it is',
          '      # the lag the eye notices on slow motion), motion thresholds in sigmas.',
          '      temporal:',
          '        - { gain: 1.0, sigma: 2.5 }',
          '        - { gain: 4.0, sigma: 3.5 }',
          '        - { gain: 16.0, sigma: 6.5 }',
          '      temporalStrength: 0.5',
          '      temporalChromaStrength: 0.75',
          '      temporalMotionLow: 1.5',
          '      temporalMotionHigh: 3.0',
          '...']
    open(out, 'w').write('\n'.join(L) + '\n')
    print(f"wrote {out}: {len(sets)} shading sets, {len(ccms)} colour matrices")
    for cct, chrom, _ in sets: print(f"  shading set ct {cct} K  chromaticity {chrom[0]:.3f},{chrom[1]:.3f}")
    for cct, key, rms, corner in report: print(f"  fit {cct}K {key:>2}: RMS {rms:.3f}  corner gain {corner:.2f}")

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
