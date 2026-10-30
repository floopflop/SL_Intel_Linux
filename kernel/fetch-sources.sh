#!/bin/bash
# Fetch the kernel sources the four patched modules need, for a given kernel version, from the
# stable tree on kernel.org, apply the Surface Laptop 7 fixes and lay them out for one Kbuild run.
# Usage: fetch-sources.sh [kernel-version]   (default: running kernel; KERNEL_TAG=vX.Y.Z overrides
# the tag derived from the version string). Writes into the directory of this script.
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
K=${1:-$(uname -r)}
VER=${K%%-*}                                   # 7.2.11-200.fc44.x86_64 -> 7.2.11 ; 7.3.0-... -> 7.3.0
case $VER in *.*.0) VER=${VER%.0};; esac       # x.y.0 is tagged vx.y
B=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain
SRC=$D/src
I=drivers/staging/media/ipu7                    # used by both the fetch and the Kbuild layout below
CACHE=${SOURCE_CACHE:-/var/cache/surface-laptop-7-intel}
# The tag for this version may not exist yet (distribution builds can run ahead of the stable
# tag); fall back to the previous patch levels of the same series and say so.
tag_exists() { curl -sfL -m 30 -o /dev/null "$B/Makefile?h=$1"; }
if [ -n "${KERNEL_TAG:-}" ]; then TAG=$KERNEL_TAG
else
  TAG=v$VER; base=${VER%.*}; pl=${VER##*.}; [ "$pl" = "$base" ] && pl=0
  if [ -d "$CACHE/$TAG" ]; then :
  else
    while ! tag_exists "$TAG"; do
      [ "$pl" -gt 0 ] || { echo "no stable tag found for $VER"; exit 1; }
      pl=$((pl - 1)); TAG=v$base.$pl; [ "$pl" = 0 ] && TAG=v$base
      echo "tag v$VER not on kernel.org yet, trying $TAG"
    done
  fi
fi
rm -rf "$SRC"
if [ -d "$CACHE/$TAG" ]; then
  echo "== using cached sources for $TAG =="; cp -r "$CACHE/$TAG" "$SRC"
else
echo "== fetching sources for $TAG =="
mkdir -p "$SRC"
try_fetch() {  # <path in kernel tree>; returns 1 if the file does not exist at the tag
  local t; mkdir -p "$SRC/$(dirname "$1")"
  for t in 1 2 3 4 5; do
    curl -sfL "$B/$1?h=$TAG" -o "$SRC/$1" && return 0
    [ $t -lt 5 ] && sleep 2
  done
  rm -f "$SRC/$1"; return 1
}
fetch() { try_fetch "$1" || { echo "fetch failed: $1 ($TAG). Does the tag exist? Set KERNEL_TAG=vX.Y.Z to override."; exit 1; }; }
fetch drivers/platform/surface/surface_aggregator_registry.c
fetch drivers/media/i2c/ov02c10.c
fetch sound/soc/sdw_utils/Makefile
fetch sound/soc/codecs/rt1308.h
# the object list of the sdw-utils module spans continuation lines
for o in $(sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "$SRC/sound/soc/sdw_utils/Makefile" | sed -n 's/^snd-soc-sdw-utils-y *:= *//p' | tr -s '\t ' '\n'); do fetch "sound/soc/sdw_utils/${o%.o}.c"; done
for h in $(grep -ho '#include "[^"]*"' "$SRC"/sound/soc/sdw_utils/*.c | sed 's/#include "//;s/"//' | sort -u); do
  case $h in ../*) fetch "sound/soc/${h#../}";; *) fetch "sound/soc/sdw_utils/$h";; esac
done
# IPU7 staging driver: all sources named in its Makefile plus the local headers they include
fetch $I/Makefile
for o in $(sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "$SRC/$I/Makefile" | grep -oE '[a-z0-9-]+\.o' | grep -v '^intel-' | sort -u); do fetch "$I/${o%.o}.c"; done
for pass in 1 2 3 4 5; do
  for h in $(grep -ho '#include "[^"]*"' "$SRC/$I"/*.c "$SRC/$I"/*.h "$SRC/$I"/abi/*.h 2>/dev/null | sed 's/#include "//;s/"//' | sort -u); do
    [ -e "$SRC/$I/$h" ] || [ -e "$SRC/$I/abi/$h" ] || try_fetch "$I/$h" || fetch "$I/abi/$h"
  done
done
# keep a copy so that rebuilds (and other kernels on the same tag) need no network
if mkdir -p "$CACHE" 2>/dev/null && [ -w "$CACHE" ]; then rm -rf "$CACHE/$TAG"; cp -r "$SRC" "$CACHE/$TAG"; fi
fi
echo "== applying the fixes =="
python3 -I "$D/port-patches.py" "$SRC"
echo "== Kbuild layout =="
cat > "$SRC/Kbuild" <<'K'
obj-m += drivers/platform/surface/ drivers/media/i2c/ sound/soc/sdw_utils/ drivers/staging/media/ipu7/
K
echo 'obj-m += surface_aggregator_registry.o' > "$SRC/drivers/platform/surface/Kbuild"
echo 'obj-m += ov02c10.o' > "$SRC/drivers/media/i2c/Kbuild"
sed 's/^obj-\$(CONFIG_SND_SOC_SDW_UTILS)/obj-m/' "$SRC/sound/soc/sdw_utils/Makefile" > "$SRC/sound/soc/sdw_utils/Kbuild"
# only the input system module is rebuilt; the core intel-ipu7 module stays the distribution's
sed -e 's/^obj-\$(CONFIG_VIDEO_INTEL_IPU7)[[:space:]]*+= intel-ipu7\.o/obj-n += intel-ipu7.o/' \
    -e 's/^obj-\$(CONFIG_VIDEO_INTEL_IPU7)[[:space:]]*+= intel-ipu7-isys\.o/obj-m += intel-ipu7-isys.o/' "$SRC/$I/Makefile" > "$SRC/$I/Kbuild"
echo "sources ready in $SRC"
