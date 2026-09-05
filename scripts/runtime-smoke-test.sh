#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${1:?Usage: runtime-smoke-test.sh /path/to/Studio.app}"
identity="${STUDIO_SMOKE_SIGNING_IDENTITY:-$(bash "$repo_root/scripts/local-signing-identity.sh")}"
[[ "$identity" != - ]] || { echo 'The runtime smoke test requires an Apple Development or Developer ID signing identity.' >&2; exit 1; }
"$repo_root/scripts/verify-app.sh" "$app"
smoke_root="$(mktemp -d "${TMPDIR%/}/studio-smoke-app.XXXXXX")"
smoke_app="$smoke_root/Studio Smoke.app"
ditto "$app" "$smoke_app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier ai.cbk.studio.smoke-test' "$smoke_app/Contents/Info.plist"
sparkle="$smoke_app/Contents/Frameworks/Sparkle.framework"
for component in "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
    codesign --force --options runtime --timestamp=none --sign "$identity" "$component"
done
codesign --force --options runtime --timestamp=none --sign "$identity" --entitlements "$repo_root/Packaging/Studio.entitlements" "$smoke_app"
"$repo_root/scripts/verify-app.sh" "$smoke_app"
"$smoke_app/Contents/MacOS/Studio" --runtime-smoke-test | tee "$smoke_root/smoke.log"
rg -q '^STUDIO_SMOKE_PASS:' "$smoke_root/smoke.log"
echo "Smoke evidence: $smoke_root/smoke.log"
