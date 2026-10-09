#!/bin/bash
set -euo pipefail
out=$1
source_root=$2
stage="$out/deb-stage"
case "$out" in ''|/|.) echo 'Unsafe package output' >&2; exit 1;; esac
rm -rf "$stage"
mkdir -p "$stage/DEBIAN" "$stage/Applications" "$stage/Library/LaunchDaemons" "$stage/usr/share/rcloud"
cp -R "$out/rCloud.app" "$stage/Applications/"
cp "$source_root/iOS-daemon/package/"*.plist "$stage/usr/share/rcloud/"
mv "$stage/usr/share/rcloud/com.altivecintelligence.rcloudd.plist" "$stage/Library/LaunchDaemons/"
for hook in preinst postinst prerm; do
  sed "/^# RC_LIFECYCLE$/r $source_root/iOS-daemon/package/lifecycle.sh" \
    "$source_root/iOS-daemon/package/$hook" > "$stage/DEBIAN/$hook"
done
cat > "$stage/DEBIAN/control" <<'CONTROL'
Package: com.altivecintelligence.rcloud
Name: rCloud
Version: 0.1.0
Architecture: iphoneos-arm
Section: Utilities
Priority: optional
Maintainer: Strappy <strappy@jeffburg.com>
Depends: firmware (>= 5.0), uikittools
Description: Contacts and calendar sync daemon for jailbroken iOS.
CONTROL
find "$stage" -type d -exec chmod 755 {} +
find "$stage" -type f -exec chmod 644 {} +
chmod 755 "$stage/Applications/rCloud.app/rCloud" "$stage/DEBIAN/"{preinst,postinst,prerm}
fakeroot sh -c 'chown -R 0:0 "$1" && dpkg-deb -Zgzip --build "$1" "$2"' sh "$stage" "$out/rCloud-rootful.deb"
