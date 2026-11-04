#!/bin/bash
# Build the alex-lentz iptsd fork (Sensel haptic touchpad support for the Surface Laptop 7) with the
# touchpad fixes in patches/ applied. No root needed. Then: sudo ../install.sh iptsd
# Dependencies: a C++ compiler, meson, ninja, cmake, CLI11, Eigen3 (meson fetches both itself if the
# distribution has no package), and network access the first time: fmt, spdlog and inih are built from
# meson's wrap files and linked statically (see below), so their sources are downloaded once into
# src/subprojects/packagecache/.
#
# Why static: the installed binaries used to link the distribution's libfmt.so.N and libspdlog.so.1.M.
# Both sonames change between Fedora releases (44 -> 45: fmt 11 -> 12, spdlog 1.15 -> 1.17), and after
# the upgrade /usr/local/bin/iptsd-check-device failed to start ("libfmt.so.11: cannot open shared
# object file"), so the udev rule never requested iptsd@.service and the touchpad fell back to the
# firmware's mouse mode (no gestures, twitchy). Built this way the binaries depend only on the toolchain's
# runtime (glibc, libstdc++, libgcc_s), which stays backward compatible across upgrades.
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
BASE=3663e96e758145801c3cb1ce7c72f362d0d4a5f5     # fork master the patches were made on
SRC=$D/src
# iptsd dependencies whose shared libraries must not be used: built from the wraps in src/subprojects
# instead ('inih' is the subproject that provides INIReader).
STATIC_DEPS=fmt,spdlog,inih
if [ ! -d "$SRC/.git" ]; then
  echo "== cloning alex-lentz/iptsd =="
  git clone -q https://github.com/alex-lentz/iptsd.git "$SRC"
fi
cd "$SRC"
# the base commit is all that is needed; only fetch when the clone does not have it (offline rebuilds work)
git cat-file -e "$BASE^{commit}" 2>/dev/null || git fetch -q origin
git checkout -q --detach "$BASE"
git am --abort 2>/dev/null || true
echo "== applying $(ls "$D"/patches/*.patch | wc -l) patches =="
git -c user.name=installer -c user.email=installer@localhost am -q "$D"/patches/*.patch
rm -rf build
# werror=false: iptsd defaults to -Werror and LTO, and with the libraries linked statically the LTO
# link recompiles their code under the project's flags; GCC 16 then reports a -Wstringop-overflow
# false positive inside fmt 12 and the link fails. A compiler warning in a third-party library must
# not stop the touchpad daemon from being rebuilt (iptsd's own sources still compile with -Werror
# upstream, and a new warning there would otherwise block a rebuild after a compiler update too).
meson setup build --prefix=/usr/local --buildtype=release -Ddebug_tools=calibrate,dump,perf -Dsample_config=false \
  -Dwerror=false --force-fallback-for="$STATIC_DEPS" > "$D/meson-setup.log" 2>&1 || { tail -20 "$D/meson-setup.log"; echo "meson setup failed (missing dependencies or no network for the wrap downloads? see above)"; exit 1; }
meson compile -C build > "$D/build.log" 2>&1 || { tail -20 "$D/build.log"; echo "BUILD FAILED"; exit 1; }
BIN=$(ls build/src/iptsd 2>/dev/null || find build -name iptsd -type f | head -1)
echo "built: $BIN"
# the point of the static build: no distribution library other than the toolchain's may be needed
if ldd "$BIN" | grep -qE 'libfmt|libspdlog|libINIReader|libinih|not found'; then
  echo "WARNING: $BIN still depends on a distribution library that changes between releases:"; ldd "$BIN" | grep -E 'libfmt|libspdlog|libINIReader|libinih|not found'
fi
echo "install with: sudo $D/../install.sh iptsd"
