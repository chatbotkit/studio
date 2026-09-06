# Embedded-page confirmation support — 2026-09-06

Studio's UI delegate previously handled only new-window browser handoff. It now
also presents native confirmation sheets for JavaScript `confirm()` and
WebKit's `beforeunload` request. It does not inject or replace page handlers.

## Behavior and verification

- All 109 regression tests pass. Real WKWebView fixtures verify JavaScript
  Cancel/OK, canceling navigation, canceling reload, and approving navigation
  away from a document with a registered `beforeunload` handler.
- A real AppKit sheet test verifies presentation and cancellation. Unit tests
  verify one reply per request, overlap rejection, stale callbacks, teardown,
  safe behavior without a visible parent, origin display without URL credentials,
  and safe button defaults. Escape is scoped to the presented sheet and returns
  Stay/Cancel; the temporary event monitor is removed when the sheet finishes.
- Before-unload text is a fixed Studio warning, not arbitrary page-provided
  instructions. JavaScript confirmation text is attributed to its frame's origin
  and length-limited. Return defaults to Stay/Cancel; Leave/OK is explicit.
- Page-load deadlines pause while a confirmation is open. A finished document
  cancels its deadline before visual settling, avoiding a race found by the
  sheet test. Declined navigation does not turn an existing page into an error.
- Page-process termination and view dismantling cancel outstanding requests.
  Existing external-window browser routing remains covered by regression tests.

## Compatibility and boundaries

The public [JavaScript confirmation delegate](https://developer.apple.com/documentation/webkit/wkuidelegate/webview(_:runjavascriptconfirmpanelwithmessage:initiatedbyframe:completionhandler:))
handles in-page routers that use `confirm()`. The before-unload callback remains
an isolated Objective-C selector from
[WebKit's private UI delegate](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKUIDelegatePrivate.h):
`_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:`.
WebKit detects this selector itself. Its normal user-activation policy is not
disabled. Compatibility depends on that private callback remaining available;
the real-WebKit regression test checks it on the current SDK/runtime.

Pages must register their own unsaved-state guard. History-only SPA navigation
does not itself trigger `beforeunload`; the router must ask before leaving.
Native Quit, Restart Stack, forced termination, and crashes are not browser
navigations and are not covered by this change. No blanket loss-prevention claim.

No new dependencies or permissions. The app retains these entitlements:
`com.apple.security.app-sandbox`, `com.apple.security.network.client`,
`com.apple.security.network.server`, `com.apple.security.virtualization`, and
`com.apple.security.temporary-exception.mach-lookup.global-name` containing only
`ai.cbk.private-oci-stack-spks` and `ai.cbk.private-oci-stack-spki`.
The already-approved Sparkle installer helpers remain signed outside the host
sandbox; this change introduces no helper or sandbox escape. The current user
session is not restarted automatically, because it may contain unsaved work.
