#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
document="${1:?Usage: test-icon-appearances.sh /path/to/Studio.icon /path/to/renders}"
output="${2:?Provide a generated render directory}"
icon_tool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
test -x "$icon_tool"
mkdir -p "$output"
for appearance in Default Dark ClearLight ClearDark TintedLight TintedDark; do
    "$icon_tool" "$document" --export-image --output-file "$output/$appearance.png" \
        --platform macOS --rendition "$appearance" --width 128 --height 128 --scale 2
done
swift "$repo_root/scripts/verify-icon.swift" --renders "$output"
