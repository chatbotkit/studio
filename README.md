# Studio

A native macOS home for ChatBotKit, with its own embedded Apple Containerization runtime. Studio loads the Compose artifact at `oci://ghcr.io/chatbotkit/platform-studio:latest`, runs the stack in an app-private Linux VM, and displays it in WebKit. It does not invoke the installed `container` CLI.

## Development

Requires Apple silicon, macOS 26+, a Swift 6.2-compatible Xcode toolchain, and Git LFS. Dependency versions are recorded in `Package.resolved`.

```sh
git lfs install --local
git lfs pull
./scripts/build-app.sh
open dist/Studio.app
```

The script builds a release executable and assembles a sandboxed, hardened-runtime app. It chooses an available Apple Development or Developer ID certificate; set `STUDIO_SIGNING_IDENTITY` to choose one explicitly. A real signing team is required to load Sparkle with library validation enabled. Without a certificate, packaging still produces an ad-hoc inspection artifact, but that artifact cannot launch; no library-validation exception is added. For compilation alone, run `swift build`; launching the stack requires the team-signed packaged app and its kernel resource.

The app downloads images on first launch and needs sufficient free disk space for its image store, service disks, and persistent volumes. It publishes the platform on localhost:3000, selecting the next available port if necessary. Logs, stack details, reload, and Web Inspector are available in the Stack menu.

Embedded pages can present native JavaScript confirmations and browser-style
unsaved-change prompts when they register `beforeunload`. Navigating away or
reloading offers **Stay on Page** / **Leave Page**, with Stay as the default.
WebKit retains control of user-activation rules and whether a page requests a
prompt; Studio does not infer dirty state from arbitrary form fields. In-page
routers must still implement their own navigation guard (for example `confirm`).
The macOS `beforeunload` callback currently requires an isolated WebKit private
delegate selector, covered by a real-WebKit regression test. This is not a
promise of protection against native app quit, stack restart, forced termination
or crashes; those do not necessarily perform a browser navigation.

Stack → Manage Storage shows allocated cache/data sizes and previews obsolete-cache cleanup. Cleanup requires confirmation, stops the stack, rechecks the preview, and preserves persistent volumes, backups, and service disks before restarting. Missing last-known-good image metadata makes cleanup retain all image references. Size estimates may double-count shared APFS blocks. Free-space checks reserve 512 MiB of headroom and conservatively budget image pulls and disk creation; they cannot guarantee another application will not consume space mid-operation. Disk replacements are staged and promoted only after successful creation and synchronization.

Page failures and WebKit process termination offer a page-only reload without restarting containers. Readiness follows document loading with a bounded timeout, not pixel brightness. OCI manifests and YAML layers are size/hash-verified before decoding; the adapter limits configuration objects to 2 MiB each.

Run regression tests with `swift test -c release`. Tests cover lifecycle ownership, shutdown ordering and failure recovery, probe cleanup, configuration, OCI validation, log streaming, native console selection, listener completion, and WebKit external-link routing without starting the container stack. The [September stability audit](docs/audit-2026-09-05.md) records findings and remediation status. All nine original known-issue reproductions are now ordinary regression tests.

Studio currently implements a platform-specific Compose adapter, not a general Compose engine. Each service's environment comes from the verified YAML, including anchor merges, map/list syntax, scalar values, explicit empties, and unset variables. Compose-style variable defaults, nested expansions, required/alternative values, and escaped dollars are supported. The Mac's shell environment and `.env` files are never imported; unsupported `env_file`/`extends` fail before VM startup. Only native topology defaults are substituted: the actual platform origin, loopback storage/relay URLs, and app-shell ports. Feature flags (including trusted local sign-in) and storage settings come from the artifact, not a duplicated hardcoded environment.

The adapter forwards platform traffic plus the configured realtime relay (3001) and S3 endpoint (3900), all bound exclusively to `127.0.0.1`. Auxiliary ports must be free; startup fails instead of connecting to another application's services. Port 3001 is excluded from platform fallback. Fixed internal platform/relay/S3/admin ports remain 3000/3001/3900/3903. App-shell and space/portal hostnames remain distinct; their browser DNS behavior is not replaced with system-wide host-file edits. Arbitrary Compose commands, mounts, and network topologies are still outside this adapter's scope.

## Repository layout

- `Sources/Studio/Studio.swift` — current app, runtime, OCI loading, and interface source.
- `Sources/Studio/StudioBrand.swift` — adaptive monochrome palette, CBK logo, launch screen, and About window.
- `Sources/StudioConfiguration/` — configuration expansion, Garage preflight checks, and startup-error summaries.
- `Tests/StudioConfigurationTests/` — configuration and failure-reporting regression tests.
- `Tests/StudioTests/` — lifecycle, OCI, storage, WebKit, and native-console regressions.
- `Packaging/` — app metadata, sandbox entitlements, and runtime notices.
- `Resources/Runtime/` — bundled Linux kernel, tracked with Git LFS.
- `Resources/Brand/` — official CBK SVG symbol and wordmark, with pinned upstream provenance.
- `scripts/build-app.sh` — local build and signing entry point.
- `.github/workflows/` — build/test CI and tag-triggered signed releases.
- `VERSION` — canonical application version, copied into the packaged Info.plist.
- `scripts/package-release.sh` — Developer ID signing, notarization, stapling, ZIP and checksum.
- `scripts/generate-brand-assets.swift` — renders the original vectors into template images and macOS icon sizes during packaging.
- `docs/prototype-history.md` — imported prototype notes and implementation history.

Generated files belong in `.build/` and `dist/`; neither is committed. VM disks, logs, credentials, and app bundles are also ignored. Git LFS tracks the bundled kernel; container images and writable volumes are runtime data and do not belong in this repository.

Studio's native launch and error screens use solid white or black according to macOS appearance. The CBK mark adapts with the foreground color; the Dock icon is black on a flat white tile. About Studio includes the CBK wordmark and product links. Native controls and log selection use neutral accents. The embedded platform retains its own theme, including its existing page-edge color integration.

## Runtime identity

The product and executable are named Studio. The existing bundle identifier `ai.cbk.private-oci-stack` and the `PrivateOCIStack/Runtime` Application Support path are deliberately retained so development builds can reuse the prototype's existing sandbox data. Renaming those requires a planned data migration. Quit the prototype before launching Studio against the same data.

Updated builds lock their runtime directory across processes while running or cleaning caches. Older prototypes do not honor this lock and must still be quit manually before using the same runtime data.

The app retains App Sandbox, network client, network server (local port forwarding), and virtualization. Automatic updates add one approved entitlement containing only the `ai.cbk.private-oci-stack-spks` and `ai.cbk.private-oci-stack-spki` installer communication names. Sparkle's signed Installer XPC service, Autoupdate, and Updater app run outside the host sandbox for the update workflow. Its unnecessary Downloader service is removed. No file-access, automation, or other SuperBot permissions are copied. Containerization remains linked into the sandboxed app and the Linux kernel boots inside the VM.

## App updates

Signed releases include Sparkle 2.9.4, Check for Updates in the Studio menu, and update preferences in Settings. Updates use a signed GitHub appcast plus Ed25519 archive verification before extraction. Automatic checks default to daily; automatic download/install is off by default. Save work in the web page before installing: Studio cannot reliably detect unsaved form state inside arbitrary web content. Installation waits for stack operations, then confirms graceful VM teardown before relaunch. A failed shutdown blocks installation and can be retried in Settings.

Local development and smoke builds disable updates so they cannot replace themselves with a public release. Only the release packaging path enables them. The first updater-enabled release must be installed manually: older releases without Sparkle cannot update themselves. App updates do not migrate or delete private container data, and are separate from resolving the community stack's moving OCI tag. See [release setup](docs/releases.md) for key handling and feed publication.

## CI and releases

Pushes to `main` and pull requests run tests, assemble the app, verify its signature/security boundary, and retain a packaging-inspection ZIP for seven days. Without a signing certificate these ad-hoc artifacts cannot launch with hardened-runtime Sparkle; they are not notarized public releases. CI uses GitHub's Apple silicon `macos-26` runner and its default Xcode; toolchain versions are logged. A full VM startup is a separate local smoke test, not assumed to work under hosted-runner nested virtualization.

The release workflow follows SuperBot's tag → Developer ID → notarization → stapled ZIP and signed appcast pattern, adapted for Studio's kernel, LFS assets, and approved five-key sandbox policy. See [release setup and checklist](docs/releases.md) before publishing a version tag.
