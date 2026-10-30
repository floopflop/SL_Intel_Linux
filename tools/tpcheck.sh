#!/bin/bash
# Which touchpad device is feeding libinput right now?
# Counts evdev events for N seconds (default 6) on the raw quickspi-hid touchpad
# node (firmware fallback mode) and on the IPTSD Virtual Touchpad node.
# Move one finger around on the touchpad the whole time.  Run as root.
set -u
N=${1:-6}
node_for() {  # $1 = device name prefix
	awk -v pat="$1" '
		/^N: Name=/ { match($0, /Name="([^"]*)"/, m); name = m[1] }
		/^H: Handlers=/ && index(name, pat) == 1 { for (i = 1; i <= NF; i++) if ($i ~ /^event/) print "/dev/input/" $i }
	' /proc/bus/input/devices | head -1
}
RAW=$(node_for "quickspi-hid")
VIRT=$(node_for "IPTSD Virtual Touchpad")
echo "raw firmware touchpad : ${RAW:-<none>}"
echo "iptsd virtual touchpad: ${VIRT:-<none>}"
echo "iptsd process         : $(pgrep -a iptsd || echo '<not running>')"
echo "THC runtime PM        : $(cat /sys/devices/pci0000:00/0000:00:10.1/power/runtime_status 2>/dev/null)"
echo
echo "Sampling for ${N}s - keep one finger moving on the touchpad..."
T=$(mktemp -d)
[ -n "$RAW" ]  && (timeout "$N" cat "$RAW"  | wc -c > "$T/raw")  &
[ -n "$VIRT" ] && (timeout "$N" cat "$VIRT" | wc -c > "$T/virt") &
wait
raw=$(( $(cat "$T/raw" 2>/dev/null || echo 0) / 24 ))
virt=$(( $(cat "$T/virt" 2>/dev/null || echo 0) / 24 ))
rm -rf "$T"
printf '\n%-24s %6d events\n%-24s %6d events\n' "raw firmware touchpad:" "$raw" "iptsd virtual touchpad:" "$virt"
echo
if [ "$raw" -gt 0 ] && [ "$virt" -gt 0 ]; then
	echo "RESULT: BOTH devices are reporting -> libinput gets doubled, unsmoothed input (twitchy)."
elif [ "$raw" -gt 0 ]; then
	echo "RESULT: only the raw firmware touchpad reports -> device fell back to native mode, iptsd gets nothing."
elif [ "$virt" -gt 0 ]; then
	echo "RESULT: only iptsd reports -> mode is correct; twitchiness is not a device-mode problem."
else
	echo "RESULT: no events at all (did you move a finger?)."
fi
