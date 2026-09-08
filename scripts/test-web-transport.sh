#!/bin/bash
set -euo pipefail
app="${1:?Usage: test-web-transport.sh /path/to/Studio.app}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe_root="$(mktemp -d "${TMPDIR:-/tmp}/studio-web-transport.XXXXXX")"
identity="$(bash "$repo_root/scripts/local-signing-identity.sh")"
swiftc "$repo_root/Tests/WebTransportProbe/main.swift" -o "$probe_root/Probe"
plutil -create xml1 "$probe_root/Probe.entitlements"
for capability in app-sandbox network.client network.server; do
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.$capability bool true" "$probe_root/Probe.entitlements"
done
for mode in baseline fixed; do
    probe_app="$probe_root/$mode.app"
    mkdir -p "$probe_app/Contents/MacOS"
    cp "$probe_root/Probe" "$probe_app/Contents/MacOS/Probe"
    # Use the packaged policy, not a duplicate test definition.
    cp "$app/Contents/Info.plist" "$probe_app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ai.cbk.studio.transport.$mode" "$probe_app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Probe' "$probe_app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$probe_app/Contents/Info.plist"
    if [[ "$mode" == baseline ]]; then
        /usr/libexec/PlistBuddy -c 'Delete :NSAppTransportSecurity' "$probe_app/Contents/Info.plist"
    fi
    codesign --force --options runtime --timestamp=none --sign "$identity" --entitlements "$probe_root/Probe.entitlements" "$probe_app"
    codesign --verify --deep --strict "$probe_app"
    open -n -g -j -W --stdout "$probe_root/$mode.log" --stderr "$probe_root/$mode.err" "$probe_app" --args "--$mode"
    cat "$probe_root/$mode.log"
    rg -q '^STUDIO_TRANSPORT_PASS:' "$probe_root/$mode.log"
done
echo "Web transport test evidence: $probe_root"
