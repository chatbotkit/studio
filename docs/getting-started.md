# Getting started

## Requirements

- An Apple silicon Mac.
- macOS 26 or later.
- An internet connection for the first image download and model access.
- Enough free disk space for platform images, service disks, and persistent data.

## Install

1. Download the latest Studio ZIP from [GitHub Releases](https://github.com/chatbotkit/studio/releases/latest).
2. Unzip it and move **Studio.app** to the Applications folder.
3. Open Studio.

Studio starts its own private runtime. Docker, the Apple `container` command, and a separately installed container service are not required.

## First launch

The launch screen shows each service while Studio downloads and prepares the platform. Once the stack is ready, the workspace fades in. Later launches reuse the downloaded images and private data.

If startup fails, open **Stack → Show Live Logs** for the complete service output. **Stack → Restart Stack** retries startup without reinstalling the app.

## Configure a model provider

1. Open **Studio → Settings**.
2. Select **Models**.
3. Choose a provider and enter its credentials.
4. Save the provider.

Studio shows which providers are configured without displaying saved secrets again. The running platform reloads its model configuration after a change.

## Next steps

Create a bot or blueprint, add knowledge through datasets and files, and use the Developer Console to test the result. See [Using Studio](operations.md) for native controls and troubleshooting.
