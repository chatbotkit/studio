# Security and privacy

## Native sandbox

Studio retains the macOS App Sandbox and requests only:

- Outbound network access for image downloads and platform connectivity.
- Inbound network access for loopback-only local forwarding.
- Audio input for microphone features in the trusted local workspace.
- Virtualization for its private Linux VM.
- The two Sparkle installer communication names required for signed application updates: `ai.cbk.private-oci-stack-spks` and `ai.cbk.private-oci-stack-spki`.

It does not request general file access, camera access, Apple Events automation, or a blanket library-validation exception.

Sparkle's signed Installer XPC service, Autoupdate, and Updater components operate outside the host sandbox for the update workflow. The unused Downloader service is removed.

## Runtime boundary

Containerization is linked into the sandboxed application and the bundled Linux kernel boots inside Studio's VM. Host listeners use loopback addresses only. Studio neither depends on nor controls another installed container runtime.

Studio ignores `SIGPIPE` before starting runtime workers so a disconnected socket
returns `EPIPE` to Containerization's existing relay error handling instead of
terminating the app. Other signals are unchanged. The regression-only
`StudioCrashProbe` executable is not bundled or granted application entitlements.

## Data and credentials

Runtime data lives in Studio's Application Support area. Model provider credentials are atomically saved as an owner-only configuration file inside the existing `platform-data` disk. The native UI can determine whether a provider is configured but never reads a saved secret back for display.

Cache cleanup preserves persistent volumes, backups, and service disks. If Studio cannot determine the last-known-good image set, it retains image references rather than deleting uncertain data.

Saved [diagnostic logs](operations.md#logs-and-troubleshooting) remain inside the
sandbox, with owner-only permissions and a 4 MiB retention limit. Service output
is not guaranteed to be secret-free; review it before sharing. Logs are not
uploaded automatically, and diagnostics require no additional entitlements.

## Embedded web content

Studio adds an App Transport Security HTTP exception only for `localhost` and
its subdomains through [per-domain exceptions](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains).
This accommodates manifest-defined local endpoint names and space/portal apexes,
which do not use TLS. Remote HTTP remains blocked. Transport permission does not
make every local name a trusted application origin: manifest host, apex and port
checks are enforced separately. Packaging verifies the complete policy; no
sandbox entitlements are added for this exception.

The resolved manifest defines Studio's trusted local origins. New-window requests between those origins open in another Studio window; external destinations open in the default browser. Port checks and dot-delimited apex matching prevent unrelated local applications or similarly named domains from becoming internal. WebKit still controls user-activation and page security rules.

Microphone use is automatically accepted at the page layer only for the trusted local origin. macOS continues to present and enforce Studio's system privacy permission.

## Updates

Public releases use Developer ID signing, Apple notarization, a stapled application bundle, and Ed25519 verification of update archives. Studio waits for a graceful VM shutdown before an update replaces the running application. A shutdown failure blocks installation rather than risking runtime data.
