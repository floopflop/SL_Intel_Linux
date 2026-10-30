#!/bin/bash
# Fedora: rebuild the distribution's libcamera 0.7.2 source package with the Surface Laptop 7
# software-ISP patch, as a normal user. Then: sudo ../install.sh libcamera
# Needs: dnf download/builddep plugins and the libcamera build dependencies
# (sudo dnf install rpm-build rpmdevtools 'dnf5-command(builddep)' 'dnf5-command(download)' && sudo dnf builddep libcamera).
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
REL=sl7
W=${RPMBUILD_DIR:-$HOME/rpmbuild}
mkdir -p "$W"/{SOURCES,SPECS,SRPMS,RPMS,BUILD}
T=$(mktemp -d)
echo "== downloading the libcamera source package =="
(cd "$T" && dnf download -q --source --enablerepo=fedora-source,updates-source libcamera)
SRPM=$(ls "$T"/libcamera-*.src.rpm)
VER=$(rpm -qp --qf '%{VERSION}' "$SRPM"); FREL=$(rpm -qp --qf '%{RELEASE}' "$SRPM" | sed 's/\.fc[0-9]*$//')
[ "$VER" = 0.7.2 ] || { echo "Fedora ships libcamera $VER; the patch is for 0.7.2 only."; exit 1; }
rpm -i --define "_topdir $W" "$SRPM" 2>/dev/null
cp "$D/libcamera-0.7.2-sl7.patch" "$W/SOURCES/"
SPEC=$W/SPECS/libcamera.spec
grep -q 'libcamera-0.7.2-sl7.patch' "$SPEC" || sed -i '/^Patch02:/a # Surface Laptop 7 (Intel): software ISP work for the OV02C10 webcam\nPatch03: libcamera-0.7.2-sl7.patch' "$SPEC"
sed -i -E "s/^(Release:\s*).*/\1${FREL}.${REL}%{?dist}/" "$SPEC"
grep -E '^(Release|Patch03)' "$SPEC"
echo "== building (several minutes) =="
rpmbuild --define "_topdir $W" -ba --nocheck "$SPEC" > "$W/build-sl7.log" 2>&1 || { tail -30 "$W/build-sl7.log"; echo "RPM BUILD FAILED"; exit 1; }
ls "$W"/RPMS/x86_64/libcamera-0.7.2-"$FREL"."$REL"*.rpm | sed 's|.*/||'
echo "RPMs in $W/RPMS/x86_64 -> sudo $D/../install.sh libcamera"
rm -rf "$T"
