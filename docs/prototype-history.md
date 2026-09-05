# Private OCI Stack v11

A native SwiftUI macOS app that resolves the Docker Compose OCI artifact at
`oci://ghcr.io/chatbotkit/platform-community:latest`, verifies and reads its
Compose and digest-lock layers, then runs the six-service ChatBotKit Community
stack in one app-private Apple Containerization pod.

The app bundles its Linux kernel and never invokes or discovers the installed
`container` command. Its image store, six root filesystems, four persistent
volumes, boot log, and downloaded OCI documents live in its own App Sandbox
container. A small in-process TCP forwarder publishes the platform at
`http://localhost:3000`; if that port is already occupied, it selects the next
available local port and reports it in Stack Details.

The main window has no operational chrome: it displays centered startup
progress and reveals the live platform in an embedded WebKit view only after
the application is healthy and visibly rendered. Restart and diagnostic
details live in the native **Stack** menu.

Version 8 uses a single-instance main window and disables macOS automatic
window tabbing, so the title bar never turns into a browser-style tab strip.
The Live Logs and Stack Details instruments continue to use the one shared
runtime model; opening or restoring them cannot start a second pod. Native
surfaces, the console, and the WebKit appearance now follow the Mac's current
Light or Dark appearance rather than forcing a black presentation.

The embedded page opts into WebKit inspection. Choose **Stack → Show Web
Inspector** or press Command-Option-I to open the inspector, use
Command-Option-R to reload the embedded page, or right-click the page and
choose **Inspect Element**. The menu opener uses a guarded WebKit runtime
selector because WebKit's public `isInspectable` API enables inspection but
does not provide a public programmatic “show inspector” method.

Version 9 restores native window dragging while retaining the chromeless main
surface. The embedded WebKit view reserves the top 30 points to the right of
the traffic-light controls and converts mouse-down events there into the
standard AppKit window drag operation. A matching drag surface is installed
directly in the native window frame above WebKit, avoiding SwiftUI safe-area
and hit-testing ambiguity. The remainder of the page continues to receive
normal WebKit interaction.

Version 11 replaces the overlaid material with a true Safari-style layout.
An opaque 38-point title region contains the traffic-light area while the
embedded page starts below it and never draws underneath. There is no blur,
gradient, or separator. Once the page is visible, the app observes WebKit's
public `themeColor` and `underPageBackgroundColor` properties. The declared
theme color drives the title region; when the page does not declare one, the
WebKit-derived page background is the fallback. That same derived background
drives the native window backing and WebKit's own scroll-bounce area. Both
properties are KVO-observable, so page navigation and in-page appearance
changes update the native chrome without polling or rendered-pixel snapshots.
The app does not inspect WebKit's private scroll-view hierarchy or override its
elasticity. The full title region remains the native drag target to the right
of the controls.

Safari also has an internal top-edge color extension that is not exposed by
public `WKWebView`. To preserve that detail when a full-width banner appears at
the page edge, the app uses a document-end script to inspect the computed
background of DOM elements touching the top edge. A majority sample across the
width drives the native title region. The sample is taken once after each real
document navigation has settled. SwiftUI's native appearance environment also
requests exactly one new sample after WebKit repaints for a system Light/Dark
transition; this avoids relying on an unreliable in-page media-query callback.
The page's own theme switch is handled separately by watching only theme-related
class and data attributes on the document root; it does not need to navigate.
Modal subtree changes, body scroll locks, animations, other later DOM changes,
and scroll bounce cannot recolor the bar. Translucent viewport overlays are
ignored, and CSS colors are preserved explicitly in their native sRGB color
space so the title and page shades match. The same locked sample is applied to
WebKit's public `underPageBackgroundColor`, which is specifically the
backdrop revealed beyond the document bounds, so top rubber-banding continues
the title color instead of exposing black. The page's separately captured body
background still backs the native window. WebKit's public theme and derived
under-page colors remain the fallback, and no private WebKit API is used.

The app includes a bounded, live container-log stream. Every service's stdout and
stderr is captured as it is written and delivered to a native log window. Open
it with **Stack → Show Live Logs** or Command-Shift-L, filter by service, turn
automatic following on or off, select text, or clear the captured session from
the Stack menu. The in-memory viewer retains the latest 8,000 lines and does
not grant filesystem access or add any entitlement.

Version 6 replaces the line-by-line SwiftUI viewer with one native AppKit text
console. Output is anchored at the top-left, horizontally and vertically
scrollable, and selectable continuously across any number of lines. Every
source row in the sidebar is now clickable across its full width, and startup
failures show a concise summary while directing complete diagnostic output to
the log console.

Version 6 also migrates runtime disks to journaled ext4 images. Disposable
service filesystems are rebuilt once in the journaled format, and persistent
data uses the new `volumes-journaled-v1` set. Earlier unjournaled `volumes`
files remain untouched in the sandbox as a recoverable backup. This prevents
an interrupted VM shutdown from surfacing later as an opaque gRPC startup
failure. Runtime-level failures are also written into the live console.

Version 7 removes the fixed public DNS dependency. The sandbox-compatible
Virtualization NAT device is configured through a short-lived DHCP initializer
inside the private VM before any application workload starts; the initializer
uses the Redis image already present in the stack and receives only the Linux
`CAP_NET_ADMIN` capability for its brief run. Before waiting for Prisma, the
initializer performs a DNS lookup after accepting its lease and streams the
result to the native console before `db-init` is started. A failed lookup now
produces a focused networking error instead of being buried in Prisma's engine
download output. No macOS entitlement or external helper was added.

The bootstrap interface has no guessed gateway or DNS server. It begins on the
non-routable RFC 5737 documentation range and is replaced completely by the
address, route, search domain, and resolver returned by Virtualization's DHCP
service. The platform image briefly starts as root only to install that leased
resolver, then drops irreversibly to its original uid/gid 1001 before executing
the image entrypoint.

The current `platform-community-init` image can still emit Prisma's missing
OpenSSL detection warning. Version 7 intentionally does not mutate that image
or install packages at runtime; OpenSSL and the matching Prisma engine should
be fixed in the upstream image. With the leased resolver in place, the current
fallback engine download is able to complete instead of failing with
`getaddrinfo EAI_AGAIN`.

Requirements: Apple silicon, macOS 26 or newer, sufficient disk space for the
stack images, and Internet access on first launch. This local build is ad-hoc
signed. Distribution requires Developer ID signing and notarization.
