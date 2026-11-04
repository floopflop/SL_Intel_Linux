#!/bin/bash
# Which touchpad device is feeding libinput right now?
# Counts evdev events for N seconds (default 6) on the raw quickspi-hid touchpad nodes
# (hid-multitouch's "Mouse" and "Touchpad" nodes, which carry the firmware's native-mode
# reports; its "UNKNOWN" nodes never report) and on the IPTSD Virtual Touchpad node.
# Move one finger around on the touchpad the whole time.  Run as root.
set -u
N=${1:-6}
nodes_for() {  # $1 = regular expression on the device name; prints /dev/input/eventN for every match
	awk -v pat="$1" '
		/^N: Name=/ { match($0, /Name="([^"]*)"/, m); name = m[1] }
		/^H: Handlers=/ && name ~ pat { for (i = 1; i <= NF; i++) if ($i ~ /^event/) print "/dev/input/" $i }
	' /proc/bus/input/devices
}
RAW=$(nodes_for '^quickspi-hid .*(Mouse|Touchpad)$')
VIRT=$(nodes_for '^IPTSD Virtual Touchpad')
echo "raw firmware touchpad : $(echo "${RAW:-<none>}" | paste -sd' ')"
echo "iptsd virtual touchpad: $(echo "${VIRT:-<none>}" | paste -sd' ')"
echo "iptsd process         : $(pgrep -a iptsd || echo '<not running>')"
echo "THC runtime PM        : $(cat /sys/devices/pci0000:00/0000:00:10.1/power/runtime_status 2>/dev/null)"
echo
echo "Sampling for ${N}s - keep one finger moving on the touchpad..."
T=$(mktemp -d)
i=0; for n in $RAW;  do i=$((i + 1)); (timeout "$N" cat "$n" | wc -c > "$T/raw.$i")  & done
i=0; for n in $VIRT; do i=$((i + 1)); (timeout "$N" cat "$n" | wc -c > "$T/virt.$i") & done
wait
sum() { local f t=0; for f in "$T"/"$1".*; do [ -f "$f" ] && t=$((t + $(cat "$f"))); done; echo $((t / 24)); }   # 24 bytes per input_event
raw=$(sum raw); virt=$(sum virt)
rm -rf "${T:?}"
printf '\n%-24s %6d events\n%-24s %6d events\n' "raw firmware touchpad:" "$raw" "iptsd virtual touchpad:" "$virt"
echo
if [ "$raw" -gt 0 ] && [ "$virt" -gt 0 ]; then
	echo "RESULT: BOTH devices are reporting -> libinput gets doubled, unsmoothed input (twitchy)."
elif [ "$raw" -gt 0 ]; then
	echo "RESULT: only the raw firmware touchpad reports -> device is in its native mode, iptsd is not running or gets nothing."
	echo "        Recover with: systemctl list-units 'iptsd@*'; udevadm trigger --action=add --subsystem-match=hidraw"
elif [ "$virt" -gt 0 ]; then
	echo "RESULT: only iptsd reports -> mode is correct; twitchiness is not a device-mode problem."
else
	echo "RESULT: no events at all (did you move a finger?)."
fi
