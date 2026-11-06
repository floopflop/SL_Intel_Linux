#!/bin/bash
# Fedora: rebuild the distribution's vte291 source package with the touchpad scroll-unit patch
# (vte-touchpad-scroll-units.patch), as a normal user. Then: sudo ../install.sh vte
# Needs the vte291 build dependencies: sudo dnf builddep -y --enablerepo=fedora-source,updates-source vte291
# (or sudo ../install.sh deps). The build takes several minutes (GTK3 and GTK4 libraries plus docs).
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
REL=sl7
W=${RPMBUILD_DIR:-$HOME/rpmbuild}
mkdir -p "$W"/{SOURCES,SPECS,SRPMS,RPMS,BUILD}
T=$(mktemp -d)
echo "== downloading the vte291 source package =="
(cd "$T" && dnf download -q --source --setopt=disable_excludes='*' --enablerepo=fedora-source,updates-source vte291)   # past the version lock install.sh vte adds
SRPM=$(ls "$T"/vte291-*.src.rpm)
VER=$(rpm -qp --qf '%{VERSION}' "$SRPM"); FREL=$(rpm -qp --qf '%{RELEASE}' "$SRPM" | sed 's/\.fc[0-9]*$//')
echo "vte291 $VER-$FREL (the patch was written for 0.84.1; a failure in %prep below means it needs porting)"
rpm -i --define "_topdir $W" "$SRPM" 2>/dev/null
cp "$D/vte-touchpad-scroll-units.patch" "$W/SOURCES/"
SPEC=$W/SPECS/vte291.spec
grep -q 'vte-touchpad-scroll-units.patch' "$SPEC" || sed -i '/^Source0:/a # GTK4 build: touchpad deltas arrive in pixels and were counted as one wheel click each (vte#2720)\nPatch0: vte-touchpad-scroll-units.patch' "$SPEC"
sed -i -E "s/^(Release:\s*).*/\1${FREL}.${REL}%{?dist}/" "$SPEC"   # replaces the %autorelease line
grep -E '^(Release|Patch0)' "$SPEC"
echo "== building (several minutes) =="
rpmbuild --define "_topdir $W" -ba --nocheck "$SPEC" > "$W/build-vte-sl7.log" 2>&1 || { tail -30 "$W/build-vte-sl7.log"; echo "RPM BUILD FAILED (log: $W/build-vte-sl7.log)"; exit 1; }
ls "$W"/RPMS/x86_64/vte291*-"$VER"-"$FREL"."$REL"*.rpm "$W"/RPMS/x86_64/vte-profile-"$VER"-"$FREL"."$REL"*.rpm 2>/dev/null | sed 's|.*/||'
echo "RPMs in $W/RPMS/x86_64 -> sudo $D/../install.sh vte"
rm -rf "$T"
