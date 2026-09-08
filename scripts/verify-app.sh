#!/bin/bash
set -euo pipefail
app="${1:?Usage: verify-app.sh /path/to/Studio.app}"
binary="$app/Contents/MacOS/Studio"
codesign --verify --deep --strict "$app"
signature="$(codesign -dv --verbose=4 "$app" 2>&1)"
runtime_pattern='flags=0x[[:xdigit:]]+\([^)]*runtime[,)]'
if [[ ! "$signature" =~ $runtime_pattern ]]; then
    echo 'The application is missing hardened runtime.' >&2
    exit 1
fi
if [[ "${STUDIO_REQUIRE_DEVELOPER_ID:-0}" == 1 && "$signature" != *'Authority=Developer ID Application:'* ]]; then
    echo 'The application is not Developer ID signed.' >&2
    exit 1
fi
entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null | tr -d '[:space:]')"
count="$(printf '%s' "$entitlements" | grep -o '<key>' | wc -l | tr -d '[:space:]')"
[[ "$count" == 6 ]] || { echo 'Unexpected sandbox entitlement count.' >&2; exit 1; }
for key in app-sandbox network.client network.server device.audio-input virtualization; do
    [[ "$entitlements" == *"<key>com.apple.security.$key</key><true/>"* ]] || {
        echo "Missing required entitlement: $key" >&2; exit 1;
    }
done
while IFS= read -r dependency; do
    case "$dependency" in
        /System/Library/*|/usr/lib/*|@rpath/Sparkle.framework/Versions/B/Sparkle) ;;
        *) echo "Unexpected external library: $dependency" >&2; exit 1 ;;
    esac
done < <(otool -L "$binary" | awk '/^\t/ {print $1}')
[[ "$(lipo -archs "$binary")" == arm64 ]] || { echo 'Expected an arm64 executable.' >&2; exit 1; }
test -s "$app/Contents/Resources/Runtime/vmlinux-arm64"
test -s "$app/Contents/Resources/Studio.icns"
test -s "$app/Contents/Resources/Notices/Yams-LICENSE.txt"
plutil -lint "$app/Contents/Info.plist"
swift "$(dirname "${BASH_SOURCE[0]}")/verify-web-transport.swift" "$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$app/Contents/Info.plist")" == \
    'Studio uses your microphone when you start a voice conversation.' ]] || {
    echo 'Missing or unexpected microphone usage description.' >&2; exit 1;
}
bash "$(dirname "${BASH_SOURCE[0]}")/verify-updater.sh" "$app"
echo 'Verified: hardened runtime, six-key approved sandbox policy, microphone disclosure, arm64, system/bundled-Sparkle linkage.'
