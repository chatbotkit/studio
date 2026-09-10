# Studio release setup

## Changelog and version policy

`VERSION` is the canonical application version (`X.Y.Z`). `CHANGELOG.md` is the
source of truth for user-facing release notes, using Keep a Changelog sections
and Semantic Versioning. Add each user-visible change to the appropriate heading
under **Unreleased** in the same commit. `AGENTS.md` documents this requirement
for future work.

The initial history was reconstructed from commits grouped by the published
`v0.11.0` through `v0.14.0` tags. Dates use the release publication date in
Europe/London. Work after `v0.14.0` remains Unreleased; the reconstruction does
not change existing GitHub releases or tags.

`bash scripts/release-notes.sh X.Y.Z` previews the exact release description. It
requires exactly one dated `## [X.Y.Z] - YYYY-MM-DD` section containing at least
one bullet, and excludes Unreleased, other versions, and comparison-link footers.
Local tagging, release packaging, and CI use the same validator/extractor.
Run `bash scripts/test-release-notes.sh` when changing this process.

## Configure once

Add these encrypted Actions secrets to `chatbotkit/studio` (the names match SuperBot). Do not copy private keys into source files or artifacts:

- `MACOS_CERTIFICATE_P12`: base64-encoded Developer ID Application certificate **and private key**.
- `MACOS_CERTIFICATE_PASSWORD`: password for that archive.
- `APP_STORE_CONNECT_API_KEY_P8`: notarization API private key, as PEM text.
- `APP_STORE_CONNECT_KEY_ID`: its key ID.
- `APP_STORE_CONNECT_ISSUER_ID`: its issuer ID.
- `SPARKLE_PRIVATE_KEY`: Studio's own base64 Ed25519 seed for signing update archives and feeds. Its matching public key is pinned in `Packaging/Info.plist` and verified during packaging.

The workflow imports credentials into an ephemeral runner keychain with restrictive file permissions, never exposes them to pull-request CI, and removes the keychain and key files in an always-run cleanup step. SuperBot's secret values are not automatically available to Studio, and preparing this workflow does not copy them or grant a new repository access to them.

## Development checks

See [updater integration validation](updater-validation.md) for the locally verified scope and remaining production upgrade checks.

```sh
swift test -c release
scripts/build-app.sh
scripts/verify-app.sh dist/Studio.app
```

`STUDIO_BUILD_ROOT` selects a reusable Swift cache. `STUDIO_DIST_ROOT` redirects a local app build (useful for validating packaging without replacing a running app). Version comes from `VERSION`; build number comes from `STUDIO_BUILD_NUMBER`, the Actions run number, or local Git commit count.

Runnable local builds require a real Apple Development or Developer ID identity because hardened-runtime library validation rejects ad-hoc Sparkle loading. Local packaging automatically selects an available identity, or accepts `STUDIO_SIGNING_IDENTITY`. Certificate-free CI artifacts are explicitly packaging-inspection artifacts, not runnable installations. Release CI imports Developer ID credentials before packaging. No `disable-library-validation` entitlement is granted. The disposable VM script also requires a real local identity and re-signs its copy inside-out with that team.

The app icon is generated and compiled programmatically with Xcode's Icon
Composer command-line tools; no editor or manual export is required. Builds
render all six native appearance previews and check foreground contrast.
`verify-app.sh` verifies the packaged `Assets.car` contains default, dark and
mono icon stacks and the separate CBK mark. The compiler-generated ICNS is
included for compatibility. These steps require full Xcode with Icon Composer,
not the standalone Command Line Tools package.

Verification requires an arm64 executable, hardened runtime, strict code signature verification, and only system-library or bundled Sparkle linkage. These five entitlements must be true:

- `com.apple.security.app-sandbox`
- `com.apple.security.network.client`
- `com.apple.security.network.server`
- `com.apple.security.device.audio-input`
- `com.apple.security.virtualization`

The sixth entitlement, `com.apple.security.temporary-exception.mach-lookup.global-name`, contains exactly `ai.cbk.private-oci-stack-spks` and `ai.cbk.private-oci-stack-spki`. The user explicitly approved this installer exception. No other SuperBot exception is copied. Sparkle's Installer.xpc, Autoupdate, Updater.app, and framework are signed inside-out with hardened runtime and the same signing team. Installer tools run outside the sandbox to replace the app; they receive no additional entitlements. The Downloader XPC service is omitted because Studio already has network-client access. The bundled Linux kernel runs inside the VM.

## Update signing and first-release bootstrap

Studio uses its own Keychain account `ai.cbk.studio.updates` and GitHub Actions secret `SPARKLE_PRIVATE_KEY`. Never rotate the pinned public key casually: installed copies must be able to verify the next feed and archive. Back up the key securely through Sparkle's `generate_keys --account ai.cbk.studio.updates -x /secure/location/private.key`; never put exports in the repository or logs. The secret was configured for Studio during integration; SuperBot's signing key was not reused.

The first updater-enabled release must be downloaded and installed manually. Existing 0.11.0 builds have no updater. Publish a new, higher product version when ready; subsequent Sparkle updates compare the release's `CFBundleVersion`, which now follows `VERSION` instead of a CI counter. Normal development bundles keep `StudioUpdatesEnabled=false`; the Developer ID release path sets it true.

Packaging signs the final stapled ZIP and `appcast.xml` using Sparkle's pinned tools, verifies both signatures and the private/public key match, then publishes the assets as a draft release before marking it latest. The feed is `https://github.com/chatbotkit/studio/releases/latest/download/appcast.xml`. Do not edit signed feeds/archives after generation. A new version/tag is still required to publish; configuring secrets does not publish anything.

Before shipping, test a signed older updater-enabled copy upgrading to a signed newer copy, including busy-stack postponement, shutdown failure, relaunch, and retained private data. Local ad-hoc builds and a generated feed do not establish a successful production installation, notarization, or clean-machine Gatekeeper result.

### Disposable local VM smoke test

```sh
bash scripts/runtime-smoke-test.sh /absolute/path/to/Studio.app
```

This copies the supplied bundle into a unique temporary directory, assigns the diagnostic identity `ai.cbk.studio.smoke-test`, and signs/verifies it with a real local identity and the approved entitlement set. It validates Sparkle's packaged configuration with automatic checks/downloads disabled; it does not fetch an update feed or install an update. It does not launch or replace the production app. The diagnostic verifies the current public Compose artifact, downloads small public VM/Alpine images, boots a temporary VM, sends SIGTERM, and checks a shutdown marker from a second container sharing its disposable ext4 volume before tearing down the VM. Runtime fixtures are removed only after confirmed teardown; failures to stop preserve them for investigation. The script retains its diagnostic bundle and log and requires a `STUDIO_SMOKE_PASS` marker plus a successful process exit.

Run this on Apple silicon with network access and at least 1 GiB free; allow additional room for temporary downloads and packaging. It is a real VM boundary test, not a full community-stack startup/migration test and not proof that every upstream service honors SIGTERM. It also does not substitute for Developer ID, Gatekeeper, or clean-machine release testing.

## Release checks

- Configure the six secrets and confirm CI is green.
- Decide whether to retain `ai.cbk.private-oci-stack` as the shipping bundle identifier. It is intentionally unchanged for existing sandbox data; any rename needs a migration plan.
- Review the bundled Linux kernel's corresponding-source distribution and all dependency notices for public redistribution. The current kernel/provenance notices were carried over from the prototype.
- Smoke-test the Developer ID-signed build on Apple silicon macOS 26: first launch/image download, existing-data startup, localhost access, shutdown/restart, logs, Web Inspector, and dragging the app into Applications.
- Verify the downloaded, quarantined release passes Gatekeeper on another Mac. Local ad-hoc tests cannot establish notarization success.
- Note that `platform-studio:latest` remains a moving OCI tag. The app verifies a resolved manifest and digest-pinned images, but an app release does not freeze future stack contents.

## Publish deliberately

Only publish when explicitly requested. Prepare the release on `main`:

1. Choose an unused, higher `X.Y.Z` and set `VERSION` to it.
2. Move the notes being shipped out of Unreleased into a dated
   `## [X.Y.Z] - YYYY-MM-DD` section. Keep the Unreleased heading and any notes
   for work that is not shipping. Never reuse a published version.
3. Update the Unreleased comparison link to start at the new tag and add the
   new version's comparison link against the previous release.
4. Preview the description with `bash scripts/release-notes.sh X.Y.Z`, run
   `bash scripts/test-release-notes.sh` and the development checks above, and
   commit the version and changelog together.
5. With a clean worktree, run:

```sh
scripts/create-release-tag.sh
```

This requires a clean `main` and valid dated release notes, creates an annotated
`vX.Y.Z` tag, and atomically pushes main and the tag. A pushed tag triggers the
release workflow; normal main pushes do not publish a release. CI validates the
version, main ancestry, and changelog before importing credentials. It runs
tests, builds with Developer ID and a secure timestamp, checks Apple's Accepted
result, staples and validates the ticket, and checks Gatekeeper before publishing:

- `Studio-X.Y.Z-macOS-arm64.zip`
- `Studio-X.Y.Z-macOS-arm64.zip.sha256`
- `appcast.xml` (signed Sparkle update feed)

The extracted changelog section becomes the GitHub Release description via
`--notes-file`; CI does not generate notes from commit titles. The release stays
a draft until the curated description and all three assets have uploaded, then
becomes the latest release. Sparkle links to that same release for full notes.
After publishing, verify the release is public, its assets and description are
present, and the latest appcast is accessible.

Local notarization is available via `scripts/package-release.sh vX.Y.Z` with `STUDIO_SIGNING_IDENTITY`, `APPLE_API_KEY_PATH`, `APPLE_API_KEY_ID`, and `APPLE_API_ISSUER_ID` set. It refuses to overwrite an existing release archive. Notarization diagnostics stay in ignored `.release/` and never contain the private key.

Workflow and packaging preparation alone does not mean a public release has been signed, notarized, or tested on a clean machine.
