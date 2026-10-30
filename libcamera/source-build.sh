#!/bin/bash
# Other distributions: build libcamera 0.7.2 from source with the Surface Laptop 7 patch and the
# same features Fedora enables, into a staging directory; ../install.sh libcamera copies it over
# the system's libcamera 0.7.2 (same soname, so PipeWire keeps working). Your package manager will
# overwrite it on the next libcamera update: pin/hold the libcamera packages.
# Needs the libcamera build dependencies: meson ninja g++ python3-{yaml,ply,jinja2} pkg-config
# libyaml libgnutls libudev libevent libdrm libegl/gles2 libjpeg libtiff gstreamer-1.0 devel packages.
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
SRC=$D/src/libcamera-v0.7.2
PREFIX=${PREFIX:-/usr}
LIBDIR=${LIBDIR:-$(pkg-config --variable=libdir libcamera 2>/dev/null || echo lib)}
LIBDIR=${LIBDIR#$PREFIX/}
mkdir -p "$D/src"
if [ ! -d "$SRC" ]; then
  echo "== fetching libcamera v0.7.2 =="
  curl -sfL https://gitlab.freedesktop.org/camera/libcamera/-/archive/v0.7.2/libcamera-v0.7.2.tar.bz2 | tar -xj -C "$D/src"
fi
cd "$SRC"
if [ ! -f .sl7-patched ]; then patch -p1 -s < "$D/libcamera-0.7.2-sl7.patch" && touch .sl7-patched; fi
rm -rf build
meson setup build --prefix="$PREFIX" --libdir="$LIBDIR" --buildtype=release \
  -Dpipelines=simple,uvcvideo -Dipas=simple -Dv4l2=enabled -Dgstreamer=enabled -Dcam=enabled \
  -Dqcam=disabled -Dlc-compliance=disabled -Dpycamera=disabled -Ddocumentation=disabled -Dtest=false > "$D/meson-setup.log" 2>&1 \
  || { tail -20 "$D/meson-setup.log"; echo "meson setup failed (missing dependencies?)"; exit 1; }
ninja -C build > "$D/build.log" 2>&1 || { tail -20 "$D/build.log"; echo "BUILD FAILED"; exit 1; }
rm -rf "$D/stage"; DESTDIR=$D/stage ninja -C build install > /dev/null
echo "staged in $D/stage (prefix $PREFIX, libdir $LIBDIR) -> sudo $D/../install.sh libcamera"
