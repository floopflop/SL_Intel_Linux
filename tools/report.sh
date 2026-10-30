#!/bin/bash
# Collect everything needed to debug an installation of this repository on another machine.
#   sudo ./tools/report.sh > report.txt     (works without root too, with less detail)
D=$(cd "$(dirname "$0")/.." && pwd); K=$(uname -r)
sec() { printf '\n===== %s =====\n' "$*"; }
sec "system"; date; uname -r; . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"
cat /sys/class/dmi/id/product_name /sys/class/dmi/id/product_sku /sys/class/dmi/id/bios_version 2>/dev/null
echo "cmdline: $(cat /proc/cmdline)"; echo "secure boot: $(mokutil --sb-state 2>&1 | tr '\n' ' ')"; echo "lockdown: $(cat /sys/kernel/security/lockdown 2>/dev/null)"
echo "root: $(id -u)"; echo "boots: $(journalctl --list-boots 2>/dev/null | wc -l)"
sec "install.sh status"; "$D/install.sh" status 2>&1
sec "kernel packages (Fedora)"; rpm -qa 'kernel*' 2>/dev/null | sort
sec "dkms"; dkms status 2>&1; ls -la /var/lib/dkms/mok.pub 2>&1; mokutil --test-key /var/lib/dkms/mok.pub 2>&1; echo "pending MOK requests: $(mokutil --list-new 2>/dev/null | grep -c Subject)"
for kv in $(ls /lib/modules); do [ -d "/lib/modules/$kv/kernel" ] || continue; echo "-- $kv (headers: $([ -d /lib/modules/$kv/build ] && echo yes || echo no))"
  for m in surface_aggregator_registry ov02c10 snd-soc-sdw-utils intel-ipu7-isys; do
    printf '   %-28s %s | signer: %s\n' "$m" "$(modinfo -k "$kv" -n "$m" 2>&1 | sed "s|/lib/modules/$kv/||")" "$(modinfo -k "$kv" -F signer "$m" 2>/dev/null || echo none)"; done; done
sec "dkms build logs (tail)"; for f in /var/lib/dkms/surface-laptop-7-intel/*/build/make.log /var/lib/dkms/surface-laptop-7-intel/*/*/*/log/make.log; do [ -f "$f" ] && { echo "-- $f"; tail -15 "$f"; }; done 2>/dev/null
sec "loaded modules"; lsmod | grep -E '^(surface_aggregator|surface_hid|ov02c10|intel_ipu7|snd_soc_sdw_utils|pinctrl_intel_platform|ipts|hid_)' 
sec "SAM devices"; ls /sys/bus/surface_aggregator/devices 2>&1
sec "kernel log (this boot, relevant lines)"
journalctl -kb --no-pager -o short-monotonic 2>/dev/null | grep -iE 'surface|ssam|ov02c10|ipu7|ipu-bridge|sdw|rt1320|verification|Lockdown|rejected|setup IRQ|Unknown symbol|version magic|X\.509|MokList|Secure boot|firmware load|quickspi|ipts' | grep -vE 'ACPI Error|BERT' | head -150
sec "systemd-modules-load (this boot)"; journalctl -b --no-pager -o short-monotonic -u systemd-modules-load 2>/dev/null | head -20
sec "config files"; for f in /etc/modules-load.d/surface-sam.conf /etc/modprobe.d/surface-sam.conf /etc/dracut.conf.d/surface-laptop-7-intel.conf /etc/depmod.d/surface-laptop-7-intel.conf /etc/udev/rules.d/90-surface-sam-wakeup.rules /etc/iptsd.d/99-surface-laptop-7-touchpad.conf /etc/libinput/local-overrides.quirks /etc/wireplumber/wireplumber.conf.d/50-surface-sl7-hide-ipu7-raw.conf /usr/lib/systemd/system-sleep/btintel-pcie.sh /etc/systemd/system/iptsd-resume.service /usr/share/libcamera/ipa/simple/ov02c10.yaml; do printf '  %-70s %s\n' "$f" "$([ -e "$f" ] && echo present || echo MISSING)"; done
sec "initramfs"; ls -la --time-style=long-iso /boot/initramfs-*.img 2>&1
if [ "$(id -u)" = 0 ] && command -v lsinitrd >/dev/null; then for i in /boot/initramfs-$K.img; do echo "-- $i"; lsinitrd "$i" 2>/dev/null | grep -E 'extra/|ipu7|ov02c10|surface|pinctrl-intel-platform|modprobe.d/surface|modules-load.d/surface' | awk '{print $NF}'; done; fi
sec "network"; echo "NetworkManager / wait-online / dkms / our fallback: $(systemctl is-active NetworkManager NetworkManager-wait-online dkms.service surface-laptop-7-intel-dkms.service 2>&1 | paste -sd' ')"; ls /etc/systemd/system/dkms.service.d/ 2>/dev/null | sed 's/^/OLD DROP-IN STILL PRESENT: /'; systemctl show dkms.service -p Before -p After 2>/dev/null; nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device 2>/dev/null; rfkill list 2>/dev/null | head -8
journalctl -b --no-pager 2>/dev/null | grep -iE 'ordering cycle|deleted to break' | cut -c1-220 | head -6
journalctl -kb --no-pager -o short-monotonic 2>/dev/null | grep -iE 'iwlwifi|wlan|wlp' | head -12
sec "touchpad"; systemctl list-units --plain --no-legend 'iptsd@*.service' 2>/dev/null; journalctl -b --no-pager -u 'iptsd@*' 2>/dev/null | tail -10
sec "camera"; ls -la /dev/video* 2>/dev/null | head -3; rpm -q libcamera libcamera-tools pipewire-plugin-libcamera 2>&1; timeout 15 cam -l 2>&1 | head -5
sec "audio"; aplay -l 2>/dev/null | head -8
sec "network/dnf log of the install (last run)"; grep -E 'dnf install -y --skip-unavailable dkms' /var/log/dnf5.log 2>/dev/null | tail -1; dnf5 history list 2>/dev/null | head -5
