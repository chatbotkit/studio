<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/icon-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/assets/icon-light.svg">
    <img alt="ChatBotKit Studio" src="docs/assets/icon-light.svg" width="96" height="96">
  </picture>

  <h1>AI Studio in a Box</h1>

  <strong>A complete ChatBotKit workspace running privately<br>inside one native macOS app.</strong>

  <br><br>

  ![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black)
  ![Apple silicon](https://img.shields.io/badge/Apple-silicon-black)
  ![Native Swift](https://img.shields.io/badge/native-Swift-black)
  ![Private runtime](https://img.shields.io/badge/runtime-private-black)

  <br>

  [Download Studio](https://github.com/chatbotkit/studio/releases/latest) ·
  [Get started](docs/getting-started.md) ·
  [Documentation](docs/README.md) ·
  [Architecture](docs/architecture.md)
</div>

<!--
The approved product screenshot will live at docs/assets/studio-screenshot.png.
Uncomment this block when the image is added.

<p align="center">
  <img width="2064" alt="ChatBotKit Studio" src="docs/assets/studio-screenshot.png">
</p>
-->

Studio brings the breadth of the ChatBotKit AI platform to your Mac. Build agents, manage knowledge, connect model providers, and test complete experiences while the platform runs in a private Linux VM owned by the app.

No Docker setup. No separate container command. Open Studio and start building.

## One app. A complete AI workspace.

- Build bots, datasets, skillsets, portals, and integrations.
- Configure supported model providers from native Settings.
- Keep credentials and application data in Studio's private runtime.
- Troubleshoot with native logs, stack details, and Web Inspector.
- Open multiple Studio windows backed by one shared runtime.
- Receive signed, notarized application updates.

## Install Studio

1. [Download the latest release](https://github.com/chatbotkit/studio/releases/latest).
2. Move **Studio.app** to Applications and open it.
3. Add at least one model provider in **Studio → Settings → Models**.

Studio requires an Apple silicon Mac running macOS 26 or later. The first launch downloads the platform images, so it also needs an internet connection and sufficient free disk space.

## Private by design

Studio does not control an existing Docker or Apple Container installation. It embeds its own verified runtime, starts the platform in an app-private VM, and exposes the workspace only through loopback addresses on your Mac. The native host remains sandboxed and uses a deliberately narrow permission set.

## Documentation

- [Getting started](docs/getting-started.md)
- [Using Studio](docs/operations.md)
- [Architecture and container runtime](docs/architecture.md)
- [Security and privacy](docs/security.md)
- [Development and testing](docs/development.md)
- [Release setup](docs/releases.md)
