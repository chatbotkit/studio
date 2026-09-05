#!/bin/bash
set -euo pipefail
app="${1:?Pass a built Studio.app path}"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
info="$app/Contents/Info.plist"
team="$(codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')"
if [[ "$team" == not\ set || -z "$team" ]]; then
    echo 'Warning: ad-hoc package layout verified, but Sparkle requires a team-signed build to launch under library validation.' >&2
fi
test ! -e "$sparkle/Versions/B/XPCServices/Downloader.xpc"
for key in SUEnableInstallerLauncherService SURequireSignedFeed SUVerifyUpdateBeforeExtraction; do
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$info")" == true ]]
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info")" == 'https://github.com/chatbotkit/studio/releases/latest/download/appcast.xml' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info")" == '598heLqDe1S+kD01yUaXPKqiyrcfzRJOiVVtuF+2ZsY=' ]]
if [[ "${STUDIO_REQUIRE_DEVELOPER_ID:-0}" == 1 ]]; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :StudioUpdatesEnabled' "$info")" == true ]]
fi
signed="$(codesign -d --entitlements - --xml "$app" 2>/dev/null | tr -d '[:space:]')"
[[ "$signed" == *'<key>com.apple.security.temporary-exception.mach-lookup.global-name</key><array><string>ai.cbk.private-oci-stack-spks</string><string>ai.cbk.private-oci-stack-spki</string></array>'* ]]
for component in "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
    codesign --verify --strict "$component"
    details="$(codesign -dv --verbose=4 "$component" 2>&1)"
    [[ "$details" == *"TeamIdentifier=$team"* ]]
    [[ "$details" == *runtime* ]]
    entitlements="$(codesign -d --entitlements - --xml "$component" 2>/dev/null)"
    [[ "$entitlements" != *'<key>'* ]]
done
binary="$app/Contents/MacOS/Studio"
otool -L "$binary" | grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle'
rpaths="$(otool -l "$binary" | awk '/cmd LC_RPATH/ { found=1; next } found && /path / { print $2; found=0 }')"
printf '%s\n' "$rpaths" | grep -Fxq '@executable_path/../Frameworks'
while IFS= read -r search_path; do
    case "$search_path" in @executable_path/../Frameworks|/usr/lib/swift) ;; *) echo "Unsafe runtime search path: $search_path" >&2; exit 1 ;; esac
done <<< "$rpaths"
test -s "$app/Contents/Resources/Notices/Sparkle-LICENSE.txt"
echo 'Verified signed Sparkle components, pinned public key, signed feed, and scoped installer exception.'
