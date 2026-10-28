#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
vendor_dir="$script_dir/../Vendor/MobileVLCKit"
destination="$vendor_dir/MobileVLCKit.xcframework"
normalize_manifest() {
  # Debug symbols are omitted from the app build; remove their paths from XCFramework metadata.
  python3 - "$destination/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as source:
    data = plistlib.load(source)
for library in data.get('AvailableLibraries', []):
    library.pop('DebugSymbolsPath', None)
with open(path, 'wb') as output:
    plistlib.dump(data, output)
PY
}
if [[ -d "$destination" ]]; then
  echo "MobileVLCKit.xcframework already exists: $destination"
  normalize_manifest
  exit 0
fi

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
archive="$temporary_dir/mobilevlckit.tar.xz"
curl -fL --retry 3 --connect-timeout 30 \
  'https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.6.0-c73b779f-dd8bfdba.tar.xz' \
  -o "$archive"
echo "1a5077beeb7bf943a3fbbb91523752e50a10d490a3046cb9808d906784ddbc36  $archive" | shasum -a 256 -c -
tar -xJf "$archive" -C "$temporary_dir" --exclude '*/dSYMs/*' 'MobileVLCKit-binary/MobileVLCKit.xcframework'
mkdir -p "$vendor_dir"
mv "$temporary_dir/MobileVLCKit-binary/MobileVLCKit.xcframework" "$destination"
normalize_manifest
