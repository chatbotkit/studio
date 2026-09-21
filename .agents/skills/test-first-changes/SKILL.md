---
name: test-first-changes
description: Test-first procedure for every behaviour change in Studio. Use before fixing a bug, changing how code behaves, or acting on a diagnosis made by reading the code; covers the failing test, the fix, the two runs to report, and the CI-safety constraints on tests.
---

# Behaviour changes are test-first

Do not change behaviour on the strength of reading the code.

1. Write a test that exercises the specific code and fails because of the problem.
2. Run it and see it fail.
3. Make the change.
4. Run the same test and see it pass.
5. Report both runs.

A suspected cause that no test can reproduce is still a hypothesis; say so instead
of changing code.

## Constraints on tests

Tests must also pass in CI, so they must not depend on:

- the network or an OCI registry;
- the production kernel, a VM, the image store or persistent volumes. Supply an
  in-memory `StackRuntime`, as `Tests/StudioTests/LifecycleTests.swift` does;
- the developer's own preferences or app data. Use an isolated `UserDefaults`
  suite and temporary directories;
- timing. Wait for a condition instead of sleeping for a fixed interval.

Run one suite while iterating, then everything before reporting:

```sh
swift test --filter LifecycleTests
swift test
```
