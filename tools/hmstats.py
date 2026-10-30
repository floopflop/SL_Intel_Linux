#!/usr/bin/python3 -I
"""Contact signal statistics from an iptsd-replay run with IPTSD_REPLAY_HEATMAP=1.
Signal = baseline (mode) - cell value (IPTS heatmaps dip under a finger). Reports the noise floor,
contact peak distributions for 1- and 2-finger frames, and the strength of fingers that vanish in a
2 -> 1 -> 2 flicker. Usage: hmstats.py <replay.jsonl>"""
import json, sys, statistics
rows = [json.loads(l) for l in open(sys.argv[1]) if l.startswith('{"f"')]
meta = [json.loads(l) for l in open(sys.argv[1]) if l.startswith('{"meta"')][0]["meta"]
R, C = meta["rows"], meta["cols"]
def mode(h):
    cnt = {}
    for v in h: cnt[v] = cnt.get(v, 0) + 1
    return max(cnt.items(), key=lambda kv: kv[1])[0]
def peak(h, m, c):
    cx = int(round(c["x"] * (C - 1))); cy = int(round(c["y"] * (R - 1)))
    return max(m - h[yy * C + xx] for yy in range(max(0, cy - 1), min(R, cy + 2)) for xx in range(max(0, cx - 1), min(C, cx + 2)))
noise = []; peaks = {1: [], 2: [], 3: []}; flick = []; weak2 = 0; n2 = 0
for k, r in enumerate(rows):
    if "h" not in r: continue
    h = bytes.fromhex(r["h"]); m = mode(h); cs = r["c"]
    far = [m - h[y * C + x] for y in range(R) for x in range(C)
           if all(abs(x - c["x"] * (C - 1)) >= 3 or abs(y - c["y"] * (R - 1)) >= 3 for c in cs)]
    if far: noise.append(statistics.pstdev(far))
    pk = [peak(h, m, c) for c in cs]
    if len(cs) in peaks: peaks[len(cs)] += pk
    if len(cs) == 2:
        n2 += 1
        if min(pk) < 40: weak2 += 1
    if 0 < k < len(rows) - 1 and "h" in rows[k - 1] and len(rows[k - 1]["c"]) == 2 and len(cs) == 1 and len(rows[k + 1]["c"]) == 2:
        prev = rows[k - 1]; hp = bytes.fromhex(prev["h"]); mp = mode(hp)
        lost = max(prev["c"], key=lambda c: (c["x"] - cs[0]["x"]) ** 2 + (c["y"] - cs[0]["y"]) ** 2)
        flick.append(peak(hp, mp, lost))
def q(v):
    v = sorted(v); return f"n={len(v):5d} p10 {v[len(v) // 10]:5.1f} median {v[len(v) // 2]:5.1f} p90 {v[9 * len(v) // 10]:5.1f}" if v else "n=0"
print(f"{len(rows)} frames, {C}x{R} cells, thresholds {meta['athresh']}/{meta['dthresh']}")
print("noise floor (std of cells away from contacts): " + q(noise))
for n in (1, 2, 3): print(f"contact peak, {n}-finger frames:              " + q(peaks[n]))
print(f"2-finger frames with a weak contact (peak < 40): {weak2} of {n2}")
print("peak of the finger that vanishes in a 2->1->2 flicker: " + q(flick))
