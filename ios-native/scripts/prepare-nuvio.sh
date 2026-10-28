#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
vendor_dir="$script_dir/../Vendor/NuvioEngine"
destination="$vendor_dir/NuvioEngine.xcframework"
if [[ -d "$destination" ]]; then
  echo "NuvioEngine.xcframework already exists: $destination"
  exit 0
fi

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
archive="$temporary_dir/nuvio-engine.zip"
curl -fL --retry 3 --connect-timeout 30 \
  'https://github.com/NuvioMedia/nuvio-engine/releases/download/v0.1.6/nuvio-engine-apple-0.1.6.zip' \
  -o "$archive"
echo "f556718ec0fd122a61bc5408307b19fcd54397595954c46c6ff8db1e5a179421  $archive" | shasum -a 256 -c -
unzip -q "$archive" -d "$temporary_dir"
mkdir -p "$vendor_dir"
mv "$temporary_dir/nuvio-engine-apple-0.1.6/NuvioEngine.xcframework" "$destination"
