#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:-$(tr -d '[:space:]' < "$repo_root/VERSION")}"
changelog="${2:-$repo_root/CHANGELOG.md}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid release version; expected X.Y.Z.' >&2; exit 1; }

# Buffer until validation finishes so failure never emits partial release notes.
awk -v version="$version" '
    { sub(/\r$/, "") }
    /^## / {
        active = 0
        if (index($0, "## [" version "]") == 1) {
            sections++
            date = substr($0, length("## [" version "]") + 1)
            if (date !~ /^ - [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) invalid = 1
            active = 1
        }
        next
    }
    /^\[[^]]+\]:[[:space:]]/ { active = 0 }
    active {
        notes = notes $0 "\n"
        if ($0 ~ /^- [^[:space:]]/) entries++
    }
    END {
        if (sections != 1 || invalid || !entries) {
            print "CHANGELOG.md must contain exactly one dated, nonempty section for " version ". Prepare its release notes from Unreleased first." > "/dev/stderr"
            exit 1
        }
        sub(/^\n+/, "", notes)
        sub(/\n+$/, "", notes)
        print notes
    }
' "$changelog"
