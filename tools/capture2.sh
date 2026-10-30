#!/bin/bash
# Record raw heatmap reports (iptsd-dump) AND the evdev output at the same time.
# Run as root: sudo ./capture2.sh
set -u
D=$(cd "$(dirname "$0")" && pwd); OUT=${CAPTURE_DIR:-$D/../captures}
TS=$(date +%Y%m%d-%H%M%S)
HID=$(for h in /sys/class/hidraw/hidraw*; do grep -q 'HID_ID=0001:0000045E:00000C9F' $h/device/uevent && echo /dev/$(basename $h); done | head -1)
[ -n "$HID" ] || { echo "touchpad hidraw not found"; exit 1; }
echo "raw device: $HID"
/usr/local/bin/iptsd-dump "$HID" > "$OUT/raw-$TS.log" 2>&1 &
DUMP=$!
sleep 1
/usr/local/bin/../bin/true
python3 -I "$D/capture.py" "$OUT/touchpad-$TS.jsonl"
kill -INT $DUMP 2>/dev/null; sleep 1; kill $DUMP 2>/dev/null
mv "$(sed -n "s/.*Capturing HID traffic to //p" "$OUT/raw-$TS.log" | tr -d "\r")" "$OUT/raw-$TS.bin"; chmod 644 "$OUT"/raw-$TS.* "$OUT/touchpad-$TS.jsonl"
ls -la "$OUT"/raw-$TS.* "$OUT/touchpad-$TS.jsonl"
