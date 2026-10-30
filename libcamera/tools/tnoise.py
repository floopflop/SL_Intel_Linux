#!/usr/bin/python3 -I
"""Temporal noise: capture a static scene and report the per-pixel standard deviation over frames,
binned by mean luma, plus the chroma (Cb/Cr) temporal std. This is the noise a temporal filter sees.
Usage: tnoise.py [frames=40] [skip=30] [cam args...]   (env: LIBCAMERA_* as usual)"""
import subprocess, sys, glob, os, re, tempfile, math
n = int(sys.argv[1]) if len(sys.argv) > 1 else 40; skip = int(sys.argv[2]) if len(sys.argv) > 2 else 30
extra = sys.argv[3:]; base = os.environ.get("CAPTURE_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "captures"))
os.makedirs(base, exist_ok=True)
tmp = tempfile.mkdtemp(prefix="tnoise-", dir=base)
r = subprocess.run(["cam", "-c", "1", f"--capture={n + skip}", f"--file={tmp}/f-#.bin"] + extra, capture_output=True, text=True, timeout=180)
log = r.stdout + r.stderr
m = re.search(r"configuring streams: \(0\) (\d+)x(\d+)-(\w+)", log); W, H, fmt = int(m.group(1)), int(m.group(2)), m.group(3)
files = sorted(glob.glob(f"{tmp}/f-*.bin"))[skip:]
iR, iG, iB = (2, 1, 0) if fmt.endswith("RGB8888") else (0, 1, 2)
# subsampled grid of pixels
xs = range(8, W - 8, 6); ys = range(8, H - 8, 6)
Y = {}; Cb = {}; Cr = {}
for f in files:
    b = open(f, "rb").read(); stride = len(b) // H; bpp = stride // W
    for y in ys:
        row = y * stride
        for x in xs:
            o = row + x * bpp; R, G, B = b[o + iR], b[o + iG], b[o + iB]
            yy = 0.299 * R + 0.587 * G + 0.114 * B
            Y.setdefault((x, y), []).append(yy); Cb.setdefault((x, y), []).append(0.564 * (B - yy)); Cr.setdefault((x, y), []).append(0.713 * (R - yy))
def std(v): mu = sum(v) / len(v); return math.sqrt(sum((a - mu) ** 2 for a in v) / (len(v) - 1))
bins = {}
for k, v in Y.items():
    mu = sum(v) / len(v); i = min(int(mu // 16), 15)
    bins.setdefault(i, []).append((std(v), std(Cb[k]), std(Cr[k])))
print(f"{W}x{H} {fmt}: {len(files)} frames, {len(Y)} pixels; sigma = per-pixel std over frames (8-bit codes)")
print(f"{'Y bin':>8s} {'pixels':>7s} {'sigmaY':>7s} {'sigmaCb':>8s} {'sigmaCr':>8s}")
tot = []
for i in sorted(bins):
    v = bins[i]; tot += v
    if len(v) >= 20: print(f"{i*16:3d}-{i*16+15:3d} {len(v):7d} {sum(a for a,_,_ in v)/len(v):7.2f} {sum(b for _,b,_ in v)/len(v):8.2f} {sum(c for _,_,c in v)/len(v):8.2f}")
print(f"{'all':>8s} {len(tot):7d} {sum(a for a,_,_ in tot)/len(tot):7.2f} {sum(b for _,b,_ in tot)/len(tot):8.2f} {sum(c for _,_,c in tot)/len(tot):8.2f}")
for f in files: os.remove(f)
for f in glob.glob(f"{tmp}/*"): os.remove(f)
os.rmdir(tmp)
