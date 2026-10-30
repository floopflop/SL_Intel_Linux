#!/usr/bin/python3 -I
"""Capture frames through libcamera's software ISP and save the last one as a PNG (half size).
Usage: snap.py out.png [frames=90]  -- lets AE/AWB settle before the saved frame."""
import subprocess, sys, struct, zlib, glob, os, re, tempfile
out = sys.argv[1]; n = int(sys.argv[2]) if len(sys.argv) > 2 else 90
base = os.environ.get("CAPTURE_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "captures")); os.makedirs(base, exist_ok=True)
tmp = tempfile.mkdtemp(prefix="snap-", dir=base)
r = subprocess.run(["cam", "-c", "1", f"--capture={n}", f"--file={tmp}/f-#.bin"],
                   capture_output=True, text=True, timeout=90)
log = r.stdout + r.stderr
m = re.search(r"configuring streams: \(0\) (\d+)x(\d+)-(\w+)", log)
fps = re.findall(r"\(([0-9.]+) fps\)", log)
W, H, fmt = int(m.group(1)), int(m.group(2)), m.group(3)
f = sorted(glob.glob(f"{tmp}/f-*.bin"))[-1]
raw = open(f, "rb").read(); stride = len(raw) // H; bpp = stride // W
rows = []
for y in range(0, H, 2):
    row = bytearray()
    for x in range(0, W, 2):
        o = y * stride + x * bpp
        row += bytes((raw[o], raw[o + 1], raw[o + 2]))   # memory order R,G,B for ABGR8888
    rows.append(bytes(row))
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W // 2, H // 2, 8, 2, 0, 0, 0)) + \
      chunk(b"IDAT", zlib.compress(b"".join(b"\x00" + r for r in rows), 6)) + chunk(b"IEND", b"")
open(out, "wb").write(png)
# simple exposure/colour statistics on the saved frame
import statistics
R = statistics.mean(raw[y * stride + x * bpp] for y in range(0, H, 8) for x in range(0, W, 8))
G = statistics.mean(raw[y * stride + x * bpp + 1] for y in range(0, H, 8) for x in range(0, W, 8))
B = statistics.mean(raw[y * stride + x * bpp + 2] for y in range(0, H, 8) for x in range(0, W, 8))
for p in glob.glob(f"{tmp}/*"): os.remove(p)
os.rmdir(tmp)
print(f"{W}x{H} {fmt}, last fps {fps[-1] if fps else '?'}; mean R/G/B = {R:.0f}/{G:.0f}/{B:.0f}; wrote {out}")
warn = [l for l in log.splitlines() if re.search(r"WARN|ERROR|Failed", l) and "EGL" not in l]
print("\n".join(warn[:6]))
