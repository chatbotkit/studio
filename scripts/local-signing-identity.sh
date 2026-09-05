#!/bin/bash
set -euo pipefail
# Real team signing is required to load Sparkle with library validation.
identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
identity="$(printf '%s\n' "$identities" | awk '/"Apple Development:/ {print $2; exit}')"
if [[ -z "$identity" ]]; then
    identity="$(printf '%s\n' "$identities" | awk '/"Developer ID Application:/ {print $2; exit}')"
fi
printf '%s\n' "${identity:--}"
