#!/bin/bash
# Surface Laptop 7 (Intel) fixes: one entry point. Run as root (sudo).
#   sudo ./install.sh all        deps, kernel modules, configs, touchpad daemon, webcam stack
#   sudo ./install.sh kernel     patched modules (DKMS when available, so kernel updates rebuild them; enrols the signing key when Secure Boot is on)
#   sudo ./install.sh configs    udev/systemd/libinput/wireplumber/modprobe/dracut files, kernel command line, initramfs rebuild
#   sudo ./install.sh iptsd      touchpad daemon fork with the fixes (builds first if needed)
#   sudo ./install.sh libcamera  patched libcamera 0.7.2 + OV02C10 tuning (Fedora RPM rebuild, or from source)
#   sudo ./install.sh deps       install build dependencies (Fedora; prints the list elsewhere)
#        ./install.sh status     what is installed and active (no root needed)
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
K=$(uname -r)
. /etc/os-release 2>/dev/null || true
case "${ID:-} ${ID_LIKE:-}" in *fedora*|*rhel*) DISTRO=fedora;; *debian*|*ubuntu*) DISTRO=debian;; *arch*) DISTRO=arch;; *) DISTRO=other;; esac
DKMS_NAME=surface-laptop-7-intel; DKMS_VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$D/kernel/dkms.conf")
MODULES="surface_aggregator_registry ov02c10 snd-soc-sdw-utils intel-ipu7-isys"

# With Secure Boot on, the kernel loads only modules signed with a key it trusts. DKMS signs with
# /var/lib/dkms/mok.key; the matching certificate must be enrolled in the firmware's Machine Owner Key
# list, which takes a one-time password now and a confirmation in the MOK manager at the next boot.
MOK_PUB=/var/lib/dkms/mok.pub
MOK_PENDING=
KERNEL_FAILED=   # set when a module build failed; reported at the end of "all"
secure_boot_on() { case "$(mokutil --sb-state 2>/dev/null)" in *"SecureBoot enabled"*) return 0;; *) return 1;; esac; }
ensure_mok_key() { [ -f "$MOK_PUB" ] || dkms generate_mok >/dev/null 2>&1 || true; }
ensure_mok_enrolled() {
  command -v mokutil >/dev/null || { echo "WARNING: mokutil missing; cannot check the Secure Boot key"; return 0; }
  [ -f "$MOK_PUB" ] || { echo "WARNING: no DKMS signing key at $MOK_PUB; the modules are unsigned"; return 0; }
  if mokutil --test-key "$MOK_PUB" 2>/dev/null | grep -q 'already enrolled'; then echo "DKMS signing key: enrolled in MOK"; return 0; fi
  if mokutil --list-new 2>/dev/null | grep -q 'DKMS module signing key'; then
    echo "DKMS signing key: enrolment pending; reboot, press a key at the blue MOK manager screen, then Enroll MOK, Continue, Yes, password"; MOK_PENDING=1; return 0; fi
  if secure_boot_on; then
    echo "== Secure Boot is on: the DKMS signing key must be enrolled or the modules will not load =="
    # mokutil prints its prompts through stdout: when the script's output is piped (tee), they would be
    # buffered and appear only afterwards. Talk to the terminal directly.
    if { true </dev/tty; } 2>/dev/null; then
      {
        echo "Choose a one-time password. mokutil asks 'input password:' twice; what you type is not shown."
        echo "At the next boot a blue MOK manager screen appears for ~10 s: press any key before it times out,"
        echo "then Enroll MOK -> Continue -> Yes -> enter that password -> Reboot."
        echo "(If it times out the request is dropped: run  sudo mokutil --import $MOK_PUB  and reboot again.)"
      } >/dev/tty
      if mokutil --import "$MOK_PUB" </dev/tty >/dev/tty 2>&1; then MOK_PENDING=1; echo "MOK enrolment requested"
      else echo "WARNING: mokutil --import failed; run: sudo mokutil --import $MOK_PUB"; fi
    else echo "no terminal: run  sudo mokutil --import $MOK_PUB  then reboot and confirm in the MOK manager"; fi
  else
    echo "Secure Boot is off. To turn it on later: sudo mokutil --import $MOK_PUB, reboot, confirm in the MOK manager, then enable Secure Boot in the firmware."
  fi
}

# The build that fetches sources needs the network. Fedora's dkms.service runs before networking; an
# earlier version of this script ordered it after network-online.target, which forms a dependency
# cycle that systemd breaks by dropping a job, sometimes NetworkManager (no Wi-Fi). Remove that
# drop-in wherever it exists and use our own after-network unit (configs/) as the retry instead.
enable_dkms_fallback() {
  if [ -f /etc/systemd/system/dkms.service.d/surface-laptop-7-intel.conf ]; then
    rm -f /etc/systemd/system/dkms.service.d/surface-laptop-7-intel.conf; rmdir /etc/systemd/system/dkms.service.d 2>/dev/null || true
    echo "removed the old dkms.service drop-in (it caused a systemd ordering cycle)"
  fi
  systemctl daemon-reload
  command -v dkms >/dev/null && systemctl enable surface-laptop-7-intel-dkms.service >/dev/null 2>&1 || true
}

# Files under configs/ go to /. Three of them also end up inside the initramfs (modules-load.d, the
# modprobe.d softdep, the dracut omit list), so they must be in place before anything rebuilds it.
install_config_files() {
  echo "== config files =="
  (cd "$D/configs" && find . -type f | while read -r f; do install -D -m 644 "${f#./}" "/${f#./}"; done)
  chmod 755 /usr/lib/systemd/system-sleep/btintel-pcie.sh
}
# Fedora's dkms rebuilds every initramfs after each transaction (framework.conf: post_transaction="dracut ...").
dkms_regenerates_initramfs() { grep -qsE '^post_transaction=.*(dracut|initramfs|mkinitcpio)' /etc/dkms/framework.conf /etc/dkms/framework.conf.d/*.conf; }
regen_initramfs() {
  echo "== rebuilding the initramfs of every installed kernel (about a minute) =="
  if command -v dracut >/dev/null; then dracut --regenerate-all --force || echo "WARNING: dracut failed"
  elif command -v update-initramfs >/dev/null; then update-initramfs -u -k all || echo "WARNING: update-initramfs failed"
  elif command -v mkinitcpio >/dev/null; then mkinitcpio -P || echo "WARNING: mkinitcpio failed"
  else echo "WARNING: no dracut/update-initramfs/mkinitcpio found; rebuild your initramfs by hand"; fi
}
# A kernel-core without its kernel-modules (dkms' kernel-devel-matched dependency can install one) has no
# camera, audio or Bluetooth drivers, and the patched modules cannot resolve their symbols on it.
complete_fedora_kernels() {
  rpm -q kernel-core >/dev/null 2>&1 || return 0
  local nvr
  for nvr in $(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n'); do
    rpm -q "kernel-modules-$nvr" >/dev/null 2>&1 && continue
    echo "== kernel $nvr is installed without kernel-modules: completing it =="
    dnf install -y --skip-unavailable "kernel-$nvr" "kernel-modules-$nvr" "kernel-modules-extra-$nvr" \
      || echo "WARNING: could not complete kernel $nvr; remove it with: dnf remove kernel-core-$nvr"
  done
}

need_root() { [ "$(id -u)" = 0 ] || { echo "run this as root: sudo $0 $*"; exit 1; }; }
as_user() { if [ -n "${SUDO_USER:-}" ]; then sudo -u "$SUDO_USER" -H "$@"; else "$@"; fi; }
user_home() { if [ -n "${SUDO_USER:-}" ]; then getent passwd "$SUDO_USER" | cut -d: -f6; else echo "$HOME"; fi; }
restart_wireplumber() {
  # WirePlumber hosts the PipeWire camera node and keeps the old libcamera mapped until restarted.
  [ -n "${SUDO_USER:-}" ] || return 0
  local uid; uid=$(id -u "$SUDO_USER")
  sudo -u "$SUDO_USER" XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
    systemctl --user restart wireplumber 2>/dev/null && echo "wireplumber restarted (reopen the camera app)" || true
}

cmd_deps() {
  need_root deps
  case $DISTRO in
  fedora)
    # dnf5-plugins provides the builddep, download and versionlock commands.
    # dkms requires kernel-devel-matched; dnf satisfies that with the NEWEST kernel's package and pulls that
    # kernel's kernel-core in, but not its kernel-modules. Ask for the running kernel's version explicitly
    # and complete any kernel that ended up half installed.
    dnf install -y --skip-unavailable dkms "kernel-devel-$K" "kernel-devel-matched-$K" gcc make curl python3 git \
      meson ninja-build gcc-c++ cmake eigen3-devel fmt-devel spdlog-devel cli11-devel inih-devel guidelines-support-library-devel \
      rpm-build rpmdevtools dnf5-plugins libcamera libcamera-tools pipewire-plugin-libcamera pipewire-v4l2 \
      mokutil keyutils openssl
    complete_fedora_kernels
    dnf builddep -y --enablerepo=fedora-source,updates-source libcamera
    for t in dkms gcc meson cmake rpmbuild; do command -v $t >/dev/null || echo "WARNING: $t still missing"; done
    ;;
  debian)
    echo "Install: sudo apt install dkms linux-headers-\$(uname -r) build-essential curl python3 meson ninja-build cmake"
    echo "  libeigen3-dev libfmt-dev libspdlog-dev libcli11-dev libinih-dev libmsgsl-dev   (iptsd)"
    echo "  and the libcamera build dependencies (apt build-dep libcamera), libcamera-tools, pipewire-v4l2";;
  arch)
    echo "Install: sudo pacman -S dkms linux-headers base-devel curl python meson ninja cmake eigen fmt spdlog cli11 inih microsoft-gsl"
    echo "  and the libcamera makedepends (see the libcamera PKGBUILD), libcamera-tools, pipewire-v4l2";;
  *) echo "Unknown distribution: install dkms, kernel headers for $K, gcc, make, curl, python3, meson, ninja, cmake, eigen3, fmt, spdlog, CLI11, inih, GSL, and the libcamera build dependencies.";;
  esac
}

cmd_kernel() {
  need_root kernel
  # every installed kernel that has headers, the running one first
  # (the patches are for 7.2 and newer; older kernels are skipped, their sources differ)
  local kernels=() kv m
  for kv in "$K" $(ls /lib/modules 2>/dev/null | grep -vx "$K"); do
    [ -d "/lib/modules/$kv/build" ] || continue
    if [ "$(printf '%s\n' 7.2 "${kv%%-*}" | sort -V | head -1)" != 7.2 ]; then echo "skipping $kv (older than 7.2)"; continue; fi
    kernels+=("$kv"); done
  [ ${#kernels[@]} -gt 0 ] || { echo "no installed kernel has headers (Fedora: dnf install kernel-devel-$K)"; exit 1; }
  [ -d "/lib/modules/$K/build" ] || echo "WARNING: no headers for the running kernel $K; building for ${kernels[*]} instead (reboot into one of them)"
  install_config_files   # the modprobe.d softdep and the dracut omit list must be in place before the initramfs is rebuilt
  if command -v dkms >/dev/null; then
    echo "== DKMS: $DKMS_NAME/$DKMS_VER =="
    [ -n "$(dkms status -m "$DKMS_NAME" -v "$DKMS_VER" 2>/dev/null)" ] && dkms remove -m "$DKMS_NAME" -v "$DKMS_VER" --all >/dev/null 2>&1 || true
    rm -rf "/usr/src/$DKMS_NAME-$DKMS_VER"; mkdir -p "/usr/src/$DKMS_NAME-$DKMS_VER"
    cp "$D"/kernel/dkms.conf "$D"/kernel/Kbuild "$D"/kernel/fetch-sources.sh "$D"/kernel/port-patches.py "/usr/src/$DKMS_NAME-$DKMS_VER/"
    # Fedora's dkms installs to /lib/modules/<kernel>/extra, which depmod does not search unless told to.
    printf 'search updates extra built-in weak-updates\n' > /etc/depmod.d/surface-laptop-7-intel.conf
    enable_dkms_fallback
    dkms add -m "$DKMS_NAME" -v "$DKMS_VER"
    ensure_mok_key   # so the first build is already signed
    for kv in "${kernels[@]}"; do
      echo "== DKMS build for $kv =="
      rm -f "/lib/modules/$kv/updates/"{surface_aggregator_registry,ov02c10,snd-soc-sdw-utils,intel-ipu7-isys}.ko   # stale manual installs
      if dkms build -m "$DKMS_NAME" -v "$DKMS_VER" -k "$kv" && dkms install -m "$DKMS_NAME" -v "$DKMS_VER" -k "$kv" --force; then echo "built and installed for $kv"
      else echo "WARNING: DKMS build FAILED for $kv (see /var/lib/dkms/$DKMS_NAME/$DKMS_VER/build/make.log)"; [ "$kv" = "$K" ] && KERNEL_FAILED=1; fi
      depmod -a "$kv"
    done
    for kv in "${kernels[@]}"; do for m in $MODULES; do
      case "$(modinfo -k "$kv" -n "$m" 2>/dev/null)" in */extra/*|*/updates/*) ;; *) echo "ERROR: $m for $kv still resolves to the distribution's module (build failed?)"; [ "$kv" = "$K" ] && KERNEL_FAILED=1;; esac; done; done
    echo "DKMS will rebuild the modules for every new kernel (at kernel installation, or at boot if that failed)."
    if dkms_regenerates_initramfs; then echo "(dkms rebuilt the initramfs)"; else regen_initramfs; fi
    ensure_mok_enrolled
  else
    echo "== no dkms: building without signing (re-run after every kernel update) =="
    secure_boot_on && echo "WARNING: Secure Boot is on and unsigned modules will be refused; install dkms and re-run instead"
    for kv in "${kernels[@]}"; do
      as_user "$D/kernel/build.sh" "$kv"
      install -d "/lib/modules/$kv/updates"
      for m in $MODULES; do install -m 644 "$D/kernel/out/$m.ko" "/lib/modules/$kv/updates/$m.ko"; done
      depmod -a "$kv"
    done
    regen_initramfs
  fi
  if [ -n "$KERNEL_FAILED" ]; then echo "MODULES FOR THE RUNNING KERNEL ARE NOT INSTALLED: fix the build error above, then re-run: sudo $0 kernel"
  else echo "modules installed; they take effect after a reboot"; fi
}

cmd_configs() {
  need_root configs
  install_config_files
  systemctl daemon-reload; systemctl enable iptsd-resume.service >/dev/null 2>&1 || true
  enable_dkms_fallback
  udevadm control --reload
  echo "== kernel command line: acpi_mask_gpe=0xAB (SAM GPE storm) =="
  if grep -q 'acpi_mask_gpe=0xAB' /proc/cmdline; then echo "already active"
  elif command -v grubby >/dev/null; then grubby --update-kernel=ALL --args="acpi_mask_gpe=0xAB"; echo "added via grubby (active after reboot)"
  elif [ -f /etc/default/grub ]; then
    grep -q 'acpi_mask_gpe=0xAB' /etc/default/grub || sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 acpi_mask_gpe=0xAB"/' /etc/default/grub
    if command -v update-grub >/dev/null; then update-grub; else grub2-mkconfig -o /boot/grub2/grub.cfg; fi
    echo "added to /etc/default/grub (active after reboot)"
  else echo "add acpi_mask_gpe=0xAB to the kernel command line with your boot loader's tool"; fi
  echo mask > /sys/firmware/acpi/interrupts/gpeAB 2>/dev/null || true
  [ -n "${SKIP_REGEN:-}" ] || regen_initramfs
}

cmd_iptsd() {
  need_root iptsd
  [ -x "$D/iptsd/src/build/src/iptsd" ] || as_user "$D/iptsd/build.sh"
  echo "== installing iptsd to /usr/local =="
  meson install -C "$D/iptsd/src/build" --no-rebuild >/dev/null
  install -D -m 644 "$D/configs/etc/iptsd.d/99-surface-laptop-7-touchpad.conf" /etc/iptsd.d/99-surface-laptop-7-touchpad.conf
  install -D -m 644 "$D/configs/etc/libinput/local-overrides.quirks" /etc/libinput/local-overrides.quirks
  systemctl daemon-reload; udevadm control --reload; udevadm trigger --subsystem-match=hidraw 2>/dev/null || true
  units=$(systemctl list-units --plain --no-legend 'iptsd@*.service' | awk '{print $1}')
  [ -n "$units" ] && systemctl restart $units
  sleep 1; systemctl list-units --plain --no-legend 'iptsd@*.service' || true
  echo "iptsd installed ($(/usr/local/bin/iptsd --version 2>/dev/null | head -1 || echo /usr/local/bin/iptsd))"
}

cmd_libcamera() {
  need_root libcamera
  local H; H=$(user_home)
  if [ $DISTRO = fedora ]; then
    rpm -q libcamera >/dev/null 2>&1 || { echo "libcamera is not installed; install it first (dnf install libcamera libcamera-tools)"; exit 1; }
    [ "$(rpm -q --qf '%{VERSION}' libcamera)" = 0.7.2 ] || { echo "installed libcamera is $(rpm -q --qf '%{VERSION}' libcamera); the patch is for 0.7.2 only"; exit 1; }
    local R=$H/rpmbuild/RPMS/x86_64
    ls "$R"/libcamera-0.7.2-*.sl7*.x86_64.rpm >/dev/null 2>&1 || as_user env RPMBUILD_DIR="$H/rpmbuild" "$D/libcamera/fedora-rpm.sh"
    local rel; rel=$(ls "$R"/libcamera-0.7.2-*.sl7*.x86_64.rpm | sed 's/.*libcamera-0.7.2-//; s/\.x86_64\.rpm//' | sort -V | tail -1)
    local pkgs=(); for p in libcamera libcamera-ipa libcamera-tools libcamera-devel libcamera-gstreamer libcamera-qcam libcamera-v4l2 python3-libcamera; do
      rpm -q "$p" >/dev/null 2>&1 && [ -f "$R/$p-0.7.2-$rel.x86_64.rpm" ] && pkgs+=("$R/$p-0.7.2-$rel.x86_64.rpm"); done
    for n in libcamera libcamera-ipa libcamera-tools libcamera-devel libcamera-gstreamer libcamera-qcam libcamera-v4l2 python3-libcamera; do dnf versionlock delete "$n" >/dev/null 2>&1 || true; done
    echo "== installing libcamera 0.7.2-$rel =="; dnf install -y "${pkgs[@]}"
    dnf versionlock add libcamera libcamera-ipa libcamera-tools >/dev/null 2>&1 || echo "(no dnf versionlock: a libcamera update would replace this build)"
    install -D -m 644 "$D/libcamera/tuning/ov02c10.yaml" /usr/share/libcamera/ipa/simple/ov02c10.yaml
  else
    [ -d "$D/libcamera/stage" ] || as_user "$D/libcamera/source-build.sh"
    echo "== copying the staged libcamera over the system one =="
    cp -a "$D/libcamera/stage/." /; ldconfig
    local ipadir; ipadir=$(dirname "$(find /usr/share/libcamera/ipa /usr/local/share/libcamera/ipa -name uncalibrated.yaml 2>/dev/null | head -1)")
    install -D -m 644 "$D/libcamera/tuning/ov02c10.yaml" "${ipadir:-/usr/share/libcamera/ipa/simple}/ov02c10.yaml"
    echo "pin/hold your libcamera packages so an update does not overwrite this build"
  fi
  echo "tuning: /usr/share/libcamera/ipa/simple/ov02c10.yaml"; restart_wireplumber
}

cmd_status() {
  echo "kernel $K  ($DISTRO)"
  for m in $MODULES; do
    f=$(modinfo -n "$m" 2>/dev/null || echo missing); case $f in */updates/*|*/extra/*) w=patched;; missing) w=missing;; *) w=DISTRIBUTION;; esac
    l=$([ -d "/sys/module/${m//-/_}" ] && echo loaded || echo "not loaded")
    printf '  %-30s %-13s %s\n' "$m" "$w" "$l"; done
  local ds klog; ds=$(dkms status 2>/dev/null || true); klog=$(journalctl -kb --no-pager 2>/dev/null || true)
  if ! command -v dkms >/dev/null; then echo "  dkms: not installed (modules must be rebuilt by hand after kernel updates)"
  elif grep -q "$DKMS_NAME" <<<"$ds"; then grep "$DKMS_NAME" <<<"$ds" | sed 's/^/  dkms: /'
  else echo "  dkms: installed, modules not registered (run: sudo ./install.sh kernel)"; fi
  if grep -q 'surface_serial_hub.*failed to setup IRQ' <<<"$klog"; then
    echo "  SAM: controller probe FAILED this boot (keyboard/battery dead; README, Troubleshooting)"
  elif ls /sys/bus/surface_aggregator/devices 2>/dev/null | grep -q .; then echo "  SAM: controller up ($(ls /sys/bus/surface_aggregator/devices | wc -l) devices)"
  else echo "  SAM: controller not up"; fi
  grep -q 'ipu7_fw.bin failed' <<<"$klog" && echo "  camera: IPU7 firmware load FAILED this boot (driver probed inside the initramfs; README, Troubleshooting)"
  [ $DISTRO = fedora ] && for nvr in $(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null); do
    rpm -q "kernel-modules-$nvr" >/dev/null 2>&1 || echo "  kernel $nvr: kernel-modules MISSING, most drivers absent (run: sudo ./install.sh deps)"; done
  grep -q 'acpi_mask_gpe=0xAB' /proc/cmdline && echo "  cmdline: acpi_mask_gpe=0xAB active" || echo "  cmdline: acpi_mask_gpe=0xAB MISSING"
  local sb; sb=$(mokutil --sb-state 2>/dev/null | head -1); printf '  secure boot: %s' "${sb:-unknown}"
  if [ "$(id -u)" = 0 ] && command -v keyctl >/dev/null; then   # the kernel loads MOK keys only while Secure Boot is on
    local r found=; for r in .machine .platform; do keyctl list "%:$r" 2>/dev/null | grep -q 'DKMS module signing key' && found="$found $r"; done
    case "$sb" in *enabled*) echo ", DKMS key in kernel keyring:${found:- NONE (modules will be rejected)}";; *) echo ", DKMS key enrolled in MOK: $(mokutil --list-enrolled 2>/dev/null | grep -q 'DKMS module signing key' && echo yes || echo no)";; esac
  else echo; fi
  printf '  iptsd: %s %s\n' "$(command -v iptsd || echo missing)" "$(systemctl list-units --plain --no-legend 'iptsd@*.service' 2>/dev/null | awk '{print $1, $4}' | head -1)"
  printf '  libcamera: %s\n' "$(rpm -q libcamera 2>/dev/null || cam --version 2>/dev/null | head -1 || echo unknown)"
  [ -f /usr/share/libcamera/ipa/simple/ov02c10.yaml ] && echo "  tuning: ov02c10.yaml present ($(grep -c 'flickerPeriod\|temporalStrength' /usr/share/libcamera/ipa/simple/ov02c10.yaml) of 2 recent keys)" || echo "  tuning: ov02c10.yaml MISSING"
}

case "${1:-help}" in
  deps) cmd_deps;; kernel) cmd_kernel;; configs) cmd_configs;; iptsd) cmd_iptsd;; libcamera) cmd_libcamera;; status) cmd_status;;
  all) cmd_deps; SKIP_REGEN=1 cmd_configs; cmd_kernel; cmd_iptsd; cmd_libcamera; echo
       if [ -n "$KERNEL_FAILED" ]; then echo "NOT DONE: the kernel modules did not build (see the DKMS warning above and /var/lib/dkms/$DKMS_NAME/$DKMS_VER/build/make.log)."
       elif [ -n "$MOK_PENDING" ]; then echo "All done. Reboot now. Press a key when the blue MOK manager screen appears (it times out after ~10 s), then Enroll MOK, Continue, Yes, enter the password you chose, Reboot."
       else echo "All done. Reboot to activate the kernel modules and the command line."; fi; cmd_status;;
  *) sed -n '2,10p' "$0";;
esac
