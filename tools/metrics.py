#!/usr/bin/python3 -I
"""Summarize an iptsd-replay JSON stream: finger-count flicker, dropouts, phantoms, invalid contacts."""
import json, sys, collections
rows=[json.loads(l) for l in open(sys.argv[1]) if l.startswith('{"f"')]
FPS=float(sys.argv[2]) if len(sys.argv)>2 else 68.0
frames=[{c["i"]:c for c in r["c"] if c["i"]>=0} for r in rows]
counts=[len(f) for f in frames]
changes=sum(1 for a,b in zip(counts,counts[1:]) if a!=b)
hist=collections.Counter(counts)
invalid=sum(1 for f in frames for c in f.values() if not c["v"])
unstable=sum(1 for f in frames for c in f.values() if not c["s"])
# lifetimes of each (index, birth) contact
life=[]; alive={}
for n,f in enumerate(frames):
    for i in list(alive):
        if i not in f: life.append((i,alive[i],n-alive[i])); del alive[i]
    for i in f:
        if i not in alive: alive[i]=n
for i,b in alive.items(): life.append((i,b,len(frames)-b))
short=[l for l in life if l[2]<=3]
# dropouts: contact disappears and the same slot index is back within 0.4 s (not necessarily same finger, but indicative)
gaps=[]
for i,b,d in life:
    end=b+d
    for n in range(end, min(end+int(0.4*FPS), len(frames))):
        if i in frames[n]:
            gaps.append((n-end)/FPS*1000); break
print(f"frames={len(frames)} ({len(frames)/FPS:.0f}s @ {FPS:.0f}fps)  touching={sum(1 for c in counts if c)}")
print(f"fingers/frame: {dict(sorted(hist.items()))}")
print(f"finger-count changes: {changes}   contacts lifetimes: {len(life)}  short(<=3 frames): {len(short)}")
print(f"dropout gaps (slot back within 400ms): {len(gaps)}  " + (f"med {sorted(gaps)[len(gaps)//2]:.0f}ms max {max(gaps):.0f}ms" if gaps else ""))
print(f"invalid contact-frames: {invalid}   unstable contact-frames: {unstable}")
