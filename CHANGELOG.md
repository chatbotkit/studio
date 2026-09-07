# Changelog

All notable changes to Studio are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- Group browser commands together in the Stack menu and move Clear Captured Logs below stack details, separated by a divider.
- Open the Studio GitHub repository in the default browser from Studio Help.
- Remove the redundant Manage Storage command from the Stack menu; storage management remains in Settings.
- Introduce a download-focused README with an adaptive ChatBotKit icon, product screenshot, and dedicated guides under `docs/`.
- Use curated changelog entries for release descriptions, with shared validation in local release scripts and CI and ongoing release-note guidance in `AGENTS.md`.

### Fixed

- Keep the application-menu update command responsive as update availability changes, using native placement below Settings.
- Keep the startup screen dismissed after the workspace first appears, including during quit, reload, and stack restart.

## [0.14.0] - 2026-09-07

### Added

- Native model-provider settings with configuration status and support for OpenAI, OpenRouter, Vercel AI Gateway, Google AI, Amazon Bedrock, Cloudflare Workers AI, Perplexity, Mistral, Groq, and DeepSeek.
- Multiple Studio windows sharing the running platform and browser session, with same-origin new-window links and Command-N to open the home workspace.
- Microphone access for voice features through the macOS privacy prompt.

### Changed

- Organize Settings into Models, Storage, and Updates tabs with icons, a fixed width, and automatic height adjustment.
- Move storage management into Settings, with direct access from the Stack menu and simpler cleanup controls.
- Simplify the launch screen and fade in the workspace after its first successful page load.
- Use app-native confirmation messages without internal loopback addresses; trusted local microphone requests no longer need a second page-level prompt.
- Use the standard macOS About panel and move Check for Updates below Settings.

### Fixed

- Restore reliable interaction with controls at the bottom edge of embedded pages, including the Developer toggle.
- Make model-provider configuration easier to scan and edit, and dismiss save notices after a short interval.

### Security

- Save provider credentials atomically inside the private platform data disk without reading saved secrets back into the native UI; confirm credential removal.
- Restrict page-level microphone grants to the trusted local platform origin.

## [0.13.0] - 2026-09-06

### Added

- Native unsaved-change and JavaScript confirmations for page navigation and reload, defaulting to staying on the page.
- Local forwarding for the realtime relay and storage endpoint.

### Changed

- Load the Studio distribution from `oci://ghcr.io/chatbotkit/platform-studio:latest`, while retaining compatibility with Community artifacts.
- Read service environments from the verified Compose artifact, including YAML anchors, variable expansion, and empty or unset values.

### Fixed

- Honor Studio trusted local sign-in and distribution storage settings instead of stale hardcoded defaults.
- Suspend page-load timeouts during confirmations and safely cancel pending replies when closing the web view.

## [0.12.0] - 2026-09-06

### Added

- Signed in-app updates through Sparkle, with daily checks and optional automatic installation. Development builds keep self-updates disabled.
- Cache inspection and confirmed cleanup that preserves persistent volumes, backups, and service disks.
- External browser handling for HTTP/HTTPS links opened with a new-window target.
- Page-only retry after navigation failures, timeouts, or WebKit process termination.
- A disposable VM smoke test and broader regression coverage for runtime lifecycle, configuration, storage, logs, and native controls.

### Changed

- Wait for active operations and confirmed VM shutdown before installing an app update; keep the app open when shutdown fails.
- Stop services in dependency order with bounded waits and a force-stop fallback.

### Fixed

- Serialize startup, restart, and shutdown; reject duplicate starts and stale callbacks, and clean up failed startup resources and health probes.
- Reserve disk headroom before image and disk creation, stage replacements atomically, and preserve existing disks when preparation fails or is cancelled.
- Recheck cache cleanup previews and prevent concurrent processes from owning the same runtime data.
- Detect page readiness independently of brightness and cancel superseded loading work.
- Preserve split Unicode and malformed-byte diagnostics in bounded logs, and keep startup-error summaries readable.
- Reject duplicate configuration entries and malformed image pins while supporting CRLF files.

### Security

- Verify OCI manifest and configuration sizes and hashes before decoding, and reject ambiguous or oversized artifacts.
- Verify signed update feeds and archives before extraction, using a dedicated Studio update-signing key.
- Sign bundled updater components and limit their sandbox communication exception to Studio's two installer service names.

## [0.11.0] - 2026-09-05

### Added

- The first signed and notarized Studio release for Apple silicon Macs, with an embedded private container runtime and ChatBotKit workspace in WebKit.
- OCI Compose artifact loading, persistent application data, service startup progress, streaming logs, stack details, and Web Inspector.
- Adaptive monochrome ChatBotKit branding and native appearance support.
- Versioned release packaging and macOS build/test CI.

### Fixed

- Resolve Compose configuration values needed for Garage storage startup.

### Security

- Sandbox the native application and keep the platform runtime private to Studio, with local port forwarding and a bundled Linux kernel.

[Unreleased]: https://github.com/chatbotkit/studio/compare/v0.14.0...HEAD
[0.14.0]: https://github.com/chatbotkit/studio/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/chatbotkit/studio/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/chatbotkit/studio/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/chatbotkit/studio/releases/tag/v0.11.0
