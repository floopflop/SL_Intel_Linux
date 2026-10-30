#!/usr/bin/python3 -I
"""Trace AE behaviour: per-frame exposure/gain/frame duration from cam metadata plus the mean
luma of a static region (top-left corner, 320x240) from the frames themselves.
Usage: aetrace.py [frames=200] [extra cam args...]"""
import subprocess, sys, glob, os, re, tempfile
n = int(sys.argv[1]) if len(sys.argv) > 1 else 200; extra = sys.argv[2:]
base = os.environ.get("CAPTURE_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "captures"))
os.makedirs(base, exist_ok=True)
tmp = tempfile.mkdtemp(prefix="aetrace-", dir=base)
r = subprocess.run(["cam", "-c", "1", "--metadata", f"--capture={n}", f"--file={tmp}/f-#.bin"] + extra,
                   capture_output=True, text=True, timeout=180)
log = r.stdout + r.stderr
m = re.search(r"configuring streams: \(0\) (\d+)x(\d+)-(\w+)", log)
W, H, fmt = int(m.group(1)), int(m.group(2)), m.group(3)
iR, iG, iB = (2, 1, 0) if fmt.endswith("RGB8888") else (0, 1, 2)   # XRGB: B,G,R in memory
# per-frame metadata: a frame header line containing 'fps)' followed by tab-indented 'Name = value' lines
frames = []; cur = None
for line in log.splitlines():
    if "fps)" in line and "seq:" in line:
        cur = {"seq": int(re.search(r"seq: (\d+)", line).group(1))}; frames.append(cur)
    elif cur is not None and line.startswith("\t") and " = " in line:
        k, v = line.strip().split(" = ", 1); cur[k] = v
files = sorted(glob.glob(f"{tmp}/f-*.bin"))
def meanY(path):
    b = open(path, "rb").read(); stride = len(b) // H; bpp = stride // W
    acc = 0; cnt = 0
    for y in range(24, 264, 4):
        for x in range(24, 344, 4):
            o = y * stride + x * bpp; acc += 0.299 * b[o + iR] + 0.587 * b[o + iG] + 0.114 * b[o + iB]; cnt += 1
    return acc / cnt
ys = [meanY(f) for f in files]
# banding metric: per-row mean luma over the ceiling region (rows 24..344, every 4th column),
# compared with each row's median over the run; mains-light flicker with a rolling shutter shows
# up as horizontal stripes whose phase moves from frame to frame -> large per-frame deviation.
def rowmeans(path):
    b = open(path, "rb").read(); stride = len(b) // H; bpp = stride // W
    out = []
    for y in range(24, 344):
        acc = 0; cnt = 0
        for x in range(24, 344, 4):
            o = y * stride + x * bpp; acc += 0.299 * b[o + iR] + 0.587 * b[o + iG] + 0.114 * b[o + iB]; cnt += 1
        out.append(acc / cnt)
    return out
rm = [rowmeans(f) for f in files]
import statistics
med = [statistics.median(r[i] for r in rm) for i in range(len(rm[0]))]
band = []
for r, y in zip(rm, ys):
    scale = (sum(med) / len(med)) / (sum(r) / len(r)) if sum(r) else 1.0   # remove global brightness change
    d = [a * scale - m for a, m in zip(r, med)]
    band.append(statistics.pstdev(d))
# optionally keep 1:1 crops (centre 480x360) of frames around brightness jumps for inspection
save = os.environ.get("AETRACE_SAVE")
if save:
    os.makedirs(save, exist_ok=True)
    import struct, zlib
    def crop_png(path, out, x0, y0, w, h):
        b = open(path, "rb").read(); stride = len(b) // H; bpp = stride // W; rows = []
        for y in range(y0, y0 + h):
            row = bytearray()
            for x in range(x0, x0 + w):
                o = y * stride + x * bpp; row += bytes((b[o + iR], b[o + iG], b[o + iB]))
            rows.append(bytes(row))
        def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
        png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + \
              chunk(b"IDAT", zlib.compress(b"".join(b"\x00" + r for r in rows), 6)) + chunk(b"IEND", b"")
        open(out, "wb").write(png)
    flagged = [i for i in range(1, len(ys)) if abs(ys[i] - ys[i - 1]) > 2.0 and i > 3]
    want = sorted({j for i in flagged for j in (i - 1, i, i + 1) if 0 <= j < len(files)})[:24]
    for j in want:
        crop_png(files[j], f"{save}/frame-{j:03d}.png", (W - 480) // 2, (H - 360) // 2, 480, 360)
    print(f"saved {len(want)} crops to {save}")
for f in files: os.remove(f)
os.rmdir(tmp)
print(f"{W}x{H}: {len(frames)} metadata frames, {len(ys)} files")
print(f"{'i':>4s} {'exp_us':>7s} {'mod8333':>7s} {'gain':>6s} {'frame_us':>8s} {'meanY':>6s}  dY  {'band':>5s}")
prev = None
for i, (fr, y) in enumerate(zip(frames, ys)):
    e = fr.get("ExposureTime", "?"); g = fr.get("AnalogueGain", "?"); d = fr.get("FrameDuration", "?")
    try: g = f"{float(g):.2f}"
    except ValueError: pass
    dy = "" if prev is None else f"{y - prev:+.1f}"
    flag = " <--" if prev is not None and abs(y - prev) > 2.0 else ""
    try: mod = f"{float(e) % 8333.3:7.0f}"
    except ValueError: mod = "?"
    if i < 5 or i % 5 == 0 or flag: print(f"{i:4d} {e:>7s} {mod:>7s} {g:>6s} {d:>8s} {y:6.1f} {dy:>5s} {band[i]:5.2f}{flag}")
    prev = y
