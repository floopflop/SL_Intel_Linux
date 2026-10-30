#!/usr/bin/python3 -I
"""Measure output noise through libcamera's software ISP.
Usage: noise.py label [frames=60] [extra cam args...]
Captures `frames` frames with cam, uses the last 12: per-pixel temporal std of Y/Cb/Cr and
spatial chroma high-pass energy, for a centre and a corner region. Writes 1:1 crops of the
last frame to webcam/noise-<label>-{centre,corner}.png. Honour LIBCAMERA_* env for variants."""
import os, subprocess, sys, struct, zlib, glob, os, re, tempfile, math
label = sys.argv[1]; n = int(sys.argv[2]) if len(sys.argv) > 2 else 60; extra = sys.argv[3:]
K = 12
base = os.environ.get("CAPTURE_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "captures"))
os.makedirs(base, exist_ok=True)
tmp = tempfile.mkdtemp(prefix="noise-", dir=base)
r = subprocess.run(["cam", "-c", "1", "--metadata", f"--capture={n}", f"--file={tmp}/f-#.bin"] + extra,
                   capture_output=True, text=True, timeout=120)
log = r.stdout + r.stderr
m = re.search(r"configuring streams: \(0\) (\d+)x(\d+)-(\w+)", log)
W, H, fmt = int(m.group(1)), int(m.group(2)), m.group(3)
fps = re.findall(r"\(([0-9.]+) fps\)", log)
files = sorted(glob.glob(f"{tmp}/f-*.bin"))[-K:]
frames = [open(f, "rb").read() for f in files]
stride = len(frames[0]) // H; bpp = stride // W
for p in glob.glob(f"{tmp}/*"): os.remove(p)
os.rmdir(tmp)

# memory order of the first three bytes: XBGR/ABGR -> R,G,B ; XRGB/ARGB -> B,G,R
iR, iG, iB = (2, 1, 0) if fmt.endswith("RGB8888") else (0, 1, 2)
def yuv(b, o):
    R, G, B = b[o + iR], b[o + iG], b[o + iB]
    return (0.299 * R + 0.587 * G + 0.114 * B,
            -0.168736 * R - 0.331264 * G + 0.5 * B,
            0.5 * R - 0.418688 * G - 0.081312 * B)

def region(x0, y0, w, h, step=2):
    """temporal std (Y, Cb, Cr) averaged over the region, and spatial chroma high-pass std."""
    tv = [0.0, 0.0, 0.0]; cnt = 0
    # per-frame region means, so a drifting/flickering AE does not count as pixel noise
    pts = [(y * stride + x * bpp) for y in range(y0, y0 + h, step) for x in range(x0, x0 + w, step)]
    fm = []
    for b in frames:
        acc = [0.0, 0.0, 0.0]
        for o in pts:
            v = yuv(b, o); acc[0] += v[0]; acc[1] += v[1]; acc[2] += v[2]
        fm.append([a / len(pts) for a in acc])
    for o in pts:
        vals = [[a - m for a, m in zip(yuv(b, o), fm[i])] for i, b in enumerate(frames)]
        for c in range(3):
            mu = sum(v[c] for v in vals) / K
            tv[c] += math.sqrt(sum((v[c] - mu) ** 2 for v in vals) / (K - 1))
        cnt += 1
    tv = [t / cnt for t in tv]
    global last_mean
    last_mean = fm[-1]
    # spatial: chroma of last frame minus 5x5 box mean, std over region (speckle energy)
    last = frames[-1]; hp = [0.0, 0.0]; hc = 0
    for y in range(y0 + 2, y0 + h - 2, step):
        for x in range(x0 + 2, x0 + w - 2, step):
            c0 = yuv(last, y * stride + x * bpp)
            acc = [0.0, 0.0]
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    c = yuv(last, (y + dy) * stride + (x + dx) * bpp)
                    acc[0] += c[1]; acc[1] += c[2]
            hp[0] += (c0[1] - acc[0] / 25) ** 2; hp[1] += (c0[2] - acc[1] / 25) ** 2; hc += 1
    return tv, [math.sqrt(v / hc) for v in hp]

def crop_png(out, x0, y0, w, h):
    b = frames[-1]; rows = []
    for y in range(y0, y0 + h):
        row = bytearray()
        for x in range(x0, x0 + w):
            o = y * stride + x * bpp; row += bytes((b[o + iR], b[o + iG], b[o + iB]))
        rows.append(bytes(row))
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + \
          chunk(b"IDAT", zlib.compress(b"".join(b"\x00" + r for r in rows), 6)) + chunk(b"IEND", b"")
    open(out, "wb").write(png)

cw, ch = 320, 240
regs = {"centre": ((W - cw) // 2, (H - ch) // 2), "corner": (24, 24), "top": ((W - cw) // 2, 24)}
meta = {k: v for k, v in re.findall(r"(AnalogueGain|ExposureTime|FrameDuration|ColourTemperature) = (\S+)", log)}
print(f"{label}: {W}x{H} {fmt}, last fps {fps[-1] if fps else '?'}, {len(frames)} frames analysed; "
      f"gain {meta.get('AnalogueGain','?')} exposure {meta.get('ExposureTime','?')} us frame {meta.get('FrameDuration','?')} us ct {meta.get('ColourTemperature','?')} K")
print(f"{'region':8s} {'tY':>6s} {'tCb':>6s} {'tCr':>6s} | {'sCb':>6s} {'sCr':>6s}   (temporal std | spatial chroma HP std, 8-bit)")
for name, (x0, y0) in regs.items():
    tv, sp = region(x0, y0, cw, ch)
    print(f"{name:8s} {tv[0]:6.2f} {tv[1]:6.2f} {tv[2]:6.2f} | {sp[0]:6.2f} {sp[1]:6.2f}   mean Y/Cb/Cr {last_mean[0]:5.1f}/{last_mean[1]:+5.1f}/{last_mean[2]:+5.1f}")
    crop_png(f"{base}/noise-{label}-{name}.png", x0, y0, cw, ch)
bench = [l for l in log.splitlines() if "Benchmark" in l or "us/frame" in l]
print("\n".join(bench[-2:]))
warn = [l for l in log.splitlines() if re.search(r"WARN|ERROR|Failed", l) and "EGL" not in l]
print("\n".join(warn[:6]))
