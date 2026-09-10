# Development

## Requirements

- Apple silicon and macOS 26 or later.
- A Swift 6.2-compatible Xcode toolchain.
- Git LFS.

Dependency versions are recorded in `Package.resolved`.

## Build the app

```sh
git lfs install --local
git lfs pull
./scripts/build-app.sh
open dist/Studio.app
```

The build script compiles a release executable and assembles a sandboxed, hardened-runtime app. It chooses an available Apple Development or Developer ID certificate; set `STUDIO_SIGNING_IDENTITY` to select one explicitly.

A real signing team is required to load the updater framework with library validation enabled. With no suitable certificate, packaging can create an ad-hoc inspection artifact, but that artifact cannot launch. The build does not add a library-validation exception.

For compilation without packaging, run:

```sh
swift build
```

Launching the stack requires the packaged, team-signed app and bundled kernel resource.

## Tests

```sh
swift test -c release
```

The regression suite covers lifecycle ownership, shutdown and recovery, probes, configuration expansion, OCI validation, storage cleanup, log streaming, native console selection, listener completion, windows and external links, page confirmations, and updater behavior without starting the full stack.

Packaging checks the complete local HTTP exception policy. To test its rejection
cases and exercise the packaged policy in real WebKit processes, run:

```sh
swift scripts/verify-web-transport.swift --self-test
bash scripts/test-web-transport.sh dist/Studio.app
```

The WebKit smoke test uses hidden, separately signed probe apps, an ephemeral
loopback HTTP fixture, and nonpersistent web data. It reproduces the ATS failure
without the policy, verifies Apps, Labs, custom local endpoint names and nested
apex names load with it, and checks remote HTTP remains blocked. Manifest tests
separately ensure undeclared local hosts and unrelated ports are not trusted
application origins. The probes have only sandbox and client/server network
entitlements; they neither launch Studio's VM nor access its workspace. Evidence
is retained in the temporary directory printed by the script. This test requires
a logged-in macOS GUI session and is separate from headless CI policy checks.

The [September stability audit](audit-2026-09-05.md) records the original findings and remediation status. A full VM startup remains a separate local smoke test because hosted runners do not guarantee nested virtualization.

## Generated and private data

Generated files belong in `.build/` and `dist/`; neither is committed. VM disks, logs, credentials, and app bundles are ignored. Git LFS tracks the bundled kernel. Downloaded images and writable volumes are runtime data and do not belong in the repository.

## Continuous integration

Pushes to `main` and pull requests run tests, assemble the app, verify its signature and security boundary, and retain a packaging-inspection ZIP for seven days. CI uses GitHub's Apple silicon `macos-26` runner and logs the selected toolchain.

Unsigned CI artifacts are for inspection only. Public builds follow the tag, Developer ID signing, notarization, stapling, ZIP, checksum, and signed appcast workflow described in [Release setup](releases.md).
