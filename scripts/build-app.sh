#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="${STUDIO_BUILD_ROOT:-$repo_root/.build}"
kernel="$repo_root/Resources/Runtime/vmlinux-arm64"
app="$repo_root/dist/Studio.app"
identity="${STUDIO_SIGNING_IDENTITY:--}"

if [[ ! -f "$kernel" ]] || [[ "$(head -c 42 "$kernel")" == 'version https://git-lfs.github.com/spec/v1'* ]]; then
    echo 'The Linux kernel is missing. Run git lfs install --local and git lfs pull.' >&2
    exit 1
fi

mkdir -p "$build_root/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$build_root/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_root/ModuleCache"
swift "$repo_root/scripts/generate-brand-assets.swift" "$repo_root/Resources/Brand" "$build_root/Brand"
iconutil -c icns "$build_root/Brand/Studio.iconset" -o "$build_root/Brand/Studio.icns"
swift build --package-path "$repo_root" --scratch-path "$build_root" -c release --product Studio
bin_dir="$(swift build --package-path "$repo_root" --scratch-path "$build_root" -c release --show-bin-path)"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Runtime" "$app/Contents/Resources/Notices"
mkdir -p "$app/Contents/Resources/Brand"
cp "$build_root/Brand/CBKMark.png" "$build_root/Brand/CBKLogo.png" "$app/Contents/Resources/Brand/"
cp "$build_root/Brand/Studio.icns" "$app/Contents/Resources/Studio.icns"
cp "$bin_dir/Studio" "$app/Contents/MacOS/Studio"
cp "$repo_root/Packaging/Info.plist" "$app/Contents/Info.plist"
cp "$kernel" "$app/Contents/Resources/Runtime/vmlinux-arm64"
cp "$repo_root/Packaging/KERNEL-NOTICE.txt" "$repo_root/Packaging/CONTAINERIZATION-LICENSE.txt" "$app/Contents/Resources/Notices/"
codesign --force --sign "$identity" --entitlements "$repo_root/Packaging/Studio.entitlements" "$app"
codesign --verify --deep --strict "$app"
echo "Built $app"
