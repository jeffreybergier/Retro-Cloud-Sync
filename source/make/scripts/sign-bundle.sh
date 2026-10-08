#!/bin/bash
# Seal bundle resources using modern slices, then restore the untouched legacy
# slices. Refresh hashes for nested files after universal assembly, then seal
# those final resources in the modern main executable only.
set -euo pipefail
bundle="$1" pem="${2:-}" lipo="$3"
work=$(mktemp -d "${bundle}.signing.XXXXXX")
trap 'rm -rf "$work"' EXIT
executables=()
while IFS= read -r -d '' binary; do
  if "$lipo" -info "$binary" 2>/dev/null | grep -q 'ppc'; then
    index=${#executables[@]}
    executables+=("$binary")
    "$lipo" "$binary" -thin ppc -output "$work/$index.ppc"
    "$lipo" "$binary" -thin i386 -output "$work/$index.i386"
    "$lipo" "$binary" -extract x86_64 -extract arm64 -output "$work/$index.modern"
    cp "$work/$index.modern" "$binary"
  fi
done < <(find "$bundle/Contents/MacOS" "$bundle/Contents/Library" -type f -print0 2>/dev/null || true)
args=(--timestamp-url none)
if [ -n "$pem" ] && [ -f "$pem" ]; then args+=(--pem-file "$pem"); fi
rcodesign -C /dev/null sign "${args[@]}" "$bundle" > "$work/signing.log" 2>&1 || {
  cat "$work/signing.log" >&2; exit 1;
}
for ((index=0;index<${#executables[@]};index++)); do
  binary="${executables[$index]}"
  "$lipo" -create "$work/$index.ppc" "$work/$index.i386" "$binary" -output "$work/$index.fat"
  cp "$work/$index.fat" "$binary"
done

if [ ${#executables[@]} -gt 0 ]; then
  # LaunchServices helpers are plain resources in rcodesign's envelope. Their
  # hashes must describe the final quad-fat bytes, not the temporary modern fat.
  python3 - "$bundle" <<'PYCODE'
import hashlib
import plistlib
from pathlib import Path
import sys
contents = Path(sys.argv[1]) / 'Contents'
path = contents / '_CodeSignature/CodeResources'
resources = plistlib.loads(path.read_bytes())
for entries in (resources.get('files', {}), resources.get('files2', {})):
    for name, value in entries.items():
        if not name.startswith('Library/LaunchServices/'):
            continue
        data = (contents / name).read_bytes()
        if isinstance(value, bytes):
            entries[name] = hashlib.sha1(data).digest()
        elif isinstance(value, dict):
            if 'hash' in value: value['hash'] = hashlib.sha1(data).digest()
            if 'hash2' in value: value['hash2'] = hashlib.sha256(data).digest()
path.write_bytes(plistlib.dumps(resources))
PYCODE
  identifier=$(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["CFBundleIdentifier"])' "$bundle/Contents/Info.plist")
  for ((index=0;index<${#executables[@]};index++)); do
    binary="${executables[$index]}"
    case "$binary" in "$bundle"/Contents/MacOS/*) ;; *) continue ;; esac
    "$lipo" "$binary" -extract x86_64 -extract arm64 -output "$work/main.modern"
    rcodesign -C /dev/null sign "${args[@]}" --binary-identifier "$identifier" \
      --info-plist-file "$bundle/Contents/Info.plist" \
      --code-resources-file "$bundle/Contents/_CodeSignature/CodeResources" \
      "$work/main.modern" > "$work/main-signing.log" 2>&1 || {
      cat "$work/main-signing.log" >&2; exit 1;
    }
    "$lipo" -create "$work/$index.ppc" "$work/$index.i386" "$work/main.modern" -output "$work/main.fat"
    cp "$work/main.fat" "$binary"
  done
fi
