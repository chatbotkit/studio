# Contributing

Contributions to Studio are welcome, including bug fixes, documentation improvements, and features.

## Report an issue

Open an [issue](https://github.com/chatbotkit/studio/issues) with your Studio and macOS versions, steps to reproduce the problem, and the expected and actual behavior. Remove credentials and personal data from any logs or screenshots.

For substantial changes, open an issue first to discuss the approach.

## Make a change

1. Fork the repository and create a branch for your change.
2. Follow the [development guide](docs/development.md) for requirements, build instructions, and tests.
3. Keep the change focused and run the checks relevant to it. For code changes, run `swift test -c release`.
4. Add a concise note under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) for user-visible changes.
5. Open a pull request explaining the problem, your change, and how you verified it. Include screenshots for interface changes when useful.

See the [architecture guide](docs/architecture.md) for the source layout and runtime design.
