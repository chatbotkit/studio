#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(tr -d '[:space:]' < "$repo_root/VERSION")"
tag="${1:?Usage: package-release.sh vX.Y.Z}"
[[ "$tag" == "v$version" ]] || { echo 'Release tag must match VERSION.' >&2; exit 1; }
: "${STUDIO_SIGNING_IDENTITY:?Set a Developer ID Application identity.}"
: "${APPLE_API_KEY_PATH:?Set the notarization API key path.}"
: "${APPLE_API_KEY_ID:?Set the notarization key ID.}"
: "${APPLE_API_ISSUER_ID:?Set the notarization issuer ID.}"
: "${SPARKLE_PRIVATE_KEY_PATH:?Set the Studio update-signing key path.}"
export STUDIO_REQUIRE_DEVELOPER_ID=1
export STUDIO_CODESIGN_TIMESTAMP=1
export STUDIO_DIST_ROOT="$repo_root/dist"
# Order updates by the product version, not a resettable CI run counter.
export STUDIO_BUILD_NUMBER="$version"
# Each submission gets its own temporary workspace; never clear dist or runtime data.
mkdir -p "$repo_root/.release" "$STUDIO_DIST_ROOT"
notary_dir="$(mktemp -d "$repo_root/.release/notary.XXXXXX")"
app="$STUDIO_DIST_ROOT/Studio.app"
archive="$STUDIO_DIST_ROOT/Studio-$version-macOS-arm64.zip"
[[ ! -e "$archive" ]] || { echo "Archive already exists: $archive" >&2; exit 1; }
"$repo_root/scripts/build-app.sh"
ditto -c -k --sequesterRsrc --keepParent "$app" "$notary_dir/Studio.zip"
xcrun notarytool submit "$notary_dir/Studio.zip" \
    --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID" --wait --output-format json > "$notary_dir/result.json"
if [[ "$(plutil -extract status raw -o - "$notary_dir/result.json")" != Accepted ]]; then
    echo "Apple did not accept the submission; see $notary_dir/result.json" >&2
    exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
"$repo_root/scripts/verify-app.sh" "$app"
spctl --assess --type execute --verbose=2 "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
(cd "$STUDIO_DIST_ROOT" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
bash "$repo_root/scripts/generate-update-feed.sh" "$archive" "$tag"
echo "$archive"
