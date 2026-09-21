#!/bin/bash
# VERSION owns the version; Git tags only record validated releases.
#
#   plan  Report whether the checked-out VERSION requests a release.
#   tag   Record the checked-out VERSION as an annotated tag and push it.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
command="${1:-}"
[[ "$command" == plan || "$command" == tag ]] || { echo 'Usage: release-version.sh plan|tag' >&2; exit 1; }

semver='(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
version="$(tr -d '[:space:]' < VERSION)"
[[ "$version" =~ ^$semver$ ]] || { echo 'Invalid VERSION; expected X.Y.Z.' >&2; exit 1; }
tag="v$version"

newest() { sort -t. -k1,1n -k2,2n -k3,3n | tail -1; }
released="$(git tag --list 'v*' | grep -E "^v$semver$" | sed 's/^v//' || true)"
latest="$(newest <<< "$released")"
if [[ -n "$latest" && "$(printf '%s\n%s\n' "$version" "$latest" | newest)" != "$version" ]]; then
    echo "VERSION $version would roll back released version $latest." >&2; exit 1
fi

head="$(git rev-parse HEAD)"
tagged=''
if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
    tagged="$(git rev-parse "refs/tags/$tag^{commit}")"
else
    # A new VERSION is a release request, so its notes must already be dated.
    bash "$repo_root/scripts/release-notes.sh" "$version" >/dev/null
fi

if [[ "$command" == plan ]]; then
    release=false; resume=false
    if [[ -z "$tagged" ]]; then release=true; fi
    # The tag is pushed just before publication. If publishing then failed, the
    # same commit may finish it; the workflow checks that no release exists.
    if [[ "$tagged" == "$head" ]]; then resume=true; fi
    output="$(printf 'version=%s\ntag=%s\nrelease=%s\nresume=%s' "$version" "$tag" "$release" "$resume")"
    echo "$output"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$output" >> "$GITHUB_OUTPUT"; fi
    exit 0
fi

[[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo 'Refusing to tag modified tracked files.' >&2; exit 1; }
# A retry may find this same commit already tagged, but a release tag never moves.
if [[ -n "$tagged" && "$tagged" != "$head" ]]; then
    echo "$tag already identifies another commit." >&2; exit 1
fi
if [[ -z "$tagged" ]]; then
    git -c user.name='github-actions[bot]' \
        -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
        tag -a "$tag" -m "Studio $version" "$head"
fi
git push --atomic origin "refs/tags/$tag"
echo "$tag"
