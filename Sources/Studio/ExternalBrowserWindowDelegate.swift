import AppKit
import WebKit

/// Keeps new-window web links out of the embedded app window. WebKit calls this
/// for target="_blank", new named windows, and direct window.open(url) requests.
@MainActor
final class ExternalBrowserWindowDelegate: NSObject, WKUIDelegate {
    private let openInternalURL: (URL) -> Bool
    private let openURL: (URL) -> Bool
    let confirmations: WebConfirmationController

    init(
        confirmations: WebConfirmationController = WebConfirmationController(),
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        openInternalURL: @escaping (URL) -> Bool = { _ in false }
    ) {
        self.confirmations = confirmations
        self.openInternalURL = openInternalURL
        self.openURL = openURL
        super.init()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        confirmations.request(.init(kind: .javascript, message: message), in: webView.window) { completionHandler($0) }
    }

    // macOS WebKit still exposes beforeunload only through this UIDelegate SPI.
    // WebKit detects the selector itself; no JS handler replacement, synthetic
    // dirty-state tracking, or relaxation of its user-activation policy.
    // Source: WebKit/Source/WebKit/UIProcess/API/Cocoa/WKUIDelegatePrivate.h
    @objc(_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
    func runBeforeUnload(_ webView: WKWebView, message: String, frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        confirmations.request(.init(kind: .leavePage, message: ""), in: webView.window, reply: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        decisionHandler(Self.mediaCaptureDecision(
            type: type,
            scheme: origin.protocol,
            host: origin.host,
            port: origin.port,
            pageURL: webView.url
        ))
    }

    static func mediaCaptureDecision(
        type: WKMediaCaptureType,
        scheme: String,
        host: String,
        port: Int,
        pageURL: URL?
    ) -> WKPermissionDecision {
        guard type == .microphone,
              let pageURL,
              let pageScheme = pageURL.scheme,
              let pageHost = pageURL.host,
              ["127.0.0.1", "localhost", "::1"].contains(host.lowercased()),
              scheme.caseInsensitiveCompare(pageScheme) == .orderedSame,
              host.caseInsensitiveCompare(pageHost) == .orderedSame,
              pageURL.port == port else { return .deny }
        // Studio is not a general-purpose browser. Once the request has passed
        // the exact loaded-loopback-origin and microphone-only checks above,
        // defer user consent to macOS rather than showing a second WebKit prompt
        // labelled with the internal 127.0.0.1 address.
        return .grant
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            openNewWindow(navigationAction.request, from: webView.url)
        }
        // SwiftUI owns Studio windows; do not let WebKit create an unmanaged
        // browser window or replace the page that initiated the request.
        return nil
    }

    @discardableResult
    func openNewWindow(_ request: URLRequest, from pageURL: URL?) -> Bool {
        guard let url = webURL(for: request) else { return false }
        if Self.hasSameOrigin(url, pageURL) {
            return openInternalURL(url)
        }
        return openURL(url)
    }

    @discardableResult
    func openInDefaultBrowser(_ request: URLRequest) -> Bool {
        guard let url = webURL(for: request) else {
            // NSWorkspace can also launch apps and local files. Do not let
            // arbitrary page content use this browser handoff for those URLs,
            // or silently turn a new-window POST into a GET.
            return false
        }
        return openURL(url)
    }

    private func webURL(for request: URLRequest) -> URL? {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty,
              (request.httpMethod ?? "GET").uppercased() == "GET" else { return nil }
        return url
    }

    static func hasSameOrigin(_ destination: URL, _ source: URL?) -> Bool {
        guard let source,
              let destinationScheme = destination.scheme?.lowercased(),
              let sourceScheme = source.scheme?.lowercased(),
              let destinationHost = destination.host?.lowercased(),
              let sourceHost = source.host?.lowercased() else { return false }
        return destinationScheme == sourceScheme
            && destinationHost == sourceHost
            && effectivePort(destination) == effectivePort(source)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}
