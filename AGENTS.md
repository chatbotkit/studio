# Project instructions

## Release notes

Keep `CHANGELOG.md` current as part of every user-visible change. Add a concise entry under the appropriate heading in **Unreleased** in the same change; do not wait for release preparation to reconstruct it later.

When the user asks to mint or publish a version, follow the complete process in [`docs/releases.md`](docs/releases.md). Move the relevant Unreleased notes into a dated version section, keep any remaining work under Unreleased, update the comparison links and `VERSION`, and use the changelog entry as the release description. Do not publish a release unless the user explicitly asks.

Use `bash scripts/release-notes.sh X.Y.Z` to validate and preview the exact release description. Local tagging, packaging, and release CI share this extractor; do not replace curated notes with generated commit lists. Run `bash scripts/test-release-notes.sh` when changing the release-note format or extraction logic.
