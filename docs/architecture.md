# Architecture

Studio is a native Swift macOS application with an embedded Apple Containerization runtime and WebKit interface. It loads the verified Compose artifact at `oci://ghcr.io/chatbotkit/platform-studio:latest`, starts it in an app-private Linux VM, and displays the platform on a local origin.

It does not invoke an installed `container` command and its containers do not appear in a separate container CLI's inventory.

## Runtime lifecycle

One application process owns one runtime and VM. Multiple Studio windows reuse that running stack. Updated builds lock the runtime directory while running or cleaning caches to avoid concurrent ownership.

Image manifests, configuration layers, and YAML content are size- and hash-verified before decoding. Configuration objects are limited to 2 MiB. Disk replacements are staged and promoted only after successful creation and synchronization.

## Compose scope

Studio implements a platform-specific Compose adapter, not a general Compose engine. It supports the environment forms required by the platform artifact, including anchor merges, map and list syntax, scalar values, explicit empty values, unset variables, defaults, nested expansions, required or alternative values, and escaped dollar signs.

The Mac shell environment and `.env` files are not imported. Unsupported `env_file` and `extends` declarations fail before VM startup. Arbitrary Compose commands, mounts, and network topologies remain outside this adapter's scope.

The `x-cbk` version 1 endpoint manifest and all service environments are resolved together from one parsed YAML node with the same explicit variables. Artifacts without a valid manifest are rejected; there is no legacy-address fallback. Only native topology values are substituted: allocated platform, relay and storage ports, the actual platform origin, and loopback storage and relay URLs. Apps/Labs origins and space/portal apexes come from the artifact, not a native hostname list. Feature flags and storage settings also come from the artifact.

## Networking

The manifest declares preferred site, relay and storage ports (currently 31000, 31001 and 31900 in the new Studio artifact). The site may use the next available port within a +9 window, excluding both auxiliary ports. Studio then resolves the manifest and environments again with the chosen ports. All host listeners bind exclusively to `127.0.0.1`.

Auxiliary ports must be available; Studio fails startup instead of attaching to another application's listener. Published ports and container ports are distinct: the platform and relay still listen inside the VM on environment ports 3000 and 3001. Garage's S3 port must equal the allocated storage port on both sides; its admin port remains 3903. The bridge derives its targets from these resolved container settings, with the first target using the bare Unix socket and subsequent targets using a port suffix.

App-shell and space or portal hostnames remain distinct. The VM hosts entry includes service names, manifest URL hosts and apexes, but cannot express apex wildcards. Studio does not modify the Mac's system hosts file or add wildcard DNS. VM DNS and the default route are derived from the active virtual network rather than a hardcoded gateway address.

Only HTTP endpoints with explicit matching ports on loopback literals or valid `.localhost` names are accepted. Internal-window routing also checks ports and apex boundaries, so unrelated local apps do not become trusted origins. See [endpoint manifest validation](endpoint-manifest-validation.md) for fixtures and verification evidence.

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
