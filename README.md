<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/icon-dark.svg">
  <img alt="ChatBotKit Studio" src="docs/assets/icon-light.svg" width="60">
</picture>

<br/>

<h1>AI Studio in a Box</h1>

<p>
  <strong>A complete ChatBotKit workspace running privately<br>
  inside one native macOS app.</strong>
</p>

<p>
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-%E2%89%A526-0a0a0a?style=flat-square&logo=apple&logoColor=white">
  <img alt="Apple silicon" src="https://img.shields.io/badge/Apple-silicon-0a0a0a?style=flat-square&logo=apple&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-0a0a0a?style=flat-square&logo=swift&logoColor=white">
  <img alt="Private runtime" src="https://img.shields.io/badge/runtime-private-0a0a0a?style=flat-square&logo=apple&logoColor=white">
</p>

<p>
  <a href="https://github.com/chatbotkit/studio/releases/latest"><strong>Download Studio</strong></a> ·
  <a href="https://github.com/chatbotkit/platform#run-it"><strong>Deploy Platform</strong></a> ·
  <a href="./docs/getting-started.md"><strong>Get started</strong></a> ·
  <a href="./docs/README.md"><strong>Documentation</strong></a> ·
  <a href="./docs/architecture.md"><strong>Architecture</strong></a>
</p>

</div>

<p align="center">
  <img width="2064" alt="ChatBotKit Studio" src="https://github.com/user-attachments/assets/f9350253-1c01-42d2-826b-a2552542518c" />
</p>

Studio brings the breadth of the [ChatBotKit Platform](https://github.com/chatbotkit/platform) to your Mac. Build agents, manage knowledge, connect model providers, and test complete experiences while the platform runs in a private Linux VM owned by the app.

No Docker setup. No separate container command. Open Studio and start building.

## Build locally. Run the full platform on your servers.

Studio is an easy way to explore and build with ChatBotKit on your Mac. The bigger benefit is the **complete server-side Platform**: run AI behind your products and internal systems, serve your team, and keep control of your infrastructure and data.

For shared deployments, install [ChatBotKit Platform](https://github.com/chatbotkit/platform). It brings together the agent runtime, model gateway, knowledge, integrations, APIs, and access controls in a stack you operate.

**[Install the complete Platform →](https://github.com/chatbotkit/platform#run-it)** · [Server deployment guide](https://github.com/chatbotkit/platform/blob/main/docs/deployment.md)

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
- [Changelog](CHANGELOG.md)

## License

Studio is licensed under the [Apache License, Version 2.0](LICENSE). See
[NOTICE](NOTICE) for attribution. Third-party components retain their own licenses.
