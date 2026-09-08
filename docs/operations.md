# Using Studio

## Windows and links

Studio can open multiple native windows over one running platform. **File → New Window** or Command-N opens the default workspace in another window; it does not launch another VM.

Links targeting a new window remain inside Studio when they belong to the local platform origin. External links open in the default browser.

**Stack → Open Labs** and **Stack → Open Apps** open their respective workspaces
in separate Studio windows, sharing the existing stack. These shortcuts become
available once the stack is ready and use its active port (normally 3000).

## Model providers

**Studio → Settings → Models** configures platform-wide credentials for OpenAI, OpenRouter, Vercel AI Gateway, Google AI, Amazon Bedrock, Cloudflare Workers AI, Perplexity, Mistral, Groq, and DeepSeek.

Saved secrets are never read back into the native interface. Removing a configured provider requires confirmation.

## Storage

**Studio → Settings → Storage** shows free disk space and the space allocated to caches, service disks, and persistent data.

Cache cleanup previews what can be reclaimed, asks for confirmation, safely stops the stack, and preserves persistent volumes, backups, and service disks. Shared APFS blocks can make size estimates overlap. Studio also reserves free-space headroom before large image or disk operations, though another application can still consume space while an operation is running.

## Logs and troubleshooting

The Stack menu provides:

- Live, selectable service logs.
- Stack details and health.
- Page reload without restarting the containers.
- Web Inspector for the embedded page.
- Full stack restart when required.

Page failures and WebKit process termination offer a page-only reload first.

Studio also saves the captured service output, runtime events, and app start/shutdown
markers inside its private sandbox, at:

```text
~/Library/Containers/ai.cbk.private-oci-stack/Data/Library/Logs/Studio/
```

Use Finder's **Go → Go to Folder** to open that location. `current.jsonl` is the
latest log; `previous-1.jsonl` through `previous-3.jsonl` contain older output.
Each file is limited to 1 MiB (4 MiB total), is readable only by your macOS user,
and survives app restarts. Records include a timestamp, process ID, source, and
message. Logging stops for the current launch if the disk is full or inaccessible;
this does not stop the workspace. Simultaneous app instances may skip records
while another instance rotates/writes the shared files.

Logs contain service output, which may include personal content or credentials
printed by the platform. Inspect and redact them before sharing. Studio does not
add HTTP request bodies, cookies, or provider credential values to diagnostics.
**Clear Captured Logs** clears the live view only; to remove saved diagnostics,
quit Studio and delete the files in this log folder. Do not delete the Runtime
folder, which contains your workspace data.

These are diagnostic logs, not a full crash recorder: output still pending in a
service or the app's event queue may be lost on abrupt termination. macOS Console
can provide complementary process-exit and WebKit diagnostics.

## Unsaved changes

Pages that register a browser `beforeunload` handler receive a native **Stay on Page** / **Leave Page** confirmation for navigation and reload. Studio does not guess whether arbitrary forms are dirty, and in-page routers must provide their own navigation guard. Forced termination, crashes, stack restart, and native app quit cannot always show this warning.

## Microphone access

Local platform pages can request microphone use. Studio grants the page-level request for its trusted local origin, while macOS retains the system-level privacy decision for Studio itself.

## Updates

**Studio → Check for Updates** and **Settings → Update** use signed application updates. Automatic checks default to daily; automatic installation is off by default. Save work before installing. Studio waits for active stack operations and confirms that the VM has stopped before replacing and relaunching the app.

Development builds cannot update themselves. Application updates do not delete the private platform data or independently change the OCI stack tag.
