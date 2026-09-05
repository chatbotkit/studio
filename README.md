# Studio

A native macOS home for ChatBotKit, with its own embedded Apple Containerization runtime. Studio loads the Compose artifact at `oci://ghcr.io/chatbotkit/platform-community:latest`, runs the stack in an app-private Linux VM, and displays it in WebKit. It does not invoke the installed `container` CLI.

## Development

Requires Apple silicon, macOS 26+, a Swift 6.2-compatible Xcode toolchain, and Git LFS. Dependency versions are recorded in `Package.resolved`.

```sh
git lfs install --local
git lfs pull
./scripts/build-app.sh
open dist/Studio.app
```

The script builds a release executable and assembles a sandboxed, hardened-runtime, ad-hoc-signed app. Set `STUDIO_SIGNING_IDENTITY` to choose another signing identity. For compilation alone, run `swift build`; launching the stack requires the packaged app and its kernel resource.

The app downloads images on first launch and needs sufficient free disk space for its image store, service disks, and persistent volumes. It publishes the platform on localhost:3000, selecting the next available port if necessary. Logs, stack details, reload, and Web Inspector are available in the Stack menu.

Stack → Manage Storage shows allocated cache/data sizes and previews obsolete-cache cleanup. Cleanup requires confirmation, stops the stack, rechecks the preview, and preserves persistent volumes, backups, and service disks before restarting. Missing last-known-good image metadata makes cleanup retain all image references. Size estimates may double-count shared APFS blocks. Free-space checks reserve 512 MiB of headroom and conservatively budget image pulls and disk creation; they cannot guarantee another application will not consume space mid-operation. Disk replacements are staged and promoted only after successful creation and synchronization.

Page failures and WebKit process termination offer a page-only reload without restarting containers. Readiness follows document loading with a bounded timeout, not pixel brightness. OCI manifests and YAML layers are size/hash-verified before decoding; the adapter limits configuration objects to 2 MiB each.

Run regression tests with `swift test -c release`. Tests cover lifecycle ownership, shutdown ordering and failure recovery, probe cleanup, configuration, OCI validation, log streaming, native console selection, listener completion, and WebKit external-link routing without starting the container stack. The [September stability audit](docs/audit-2026-09-05.md) records findings and remediation status. All nine original known-issue reproductions are now ordinary regression tests.

Studio currently implements a platform-specific Compose adapter, not a general Compose engine. Inline Garage configuration supports Compose-style variable defaults, nested expansions, required/alternative values, and escaped dollars. It uses artifact defaults, not the Mac's shell environment; missing variables fail before VM startup. The adapter validates its fixed internal S3/admin ports (3900/3903). Supporting custom internal ports also requires updating the service URLs and health checks together.

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

The app retains its existing sandbox entitlements: App Sandbox, network client, network server (local port forwarding), and virtualization. There are no bundled macOS helper executables; Containerization is linked into the app and the Linux kernel boots inside the VM.

## CI and releases

Pushes to `main` and pull requests run tests, build the app, verify its signature/security boundary, and retain a development ZIP for seven days. These ad-hoc-signed builds are not notarized public releases. CI uses GitHub's Apple silicon `macos-26` runner and its default Xcode; toolchain versions are logged. A full VM startup is a separate local smoke test, not assumed to work under hosted-runner nested virtualization.

The release workflow follows SuperBot's tag → Developer ID → notarization → stapled ZIP pattern, adapted for Studio's kernel, LFS assets, and four-key sandbox policy. See [release setup and checklist](docs/releases.md) before pushing the first version tag.
