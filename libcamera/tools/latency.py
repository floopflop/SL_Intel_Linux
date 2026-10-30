#!/usr/bin/python3 -I
"""Capture-to-delivery latency inside libcamera: for each completed frame, the difference between
the moment cam prints it (CLOCK_MONOTONIC, read here) and the frame's SensorTimestamp (start of
exposure, same clock). Includes the pipe/print overhead (~1 ms). Usage: latency.py [frames=120] [cam args]"""
import subprocess, sys, time, re, statistics
n = int(sys.argv[1]) if len(sys.argv) > 1 else 120
p = subprocess.Popen(["cam", "-c", "1", "--metadata", f"--capture={n}"] + sys.argv[2:], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
lat = []; seq = None; t_seen = None
for line in p.stdout:
    if "fps)" in line and "seq:" in line:
        t_seen = time.clock_gettime(time.CLOCK_MONOTONIC); seq = int(re.search(r"seq: (\d+)", line).group(1))
    m = re.match(r"\s*SensorTimestamp = (\d+)", line)
    if m and t_seen is not None:
        ts = int(m.group(1)) / 1e9
        if seq is not None and seq > 10: lat.append((t_seen - ts) * 1000)
        t_seen = None
p.wait()
lat.sort()
if lat: print(f"{len(lat)} frames: capture-start to delivery median {lat[len(lat)//2]:.1f} ms, p10 {lat[len(lat)//10]:.1f}, p90 {lat[9*len(lat)//10]:.1f} ms")
else: print("no SensorTimestamp metadata seen")
