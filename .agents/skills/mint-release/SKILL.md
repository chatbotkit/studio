---
name: mint-release
description: Procedure for minting or publishing a version of Studio. Use when the user asks to mint, cut, prepare, release or publish a version, bump VERSION, turn Unreleased changelog notes into a dated release section, or change the release-note format, the version planning script or the release workflow.
---

# Mint a release

Do not publish a release unless the user explicitly asks. `VERSION` owns the
version: pushing a new `VERSION` to `main` requests publication, so commit and
push only on that explicit request.

The complete process, including secrets, signing, notarization, CI behaviour and
the release checks, is in [`docs/releases.md`](../../../docs/releases.md). Read it
first and follow it; this skill only summarises the preparation.

## Prepare

1. Set `VERSION` to an unused, higher `X.Y.Z`. Never reuse a published version.
2. Move the notes being shipped out of Unreleased in `CHANGELOG.md` into
   `## [X.Y.Z] - YYYY-MM-DD`. Keep the Unreleased heading and any notes for work
   that is not shipping.
3. Point the Unreleased comparison link at the new tag and add the new version's
   comparison link against the previous release.
4. Preview the exact release description:

   ```sh
   bash scripts/release-notes.sh X.Y.Z
   ```

   Local tagging, packaging and release CI share this extractor. The changelog
   entry is the release description; do not replace curated notes with a
   generated commit list.
5. Run the affected tests and review the changes.

## Publish

Only when asked: commit the version and changelog together and push `main`. The
Release workflow tests, builds, signs and notarizes that commit, records the
annotated `vX.Y.Z` tag itself and publishes the release.

Do not create tags manually or reuse published versions. A failed run leaves
`VERSION` untagged, so the next push to `main` or a re-run tries again.

Check what a checkout would do without changing anything:

```sh
bash scripts/release-version.sh plan
```

## Changing the release process

Run the script tests whenever the changelog format, the extraction logic or the
version planning changes:

```sh
bash scripts/test-release-notes.sh
bash scripts/test-release-version.sh
```
