# Upstream runtime configuration — 2026-09-10

## Regression

Studio 0.15.0 retained a preflight requirement for internal platform/relay ports
3000/3001. At 13:02:58 UTC, the moving `platform-studio:latest` artifact changed
those listeners to use the same resolved ports as the public endpoints. The
application rejected the new configuration before starting its VM.

The failing artifact's root digest is:

`sha256:a7645252e7ce1be45037ed806f24552523d5a0d4631aa49afbc9f37060820902`

Its Compose layer, now the byte-exact checked-in `studio-compose.yml` fixture:

`sha256:f92c31aff46e4db30bc2ec0752d6c40834b0a7a77361854a4d43a366103f0514`

## Source of truth

- Published addresses and ports: the artifact's `x-cbk` endpoint manifest.
- Platform and relay listeners: resolved service `PORT` and `RELAY_PORT`.
- Storage and admin listeners: resolved inline Garage configuration.
- Readiness commands: service `healthcheck.test`, executed inside each container
  with its inherited environment. Compose `$$` remains a literal `$` for the
  container shell; the Mac's environment is never imported.

There are no compiled-in service port values or a historical storage-port
blacklist. Numeric validity, actual listener collisions, endpoint consistency,
local-only host binding, and bounded probe execution remain enforced. This is
still a Studio-specific adapter, not a general Compose engine: service layout,
mount wiring, and native VM bootstrap remain owned by the desktop runtime.

## Regression coverage

The checked-in default and native-topology JSON references were independently
compared against standalone Docker Compose v5.0.2 using an empty environment,
`--env-file /dev/null`, and the exact public artifact. Both match every service
environment and the full endpoint manifest.

Tests cover the currently published listeners, arbitrary changed ports,
site-port fallback, previously published fixed internal ports, missing and
invalid listeners, actual collisions, storage ports formerly blacklisted, and
upstream health-check argument/expansion semantics. Unsupported or disabled
required health checks are rejected instead of replaced with native defaults.

`swift test -c release` passed all 169 tests. Release-note extraction checks
also passed. `scripts/build-app.sh` produced a signed development bundle and
passed strict signature, hardened-runtime, linkage, ATS, and updater checks.

The sandbox policy is unchanged: App Sandbox, virtualization, outbound and
loopback-server networking, microphone input, and the existing two scoped
Sparkle Mach lookup names. Sparkle's previously approved installer helpers
remain signed outside the host sandbox; this change adds no helper or access.

## Fresh full-stack run

The signed development build at `.release/upstream-runtime-validation/Studio.app`
was re-identified as `ai.cbk.studio.upstream-validation` and verified again before
launch. It used a new, empty sandbox and downloaded fresh images from the exact
root digest above; the installed application and its data were not used.

All six stack services completed or became healthy using the upstream probes.
The actual embedded WebKit views loaded:

- Main: `127.0.0.1:31000/signin?callbackUrl=%2Foverview`, with the trusted sign-in form.
- Apps menu: `cbk-apps.localhost:31000/`, with the Apps catalogue.
- Labs menu: `cbk-labs.localhost:31000/`, with the Labs catalogue.

The process listened only on `127.0.0.1:31000`, `127.0.0.1:31001`, and
`127.0.0.1:31900`. Read-only requests returned site `/signin` 200, relay `/` 404,
and storage `/` 403. These auxiliary responses establish reachability, not an
authenticated storage operation or realtime session. No account or model
credentials were entered. The test app was quit after verification.

After confirming process exit, its 5.6 GB of disposable runtime images and
empty test volumes were removed. Diagnostic logs remain in the isolated
identity's `Data/Library/Logs/Studio/current.jsonl`; the generated test bundle
is retained. Launching it again recreates its runtime. No release was published.
