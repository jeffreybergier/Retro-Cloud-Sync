#!/bin/bash
# Run after building replacement libvc libraries with build-libvc.sh.
set -euo pipefail
root="${1:?usage: relink-libvc-daemon.sh SOURCE_BUNDLE [LEGACY_TOOLCHAIN]}"
toolchain="${2:-/osxcross/legacy/target}"
for arch in ppc i386; do
  if [ "$arch" = ppc ]; then compiler="$toolchain/bin/oppc32-gcc"
  else compiler="$toolchain/bin/o32-gcc"; fi
  "$compiler" -arch "$arch" -isysroot "$toolchain/SDK/MacOSX10.5.sdk" \
    -mmacosx-version-min=10.4 "$root/relink/$arch/"*.o \
    "$root/relink/$arch/libRetroCloudShared.a" \
    "$root/relink/$arch/libAltivecCore.a" "$root/relink/$arch/libical.a" \
    "$root/libvc-$arch/libvc.a" \
    -framework Foundation -framework CoreFoundation -framework SystemConfiguration \
    -framework Security -lxml2 -framework SyncServices -lobjc -lgcc_s.10.4 \
    -o "$root/relink/$arch/rcloudd"
done
"$toolchain/bin/i386-apple-darwin9-lipo" -create \
  "$root/relink/ppc/rcloudd" "$root/relink/i386/rcloudd" \
  -output "$root/rcloudd"
