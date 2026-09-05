#!/bin/bash
# Pinned source; the two patches only remove diagnostics unsupported by GCC 4.2.
set -euo pipefail
mode="$1"
deps="$2"
toolchain="${3:-/osxcross/legacy/target}"
version=3.0.20
archive="$deps/libical-$version.tar.gz"
src="$deps/libical-$version"
mkdir -p "$deps"
if [ "$mode" = prepare ]; then
  if [ ! -f "$archive" ]; then
    curl --fail --location --retry 2 "https://github.com/libical/libical/releases/download/v$version/libical-$version.tar.gz" -o "$archive.download"
    mv "$archive.download" "$archive"
  fi
  printf '%s  %s\n' e73de92f5a6ce84c1b00306446b290a2b08cdf0a80988eca0a2c9d5c3510b4c2 "$archive" | sha256sum --check
  tar -xzf "$archive" -C "$deps"
  python3 - "$src" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
p = root / 'CMakeLists.txt'
p.write_text(p.read_text().replace('-Wtype-limits', '').replace('-Wno-deprecated', ''))
for p in (root / 'src/libical').glob('*.c'):
    p.write_text(''.join(line for line in p.read_text().splitlines(True)
                       if not line.lstrip().startswith('#pragma GCC diagnostic')))
PY
  touch "$deps/libical-source.stamp"
  exit
fi
out="$deps/libical-$mode"
args=(-DSTATIC_ONLY=ON -DWITH_CXX_BINDINGS=OFF -DICAL_GLIB=OFF
      -DICAL_BUILD_DOCS=OFF -DLIBICAL_BUILD_TESTING=OFF
      -DCMAKE_DISABLE_FIND_PACKAGE_ICU=TRUE
      -DCMAKE_DISABLE_FIND_PACKAGE_BerkeleyDB=TRUE
      -DUSE_BUILTIN_TZDATA=ON -DCMAKE_BUILD_TYPE=Release)
if [ "$mode" != host ]; then
  case "$mode" in
    ppc) compiler="$toolchain/bin/oppc32-gcc"; processor=powerpc ;;
    i386) compiler="$toolchain/bin/o32-gcc"; processor=i386 ;;
    *) exit 1 ;;
  esac
  args+=(-DCMAKE_SYSTEM_NAME=Darwin "-DCMAKE_SYSTEM_PROCESSOR=$processor"
         "-DCMAKE_C_COMPILER=$compiler"
         "-DCMAKE_AR=$toolchain/bin/i386-apple-darwin9-ar"
         "-DCMAKE_RANLIB=$toolchain/bin/i386-apple-darwin9-ranlib"
         "-DCMAKE_OSX_SYSROOT=$toolchain/SDK/MacOSX10.5.sdk"
         "-DCMAKE_OSX_ARCHITECTURES=$mode" -DCMAKE_OSX_DEPLOYMENT_TARGET=10.4
         '-DCMAKE_C_FLAGS=-std=c99 -fno-stack-protector')
fi
if ! cmake -S "$src" -B "$out" "${args[@]}" > "$deps/libical-$mode-configure.log" 2>&1; then
  cat "$deps/libical-$mode-configure.log"; exit 1
fi
if ! cmake --build "$out" --target ical --parallel 4 > "$deps/libical-$mode-build.log" 2>&1; then
  cat "$deps/libical-$mode-build.log"; exit 1
fi
# Some CMake versions cache the host's archive rule while identifying this old
# compiler. Repack with cctools so ld64 receives BSD, not GNU, archive members.
if [ "$mode" != host ]; then
  rm -f "$out/lib/libical-legacy.a"
  "$toolchain/bin/i386-apple-darwin9-ar" rcs "$out/lib/libical-legacy.a" "$out"/src/libical/CMakeFiles/ical.dir/*.o
  "$toolchain/bin/i386-apple-darwin9-ranlib" "$out/lib/libical-legacy.a"
  mv "$out/lib/libical-legacy.a" "$out/lib/libical.a"
fi
