# Studio release setup

## Configure once

Add these encrypted Actions secrets to `chatbotkit/studio` (the names match SuperBot). Do not copy private keys into source files or artifacts:

- `MACOS_CERTIFICATE_P12`: base64-encoded Developer ID Application certificate **and private key**.
- `MACOS_CERTIFICATE_PASSWORD`: password for that archive.
- `APP_STORE_CONNECT_API_KEY_P8`: notarization API private key, as PEM text.
- `APP_STORE_CONNECT_KEY_ID`: its key ID.
- `APP_STORE_CONNECT_ISSUER_ID`: its issuer ID.

The workflow imports credentials into an ephemeral runner keychain with restrictive file permissions, never exposes them to pull-request CI, and removes the keychain and key files in an always-run cleanup step. SuperBot's secret values are not automatically available to Studio, and preparing this workflow does not copy them or grant a new repository access to them.

## Development checks

```sh
swift test -c release
scripts/build-app.sh
scripts/verify-app.sh dist/Studio.app
```

`STUDIO_BUILD_ROOT` selects a reusable Swift cache. `STUDIO_DIST_ROOT` redirects a local app build (useful for validating packaging without replacing a running app). Version comes from `VERSION`; build number comes from `STUDIO_BUILD_NUMBER`, the Actions run number, or local Git commit count.

Verification requires an arm64 executable, hardened runtime, strict code signature verification, and only system-library linkage. Exactly these entitlements must be true, with no extras:

- `com.apple.security.app-sandbox`
- `com.apple.security.network.client`
- `com.apple.security.network.server`
- `com.apple.security.virtualization`

There are no macOS helper executables in this app. The bundled Linux kernel runs inside the VM. No sandbox exceptions from SuperBot are copied.

## Before the first public release

- Configure the five secrets and confirm CI is green.
- Decide whether to retain `ai.cbk.private-oci-stack` as the shipping bundle identifier. It is intentionally unchanged for existing sandbox data; any rename needs a migration plan.
- Review the bundled Linux kernel's corresponding-source distribution and all dependency notices for public redistribution. The current kernel/provenance notices were carried over from the prototype.
- Smoke-test the Developer ID-signed build on Apple silicon macOS 26: first launch/image download, existing-data startup, localhost access, shutdown/restart, logs, Web Inspector, and dragging the app into Applications.
- Verify the downloaded, quarantined release passes Gatekeeper on another Mac. Local ad-hoc tests cannot establish notarization success.
- Note that `platform-community:latest` remains a moving OCI tag. The app verifies a resolved manifest and digest-pinned images, but an app release does not freeze future stack contents.

## Publish deliberately

Set `VERSION` to an unused `X.Y.Z`, commit on `main`, then run:

```sh
scripts/create-release-tag.sh
```

This requires a clean `main`, creates an annotated `vX.Y.Z` tag, and atomically pushes main and the tag. A pushed tag triggers the release workflow; normal main pushes do not publish a release. The workflow validates the version and main ancestry, runs tests, builds with Developer ID and a secure timestamp, checks Apple's Accepted result, staples and validates the ticket, and checks Gatekeeper before publishing:

- `Studio-X.Y.Z-macOS-arm64.zip`
- `Studio-X.Y.Z-macOS-arm64.zip.sha256`

Local notarization is available via `scripts/package-release.sh vX.Y.Z` with `STUDIO_SIGNING_IDENTITY`, `APPLE_API_KEY_PATH`, `APPLE_API_KEY_ID`, and `APPLE_API_ISSUER_ID` set. It refuses to overwrite an existing release archive. Notarization diagnostics stay in ignored `.release/` and never contain the private key.

Workflow and packaging preparation alone does not mean a public release has been signed, notarized, or tested on a clean machine.
