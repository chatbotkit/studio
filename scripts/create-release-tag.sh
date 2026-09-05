#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
version="$(tr -d '[:space:]' < VERSION)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid VERSION.' >&2; exit 1; }
[[ "$(git branch --show-current)" == main ]] || { echo 'Release from main.' >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit all changes first.' >&2; exit 1; }
tag="v$version"
if git rev-parse --verify "refs/tags/$tag" >/dev/null 2>&1; then
    echo "Tag $tag already exists." >&2; exit 1
fi
git tag -a "$tag" -m "Studio $version"
git push --atomic origin main "refs/tags/$tag"
