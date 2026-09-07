#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
extractor="$repo_root/scripts/release-notes.sh"
fixture="$repo_root/Tests/ReleaseNotesFixtures/CHANGELOG.md"
expected='### Added

- Preserve `literal code`, punctuation, and [links](https://example.com).

### Fixed

- A second note.'
[[ "$(bash "$extractor" 1.2.3 "$fixture")" == "$expected" ]]
[[ "$(sed $'s/$/\r/' "$fixture" | bash "$extractor" 1.2.3 /dev/stdin)" == "$expected" ]]
[[ "$(bash "$extractor" 1.0.0 "$fixture")" == $'### Added\n\n- Oldest release.' ]]

# Missing, undated, empty, duplicate and invalid versions fail without output.
for version in 9.9.9 1.3.0 1.4.0 1.5.0 Unreleased '1x2x3'; do
    if output="$(bash "$extractor" "$version" "$fixture" 2>/dev/null)"; then
        echo "Unexpected success for invalid fixture: $version" >&2
        exit 1
    fi
    [[ -z "$output" ]]
done

# Ensure the reconstructed history is consumable by the release workflow.
for version in 0.11.0 0.12.0 0.13.0 0.14.0; do
    bash "$extractor" "$version" >/dev/null
done
echo 'Release-note extraction checks passed.'
