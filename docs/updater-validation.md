# Updater integration validation — 6 September 2026

Implements SuperBot's Sparkle-based update delivery for Studio without publishing a release or changing `VERSION`.

## Verified locally

- Pinned Sparkle 2.9.4; all existing dependency pins preserved.
- 91 regression tests pass. The update tests cover waiting for busy operations, shutdown-before-install ordering, failed teardown and retry, superseded/aborted handlers, late shutdown completion after cancellation, and explicitly restarting after an aborted update. The suite also passed three consecutive repeat runs.
- Generated a local signed appcast and archive with Studio's dedicated key. Verified both signatures and rejected substituted archive bytes. Private/public key validation passed and invalid key input failed closed. No test archive/feed was uploaded.
- Configured the new `SPARKLE_PRIVATE_KEY` GitHub Actions secret for `chatbotkit/studio`. Its private key remains in Keychain under `ai.cbk.studio.updates`; temporary exports were removed. SuperBot's key was not reused.
- Built and strictly verified a separate development app and all embedded updater code. Its executable loads Sparkle only from the signed bundle; mutable build-cache search paths are removed.
- Launched an Apple Development-signed diagnostic with a separate identity. Sparkle's actual updater configuration validated without a feed request or installation. The same process verified the public OCI artifact, booted a disposable VM, tested SIGTERM and a persisted shared-volume marker, tore down the VM, removed its temporary runtime, and exited with status 0.
- The diagnostic identity also forces diagnostic mode when opened without arguments; it cannot start the normal community stack through Finder or an inspector.

## Reviewed boundary

The host keeps App Sandbox, network client, network server, and virtualization. The only added entitlement is the approved Mach lookup exception for exactly `ai.cbk.private-oci-stack-spks` and `ai.cbk.private-oci-stack-spki`. Sparkle Installer.xpc, Autoupdate, and Updater.app are explicitly approved unsandboxed installer components. They and the framework are signed inside-out with the host's team and hardened runtime, with no additional entitlements. The unused Downloader XPC service is removed.

The first ad-hoc launch test exposed hardened-runtime library validation rejecting Sparkle without a real team identity. Local builds now prefer Apple Development/Developer ID signing; no `disable-library-validation` entitlement was added. Certificate-free CI artifacts are labelled for packaging inspection only. Release CI signs with Developer ID.

## Release qualification still required

No public release, tag, push, notarization submission, or production app replacement was performed. Version 0.11.0 has no updater and requires a one-time manual upgrade to the first updater-enabled release. Before distribution, test a signed old-to-new installation and relaunch, including stack-busy and shutdown-failure cases, existing private data, and Gatekeeper on a clean Mac. Local signatures, mocked lifecycle tests, and configuration startup do not establish that production installation test.

The updater cannot detect arbitrary unsaved forms in the embedded web application; save work before installation. Automatic checks default to daily, automatic download/install defaults off, and local development builds disable update checking. The live Studio app and its persistent volumes were not changed.
