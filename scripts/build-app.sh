#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="${STUDIO_BUILD_ROOT:-$repo_root/.build}"
kernel="$repo_root/Resources/Runtime/vmlinux-arm64"
dist_root="${STUDIO_DIST_ROOT:-$repo_root/dist}"
app="$dist_root/Studio.app"
identity="${STUDIO_SIGNING_IDENTITY:-$(bash "$repo_root/scripts/local-signing-identity.sh")}"
if [[ "$identity" == - ]]; then
    echo 'Warning: no team signing identity is available. This bundle is for packaging inspection only; hardened-runtime Sparkle loading requires a real signing team.' >&2
fi
version="$(tr -d '[:space:]' < "$repo_root/VERSION")"
build_number="${STUDIO_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-$(git -C "$repo_root" rev-list --count HEAD)}}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$build_number" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo 'VERSION must be X.Y.Z and STUDIO_BUILD_NUMBER must be a numeric version.' >&2
    exit 1
fi
if [[ "$(uname -m)" != arm64 ]]; then
    echo 'Studio requires an Apple silicon build host.' >&2
    exit 1
fi
if [[ "${STUDIO_REQUIRE_DEVELOPER_ID:-0}" == 1 && "$identity" != 'Developer ID Application:'* ]]; then
    echo 'Release builds require a Developer ID Application identity.' >&2
    exit 1
fi

if [[ ! -f "$kernel" ]] || [[ "$(head -c 42 "$kernel")" == 'version https://git-lfs.github.com/spec/v1'* ]]; then
    echo 'The Linux kernel is missing. Run git lfs install --local and git lfs pull.' >&2
    exit 1
fi

mkdir -p "$build_root/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$build_root/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_root/ModuleCache"
swift "$repo_root/scripts/generate-brand-assets.swift" "$repo_root/Resources/Brand" "$build_root/Brand"
mkdir -p "$build_root/Brand/Compiled"
xcrun actool "$build_root/Brand/Studio.icon" \
    --compile "$build_root/Brand/Compiled" --app-icon Studio \
    --platform macosx --minimum-deployment-target 26.0 \
    --output-partial-info-plist "$build_root/Brand/Compiled/icon-info.plist" \
    --output-format human-readable-text
bash "$repo_root/scripts/test-icon-appearances.sh" "$build_root/Brand/Studio.icon" "$build_root/Brand/Previews"
swift build --package-path "$repo_root" --scratch-path "$build_root" -c release --product Studio
bin_dir="$(swift build --package-path "$repo_root" --scratch-path "$build_root" -c release --show-bin-path)"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Runtime" "$app/Contents/Resources/Notices"
mkdir -p "$app/Contents/Resources/Brand"
cp "$build_root/Brand/CBKMark.png" "$build_root/Brand/CBKLogo.png" "$app/Contents/Resources/Brand/"
cp "$build_root/Brand/Compiled/Studio.icns" "$build_root/Brand/Compiled/Assets.car" "$app/Contents/Resources/"
cp "$bin_dir/Studio" "$app/Contents/MacOS/Studio"
binary="$app/Contents/MacOS/Studio"
# Resolve Sparkle from the signed bundle, never the development build cache.
while IFS= read -r search_path; do
    case "$search_path" in
        @executable_path/../Frameworks|/usr/lib/swift) ;;
        *) install_name_tool -delete_rpath "$search_path" "$binary" ;;
    esac
done < <(otool -l "$binary" | awk '/cmd LC_RPATH/ { found=1; next } found && /path / { print $2; found=0 }')
sparkle_source="$build_root/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
# Only replace the generated framework, never runtime data.
if [[ -d "$sparkle" ]]; then rm -r "$sparkle"; fi
ditto "$sparkle_source" "$sparkle"
rm -r "$sparkle/Versions/B/XPCServices/Downloader.xpc"
cp -f "$build_root/checkouts/Sparkle/LICENSE" "$app/Contents/Resources/Notices/Sparkle-LICENSE.txt"
cp -f "$build_root/checkouts/Yams/LICENSE" "$app/Contents/Resources/Notices/Yams-LICENSE.txt"
cp "$repo_root/LICENSE" "$repo_root/NOTICE" "$app/Contents/Resources/Notices/"
cp "$repo_root/Packaging/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
updates_enabled=false
if [[ "${STUDIO_REQUIRE_DEVELOPER_ID:-0}" == 1 ]]; then updates_enabled=true; fi
/usr/libexec/PlistBuddy -c "Add :StudioUpdatesEnabled bool $updates_enabled" "$app/Contents/Info.plist"
cp "$kernel" "$app/Contents/Resources/Runtime/vmlinux-arm64"
cp "$repo_root/Packaging/KERNEL-NOTICE.txt" "$repo_root/Packaging/CONTAINERIZATION-LICENSE.txt" "$app/Contents/Resources/Notices/"
timestamp_option=--timestamp=none
if [[ "${STUDIO_CODESIGN_TIMESTAMP:-0}" == 1 ]]; then timestamp_option=--timestamp; fi
# Approved exception: installer tools run outside the host sandbox to replace
# the app. Sign inside-out without granting unrelated host entitlements.
for component in "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
    codesign --force --options runtime "$timestamp_option" --sign "$identity" "$component"
done
codesign --force --options runtime "$timestamp_option" --sign "$identity" --entitlements "$repo_root/Packaging/Studio.entitlements" "$app"
"$repo_root/scripts/verify-app.sh" "$app"
echo "Built $app"
