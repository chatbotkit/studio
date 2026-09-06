# Changelog

## Unreleased

## 0.13.0

- Show native unsaved-change and JavaScript confirmation sheets for embedded page navigation/reloads. Default to staying, suspend page-load timeouts while a prompt is open, and cancel pending replies safely during teardown.
- Apply each service's verified Compose environment, including YAML anchors and empty/unset semantics, so Studio trusted sign-in and current storage defaults match the distribution. Add loopback-only relay/storage forwarding and remove the stale Community loading label.
- Switch the default OCI stack to `oci://ghcr.io/chatbotkit/platform-studio:latest`, share that reference with the isolated smoke test, and recognize Studio artifact layers while retaining Community compatibility.

## 0.12.0

- Add Sparkle app updates with signed GitHub feeds and archives, Check for Updates, update settings, and confirmed VM shutdown before installation. Development builds keep updates disabled; the first updater-enabled release requires manual installation.
- Package and verify Sparkle's signed installer components with the explicitly approved, narrowly scoped sandbox communication exception. Configure a dedicated Studio signing key and CI feed publication.
- Verify OCI manifest and configuration bytes before decoding; fetch each object once and reject oversized or ambiguous artifacts.
- Make page loading independent of brightness, cancel superseded readiness work, and provide page-only retry after navigation failures, timeouts, or WebKit process termination.
- Add Manage Storage with a confirmation-based obsolete-cache cleanup that preserves persistent volumes, backups, and service disks. Revalidate cleanup previews and exclude concurrent runtime owners.
- Check free disk space before image/disk creation and atomically promote completed replacement disks; failed or cancelled preparation retains the previous disk.
- Add a separate-identity, disposable-VM smoke test for the public OCI artifact, graceful termination, persistent-volume writes, and VM teardown.
- Serialize startup, restart, and shutdown; reject duplicate starts, await cancelled startup, and ignore stale callbacks. Keep Studio open if VM teardown fails so the user can retry.
- Gracefully terminate services in dependency order with bounded exit waits and force-stop fallback; clean up failed startup resources and timed-out health probes.
- Preserve split Unicode and malformed-byte diagnostics in bounded log streams, and bound startup-error headlines.
- Restrict configuration parsing to the correct sections; reject duplicate image/service entries and malformed SHA-256 pins, and support CRLF configuration files.
- Expand isolated regression coverage for lifecycle, shutdown, configuration, log streaming, console selection, and listener completion. Convert all original known-issue reproductions to normal regression tests.
- Open HTTP/HTTPS links targeting a new window (`target="_blank"` and direct `window.open(url)`) in the default browser while keeping the embedded page in Studio. This does not forward POST forms, local files, or custom app URL schemes.

## 0.11.0

- Initial signed and notarized Studio release.
