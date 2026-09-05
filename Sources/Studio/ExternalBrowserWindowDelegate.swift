import AppKit
import WebKit

/// Keeps new-window web links out of the embedded app window. WebKit calls this
/// for target="_blank", new named windows, and direct window.open(url) requests.
@MainActor
final class ExternalBrowserWindowDelegate: NSObject, WKUIDelegate {
    private let openURL: (URL) -> Bool

    init(openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.openURL = openURL
        super.init()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            openInDefaultBrowser(navigationAction.request)
        }
        // Do not create another Studio window or replace its current page.
        return nil
    }

    @discardableResult
    func openInDefaultBrowser(_ request: URLRequest) -> Bool {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty,
              (request.httpMethod ?? "GET").uppercased() == "GET" else {
            // NSWorkspace can also launch apps and local files. Do not let
            // arbitrary page content use this browser handoff for those URLs,
            // or silently turn a new-window POST into a GET.
            return false
        }
        return openURL(url)
    }
}
