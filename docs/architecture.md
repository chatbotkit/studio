# Architecture

Studio is a native Swift macOS application with an embedded Apple Containerization runtime and WebKit interface. It loads the verified Compose artifact at `oci://ghcr.io/chatbotkit/platform-studio:latest`, starts it in an app-private Linux VM, and displays the platform on a local origin.

It does not invoke an installed `container` command and its containers do not appear in a separate container CLI's inventory.

## Runtime lifecycle

One application process owns one runtime and VM. Multiple Studio windows reuse that running stack. Updated builds lock the runtime directory while running or cleaning caches to avoid concurrent ownership.

Image manifests, configuration layers, and YAML content are size- and hash-verified before decoding. Configuration objects are limited to 2 MiB. Disk replacements are staged and promoted only after successful creation and synchronization.

## Compose scope

Studio implements a platform-specific Compose adapter, not a general Compose engine. It supports the environment forms required by the platform artifact, including anchor merges, map and list syntax, scalar values, explicit empty values, unset variables, defaults, nested expansions, required or alternative values, and escaped dollar signs.

The Mac shell environment and `.env` files are not imported. Unsupported `env_file` and `extends` declarations fail before VM startup. Arbitrary Compose commands, mounts, and network topologies remain outside this adapter's scope.

Only native topology values are substituted: the actual platform origin, loopback storage and relay URLs, and app-shell ports. Feature flags and storage settings come from the artifact.

## Networking

Platform traffic is published on localhost port 3000, with the next available port selected when necessary. The realtime relay uses 3001 and the S3 endpoint uses 3900. All host listeners bind exclusively to `127.0.0.1`.

Auxiliary ports must be available; Studio fails startup instead of attaching to another application's listener. Port 3001 is excluded from platform fallback. Internal platform, relay, S3, and admin ports remain 3000, 3001, 3900, and 3903.

App-shell and space or portal hostnames remain distinct. Studio does not modify the system hosts file. VM DNS and the default route are derived from the active virtual network rather than a hardcoded gateway address.

## Runtime identity

The product and executable are named Studio. The existing bundle identifier `ai.cbk.private-oci-stack` and the `PrivateOCIStack/Runtime` Application Support path are retained so current builds can reuse data created by the prototype. Changing them requires an explicit data migration.

Older prototype builds do not honor the runtime lock and must be quit before Studio uses the same data.

## Source layout

- `Sources/Studio/Studio.swift` — application, runtime, OCI loading, WebKit, and primary interface.
- `Sources/Studio/StudioBrand.swift` — adaptive product branding and native launch presentation.
- `Sources/StudioConfiguration/` — configuration expansion, startup preflight, and error summaries.
- `Tests/StudioConfigurationTests/` — configuration and failure-reporting regressions.
- `Tests/StudioTests/` — lifecycle, OCI, storage, WebKit, window, and console regressions.
- `Packaging/` — application metadata, entitlements, and runtime notices.
- `Resources/Runtime/` — bundled Linux kernel tracked with Git LFS.
- `Resources/Brand/` — official CBK vector assets with pinned provenance.
- `scripts/` — building, branding, release packaging, and validation.
- `.github/workflows/` — continuous integration and signed releases.
- `VERSION` — canonical packaged application version.
