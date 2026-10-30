#!/bin/bash
# Build the four patched modules against the running kernel (or the one given) without DKMS.
# Needs the kernel headers (Fedora: kernel-devel-$(uname -r); Debian/Ubuntu: linux-headers-$(uname -r);
# Arch: linux-headers), gcc, make, curl, python3. Output: ./out/*.ko
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
K=${1:-$(uname -r)}
KDIR=/lib/modules/$K/build
[ -d "$KDIR" ] || { echo "no kernel headers at $KDIR (install them for exactly $K)"; exit 1; }
"$D/fetch-sources.sh" "$K"
echo "== building =="
make -C "$KDIR" M="$D/src" modules -j"$(nproc)" > "$D/src/build.log" 2>&1 || { tail -30 "$D/src/build.log"; echo "BUILD FAILED"; exit 1; }
grep -E 'LD \[M\]' "$D/src/build.log"
rm -rf "$D/out"; mkdir -p "$D/out"
cp "$D"/src/drivers/platform/surface/*.ko "$D"/src/drivers/media/i2c/*.ko "$D"/src/sound/soc/sdw_utils/*.ko "$D"/src/drivers/staging/media/ipu7/*.ko "$D/out/"
for k in "$D"/out/*.ko; do printf '%-32s %s\n' "$(basename "$k")" "$(modinfo -F vermagic "$k")"; done
echo "built into $D/out"
