# Endpoint manifest addressing — 2026-09-10

Studio now resolves the version 1 `x-cbk` manifest alongside the service
environments. Published addresses are no longer inferred from fixed native
hostnames or ports. The adapter remains specific to the Studio stack; it does
not interpret general Compose `ports:`, inherit the Mac's environment, or read
local `.env` files.

## Artifact and independent reference

Work began against the published `platform-studio:next` artifact while main was
still rolling out. The subsequently published `platform-studio:v0.3.0` and
`:latest` contain the identical Compose layer:

`sha256:54fa129a3d85c9f38ff6111302682f3af7a8166e2bf7ec00a818528cf99846b1`

The checked-in `Tests/StudioConfigurationTests/Fixtures/studio-compose.yml`
matches that layer byte for byte. It contains only public artifact defaults,
not local credentials. The main image-map layer differs from next, as expected;
the runtime continues to fetch and verify the selected artifact's digest map.

Standalone Docker Compose v5.0.2 generated both JSON references without a
container daemon or any running containers:

```sh
env -i PATH=/usr/bin:/bin /usr/local/bin/docker-compose \
  --env-file /dev/null -f /private/tmp/studio-manifest-compose.yml \
  config --format json

env -i PATH=/usr/bin:/bin \
  PLATFORM_PORT=31000 RELAY_PORT=31001 STORAGE_PORT=31900 \
  SITE_URL=http://127.0.0.1:31000 NEXTAUTH_URL=http://127.0.0.1:31000 \
  RELAY_URL=http://127.0.0.1:31001 STORAGE_URL=http://127.0.0.1:31900 \
  /usr/local/bin/docker-compose --env-file /dev/null \
  -f /private/tmp/studio-manifest-compose.yml config --format json
```

The checked-in reference JSON retains `services.*.environment` as
`environments`, plus `x-cbk` as `manifest`. Tests compare every service
environment and the entire manifest in both default and native-topology modes.

## Configuration and security checks

- All 159 regression tests passed with `swift test -c release`, including the
  independent Compose references and native WebKit/window tests.
- Missing, malformed, incomplete or unsupported-version manifests fail closed.
- Endpoint URLs require HTTP, explicit matching ports, and valid loopback or
  `.localhost` hosts. Credentials, non-local hosts, ambiguous host spellings,
  invalid ports and malformed apexes are rejected without echoing URL values.
- Actual allocated ports must match all endpoint and apex publications. Site
  fallback is bounded to +9 and excludes both auxiliary ports. A real listener
  test reserves a port and verifies fallback; occupied auxiliary ports fail.
- The main stack defaults to published 31000/31001/31900, but container ports
  remain platform 3000 and relay 3001. Garage binds the chosen storage port on
  both sides; its admin port remains 3903. Tests reject inconsistent Garage
  bindings and verify `garage-init` follows the storage port.
- Apps/Labs destinations, VM hosts entries and native-window origin membership
  use the resolved manifest. Membership includes the port and dot-delimited
  apex boundary. A differently named or differently ported local app is not
  trusted. Microphone capture still requires the exact loaded origin and macOS
  permission; another trusted endpoint's iframe does not gain capture access.
- The signed WebKit transport probe first confirms the baseline ATS rejection,
  then loads Apps, Labs, a custom app hostname and a nested space-apex hostname
  using the packaged localhost/subdomain exception. Remote HTTP remains blocked
  with ATS error -1022. No App Sandbox entitlement or helper boundary changed.

## Reproduction

Run `swift test -c release`, then `scripts/build-app.sh` and
`scripts/test-web-transport.sh /path/to/Studio.app`. The build verifies strict
signatures, hardened runtime, linked libraries and the existing six-key
sandbox policy, including the two approved Sparkle Mach lookup names.

Full-stack validation must use a separately signed bundle identity and its own
sandbox data, never the installed application's data. The reference remains
`platform-studio:latest`; no next-only hook or host environment override is
included in the final application.

The existing `runtime-smoke-test.sh` checks a disposable Alpine VM and artifact
loading; it does **not** prove full platform startup or Apps/Labs navigation.
No release or tag is created by this work.

## Full-stack run

The isolated development bundle was built with:

```sh
STUDIO_DIST_ROOT="$PWD/.release/endpoint-manifest-validation" bash scripts/build-app.sh
```

Only that generated bundle was re-identified as
`ai.cbk.studio.endpoint-validation`, named “Studio Endpoint Validation”, signed
again with `Packaging/Studio.entitlements`, and checked with
`scripts/verify-app.sh` before launching. Updates remained disabled. Its runtime
and logs live in that identity's new sandbox, not the installed Studio sandbox.

The run resolved `platform-studio:latest` to:

`sha256:7fc1907f49db084bccba7c85c9fe593632031453511398959176c0c2e94b1ce2`

`lsof -nP -a -p <validation-pid> -iTCP -sTCP:LISTEN` showed exactly three
listeners: `127.0.0.1:31000`, `127.0.0.1:31001`, and `127.0.0.1:31900`.
There was no listener on 3000 or a wildcard interface. The UI showed measured
download bytes and percentage during the fresh image downloads.

All six services completed or became healthy. The actual embedded WebKit window
reached `127.0.0.1:31000/signin?callbackUrl=%2Foverview` and displayed the trusted
“Sign in as” email form. No identity was entered and no account was created.

Using **Stack → Open Apps** opened an Apps catalogue at
`cbk-apps.localhost:31000/`; **Stack → Open Labs** opened the Labs catalogue at
`cbk-labs.localhost:31000/`. These were observed in the actual Studio windows and
their accessibility URLs, not inferred from generated URL strings.

Read-only HTTP checks through the published listeners returned 200 for site
`/signin`, 404 for the relay root, and 403 for the unauthenticated storage root.
The latter two prove reachability, not authenticated object operations or a
complete realtime session. Wildcard DNS, account sign-in, model requests and
credential changes were not exercised. `/Applications/Studio.app` and its data
were not modified.

After removing the temporary next-only validation hook, the final source again
passed all 159 tests. The final verified development bundle was produced with:

```sh
STUDIO_DIST_ROOT="$PWD/.release/endpoint-manifest-final" bash scripts/build-app.sh
```

Its packaged policy passed `scripts/test-web-transport.sh` (evidence directory
`studio-web-transport.RFk2Hd` under the macOS temporary directory). A copy was
re-identified into the same isolated validation sandbox, restarted from the
cached images, and again reached the sign-in screen with all services healthy.
The test app was shut down cleanly after validation.
Its 5.6 GB of disposable image downloads and empty test volumes were removed;
diagnostic logs and generated development builds were retained. The test data
can be recreated by launching the isolated bundle again.
