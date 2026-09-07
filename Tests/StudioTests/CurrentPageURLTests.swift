import AppKit
import Testing
import WebKit
@testable import Studio

@MainActor private final class CurrentPageWebView: WKWebView {
    var pageURL: URL?
    override var url: URL? { pageURL }
}

@Test @MainActor func browserDestinationTracksCurrentPage() {
    _ = NSApplication.shared
    let inspector = EmbeddedWebInspector()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let webView = CurrentPageWebView(frame: .zero, configuration: configuration)
    inspector.attach(webView)

    #expect(inspector.currentPageURL == nil)
    webView.pageURL = URL(string: "http://127.0.0.1:3000/overview")!
    #expect(inspector.currentPageURL == webView.pageURL)

    // Read the live WebKit URL, including changes made by client-side routing.
    let destination = URL(string: "http://127.0.0.1:3000/blueprints/example?tab=build#details")!
    webView.pageURL = destination
    #expect(inspector.currentPageURL == destination)

    inspector.detach(webView)
    #expect(inspector.currentPageURL == nil)
}
