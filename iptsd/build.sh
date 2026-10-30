#!/bin/bash
# Build the alex-lentz iptsd fork (Sensel haptic touchpad support for the Surface Laptop 7) with the
# touchpad fixes in patches/ applied. No root needed. Then: sudo ../install.sh iptsd
# Dependencies: a C++ compiler, meson, ninja, cmake, CLI11, Eigen3, fmt, inih/INIReader, Microsoft GSL
# (meson fetches GSL itself if the distribution has no package), spdlog.
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
BASE=3663e96e758145801c3cb1ce7c72f362d0d4a5f5     # fork master the patches were made on
SRC=$D/src
if [ ! -d "$SRC/.git" ]; then
  echo "== cloning alex-lentz/iptsd =="
  git clone -q https://github.com/alex-lentz/iptsd.git "$SRC"
fi
cd "$SRC"
git fetch -q origin
git checkout -q --detach "$BASE"
git am --abort 2>/dev/null || true
echo "== applying $(ls "$D"/patches/*.patch | wc -l) patches =="
git -c user.name=installer -c user.email=installer@localhost am -q "$D"/patches/*.patch
rm -rf build
meson setup build --prefix=/usr/local --buildtype=release -Ddebug_tools=calibrate,dump,perf -Dsample_config=false > "$D/meson-setup.log" 2>&1 || { tail -20 "$D/meson-setup.log"; echo "meson setup failed (missing dependencies? see above)"; exit 1; }
meson compile -C build > "$D/build.log" 2>&1 || { tail -20 "$D/build.log"; echo "BUILD FAILED"; exit 1; }
echo "built: $(ls build/src/apps/daemon/iptsd 2>/dev/null || find build -name iptsd -type f | head -1)"
echo "install with: sudo $D/../install.sh iptsd"
