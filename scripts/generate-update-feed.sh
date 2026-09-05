#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive="${1:?Pass the final signed and stapled release archive}"
tag="${2:?Pass the release tag}"
version="$(tr -d '[:space:]' < "$repo_root/VERSION")"
[[ "$tag" == "v$version" ]]
[[ "$(basename "$archive")" == "Studio-$version-macOS-arm64.zip" ]]
: "${SPARKLE_PRIVATE_KEY_PATH:?Set the Studio update-signing key path}"
swift "$repo_root/scripts/verify-update-key.swift" "$SPARKLE_PRIVATE_KEY_PATH" "$repo_root/Packaging/Info.plist"
build_root="${STUDIO_BUILD_ROOT:-$repo_root/.build}"
tools="$build_root/artifacts/sparkle/Sparkle/bin"
# Exclude stale archives/feeds from earlier releases without deleting them.
feed_dir="$(mktemp -d "$(dirname "$archive")/feed.XXXXXX")"
cp "$archive" "$feed_dir/"
"$tools/generate_appcast" --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" \
    --download-url-prefix "https://github.com/chatbotkit/studio/releases/download/$tag/" \
    --full-release-notes-url "https://github.com/chatbotkit/studio/releases/tag/$tag" \
    --maximum-deltas 0 "$feed_dir"
feed="$feed_dir/appcast.xml"
test -s "$feed"
"$tools/sign_update" --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" --verify "$feed"
signature="$(xmllint --xpath 'string(//enclosure/@*[local-name()="edSignature"])' "$feed")"
test -n "$signature"
"$tools/sign_update" --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" --verify "$archive" "$signature"
cp "$feed" "$(dirname "$archive")/appcast.xml"
echo 'Signed and verified release archive and update feed.'
