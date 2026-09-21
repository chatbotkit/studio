---
name: helper-visibility
description: Dock and app-switcher policy for Studio's helpers and probes. Use when creating or changing a helper app bundle, a probe or other standalone development or test fixture, an Info.plist with LSUIElement or LSBackgroundOnly, or any NSApplication activation policy.
---

# Helper visibility

Helpers and standalone development/test fixtures must stay out of the Dock and
app switcher by default.

- Set `LSUIElement` for helper and probe app bundles, as
  `scripts/test-web-transport.sh` does for its probes.
- Use AppKit's `.accessory` activation policy when they need windows.
- Use `LSBackgroundOnly` for background-only executable metadata.
- Do not promote helpers to `.regular`.

Studio itself retains its Dock entry.

## Verify

Check a running app without screenshots:

```sh
lsappinfo list | grep -A4 '"<App Name>" ASN'
```

`type="UIElement"` is hidden; `type="Foreground"` is in the Dock. Launch Services
resets a non-`LSUIElement` app to `.regular` on every open, reopen or URL request,
so check again after triggering one with `open -g`.
