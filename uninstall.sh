#!/bin/bash
# Remove what install.sh put in place (best effort). Run as root.
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); K=$(uname -r)
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
NAME=surface-laptop-7-intel; VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$D/kernel/dkms.conf")
command -v dkms >/dev/null && dkms remove -m $NAME -v $VER --all 2>/dev/null; rm -rf /usr/src/$NAME-$VER /etc/depmod.d/surface-laptop-7-intel.conf /etc/systemd/system/dkms.service.d/surface-laptop-7-intel.conf /var/cache/surface-laptop-7-intel
for k in /lib/modules/*/updates; do rm -f $k/surface_aggregator_registry.ko $k/ov02c10.ko $k/snd-soc-sdw-utils.ko $k/intel-ipu7-isys.ko; done; depmod -a "$K"
(cd "$D/configs" && find . -type f | while read -r f; do rm -f "/${f#./}"; done)
command -v dracut >/dev/null && dracut --regenerate-all --force   # the modules-load/modprobe/dracut files were in the initramfs too
systemctl disable iptsd-resume.service surface-laptop-7-intel-dkms.service 2>/dev/null; rmdir /etc/systemd/system/dkms.service.d 2>/dev/null; systemctl daemon-reload; udevadm control --reload
command -v grubby >/dev/null && grubby --update-kernel=ALL --remove-args="acpi_mask_gpe=0xAB"
[ -d "$D/iptsd/src/build" ] && ninja -C "$D/iptsd/src/build" uninstall >/dev/null 2>&1
rm -f /usr/share/libcamera/ipa/simple/ov02c10.yaml
if command -v dnf >/dev/null; then for n in libcamera libcamera-ipa libcamera-tools; do dnf versionlock delete $n >/dev/null 2>&1; done; echo "run: dnf distro-sync 'libcamera*'   to return to the distribution's libcamera"; fi
echo "removed; reboot to go back to the distribution's modules"
[ -f /var/lib/dkms/mok.pub ] && echo "the DKMS signing key stays enrolled in the firmware; to remove it too: sudo mokutil --delete /var/lib/dkms/mok.pub (confirm at the next boot)"
exit 0
