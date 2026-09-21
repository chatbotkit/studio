---
name: mint-release
description: Procedure for minting or publishing a version of Studio. Use when the user asks to mint, cut, prepare, release or publish a version, bump VERSION, turn Unreleased changelog notes into a dated release section, or change the release-note format or extraction scripts.
---

# Mint a release

Do not publish a release unless the user explicitly asks. A pushed `vX.Y.Z` tag
triggers the release workflow, so commit, tag and push only on that explicit
request.

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

Only when asked, and from a clean `main` with the version and changelog committed
together:

```sh
scripts/create-release-tag.sh
```

Do not create tags manually.

## Changing the release-note format

Run the extractor's tests whenever the changelog format or the extraction logic
changes:

```sh
bash scripts/test-release-notes.sh
```
