#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/studio-release-version.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# A disposable repository and bare remote; never the real tags or origin.
git init -q --bare "$work/remote.git"
git init -q -b main "$work/repo"
cd "$work/repo"
git config user.name 'Release Fixture'
git config user.email 'fixture@example.invalid'
git config commit.gpgsign false
git config tag.gpgsign false
git remote add origin "$work/remote.git"
mkdir scripts
cp "$repo_root/scripts/release-version.sh" "$repo_root/scripts/release-notes.sh" scripts/

changelog() {
    printf '# Changelog\n\n## [Unreleased]\n'
    for entry in "$@"; do printf '\n## [%s]%s\n\n### Added\n\n- A note.\n' "${entry%%|*}" "${entry#*|}"; done
}
commit() { git add -A; git commit -q -m "$1"; }
plan() { bash scripts/release-version.sh plan; }
fails() {
    if output="$("$@" 2>/dev/null)"; then
        echo "Unexpected success: $*" >&2; exit 1
    fi
    [[ -z "$output" ]]
}

# An untagged VERSION with dated notes requests a release.
echo 1.0.0 > VERSION
changelog '1.0.0| - 2026-01-01' > CHANGELOG.md
commit 'Version 1.0.0'
[[ "$(plan)" == $'version=1.0.0\ntag=v1.0.0\nrelease=true\nresume=false' ]]

# GitHub Actions receives the same values.
GITHUB_OUTPUT="$work/output" plan >/dev/null
[[ "$(cat "$work/output")" == $'version=1.0.0\ntag=v1.0.0\nrelease=true\nresume=false' ]]

# Tagging refuses modified tracked files, then records and pushes the tag.
echo 'edited' >> CHANGELOG.md
fails bash scripts/release-version.sh tag
git checkout -q CHANGELOG.md
bash scripts/release-version.sh tag >/dev/null 2>&1
[[ "$(git cat-file -t v1.0.0)" == tag ]]
[[ "$(git for-each-ref --format='%(contents:subject)' refs/tags/v1.0.0)" == 'Studio 1.0.0' ]]
[[ "$(git --git-dir="$work/remote.git" rev-parse 'v1.0.0^{commit}')" == "$(git rev-parse HEAD)" ]]

# A retry of the same commit is accepted and only offers to resume publication.
bash scripts/release-version.sh tag >/dev/null 2>&1
[[ "$(plan)" == $'version=1.0.0\ntag=v1.0.0\nrelease=false\nresume=true' ]]

# Later work under a released VERSION requests nothing.
echo 'work' > file.txt
commit 'Later work'
[[ "$(plan)" == $'version=1.0.0\ntag=v1.0.0\nrelease=false\nresume=false' ]]

# A release tag never moves to another commit.
fails bash scripts/release-version.sh tag

# A new VERSION needs its dated notes before it can be planned or tagged.
echo 1.1.0 > VERSION
commit 'Version 1.1.0 without notes'
fails plan
fails bash scripts/release-version.sh tag
changelog '1.1.0|' '1.0.0| - 2026-01-01' > CHANGELOG.md
commit 'Undated notes'
fails plan
changelog '1.1.0| - 2026-02-01' '1.0.0| - 2026-01-01' > CHANGELOG.md
commit 'Dated notes'
[[ "$(plan)" == $'version=1.1.0\ntag=v1.1.0\nrelease=true\nresume=false' ]]

# Versions order numerically, and a released version is never rolled back.
git tag -a v1.10.0 -m 'Studio 1.10.0'
echo 1.9.0 > VERSION
changelog '1.9.0| - 2026-03-01' > CHANGELOG.md
commit 'Rollback'
fails plan
fails bash scripts/release-version.sh tag

# Malformed versions and unknown commands fail without output.
echo v2 > VERSION
fails plan
echo 2.0.0 > VERSION
fails bash scripts/release-version.sh publish
fails bash scripts/release-version.sh

echo 'Release version checks passed.'
