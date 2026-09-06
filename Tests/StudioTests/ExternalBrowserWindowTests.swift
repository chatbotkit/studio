import Foundation
import Testing
import AppKit
import WebKit
@testable import Studio

@Test @MainActor func newWindowLinksOpenOnceInBrowser() {
    var opened: [URL] = []
    let handler = ExternalBrowserWindowDelegate { opened.append($0); return true }
    for address in ["https://chatbotkit.com/docs?q=hello#example", "http://127.0.0.1:3000/help"] {
        let url = URL(string: address)!
        #expect(handler.openInDefaultBrowser(URLRequest(url: url)))
    }
    #expect(opened.map(\.absoluteString) == ["https://chatbotkit.com/docs?q=hello#example", "http://127.0.0.1:3000/help"])
}

@Test @MainActor func nonWebLinksAndPostAreNotHandedToOtherApps() {
    var opened: [URL] = []
    let handler = ExternalBrowserWindowDelegate { opened.append($0); return true }
    for address in ["file:///tmp/test", "javascript:alert(1)", "data:text/html,test", "about:blank", "studio://test", "mailto:test@example.com", "https:/missing-host"] {
        #expect(!handler.openInDefaultBrowser(URLRequest(url: URL(string: address)!)))
    }
    var post = URLRequest(url: URL(string: "https://example.com/submit")!)
    post.httpMethod = "POST"
    #expect(!handler.openInDefaultBrowser(post))
    #expect(opened.isEmpty)
}

@Test @MainActor func failedBrowserOpenIsReported() {
    let handler = ExternalBrowserWindowDelegate { _ in false }
    #expect(!handler.openInDefaultBrowser(URLRequest(url: URL(string: "https://example.com")!)))
}

@Test @MainActor func newWindowsStayInStudioOnlyForTheExactOrigin() {
    var internalURLs: [URL] = []
    var browserURLs: [URL] = []
    let handler = ExternalBrowserWindowDelegate(
        openURL: { browserURLs.append($0); return true },
        openInternalURL: { internalURLs.append($0); return true }
    )
    let source = URL(string: "http://127.0.0.1:3000/overview")!

    #expect(handler.openNewWindow(
        URLRequest(url: URL(string: "http://127.0.0.1:3000/bots/new")!),
        from: source
    ))
    #expect(handler.openNewWindow(
        URLRequest(url: URL(string: "http://127.0.0.1:4000/help")!),
        from: source
    ))
    #expect(handler.openNewWindow(
        URLRequest(url: URL(string: "https://chatbotkit.com/docs")!),
        from: source
    ))

    #expect(internalURLs.map(\.absoluteString) == ["http://127.0.0.1:3000/bots/new"])
    #expect(browserURLs.map(\.absoluteString) == [
        "http://127.0.0.1:4000/help",
        "https://chatbotkit.com/docs"
    ])
}

@Test @MainActor func implicitAndExplicitDefaultPortsHaveTheSameOrigin() {
    #expect(ExternalBrowserWindowDelegate.hasSameOrigin(
        URL(string: "https://example.com/new")!,
        URL(string: "https://example.com:443/current")!
    ))
    #expect(!ExternalBrowserWindowDelegate.hasSameOrigin(
        URL(string: "http://example.com/new")!,
        URL(string: "https://example.com/current")!
    ))
}

@Test @MainActor func embeddedLoopbackPageIsGrantedMicrophoneOnly() {
    let pageURL = URL(string: "http://127.0.0.1:3000/overview")!
    #expect(ExternalBrowserWindowDelegate.mediaCaptureDecision(
        type: .microphone,
        scheme: "http",
        host: "127.0.0.1",
        port: 3000,
        pageURL: pageURL
    ) == .grant)
    #expect(ExternalBrowserWindowDelegate.mediaCaptureDecision(
        type: .cameraAndMicrophone,
        scheme: "http",
        host: "127.0.0.1",
        port: 3000,
        pageURL: pageURL
    ) == .deny)
}

@Test @MainActor func mediaCaptureIsDeniedOutsideTheLoadedLoopbackOrigin() {
    let pageURL = URL(string: "http://127.0.0.1:3000/overview")!
    for (scheme, host, port) in [
        ("https", "example.com", 443),
        ("http", "localhost", 3000),
        ("http", "127.0.0.1", 4000)
    ] {
        #expect(ExternalBrowserWindowDelegate.mediaCaptureDecision(
            type: .microphone,
            scheme: scheme,
            host: host,
            port: port,
            pageURL: pageURL
        ) == .deny)
    }
}

@MainActor private final class PageLoadObserver: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
}

@Test @MainActor func webKitRoutesBlankAndWindowOpenWithoutReplacingPage() async throws {
    _ = NSApplication.shared
    var opened: [URL] = []
    let handler = ExternalBrowserWindowDelegate { opened.append($0); return true }
    let observer = PageLoadObserver()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    // Programmatic clicks lack a user gesture in this test. Production keeps
    // WebKit's normal popup policy; we enable this only in the fixture.
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
    view.uiDelegate = handler
    view.navigationDelegate = observer
    defer { view.stopLoading(); view.uiDelegate = nil; view.navigationDelegate = nil }
    view.loadHTMLString("<a id='external' href='https://example.com/blank' target='_blank' rel='noopener'>External</a>", baseURL: nil)
    for _ in 0..<200 where !observer.finished { try await Task.sleep(for: .milliseconds(25)) }
    try #require(observer.finished)
    let originalURL = view.url
    _ = try await view.evaluateJavaScript("document.getElementById('external').click(); void 0")
    for _ in 0..<200 where opened.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
    try #require(opened.map(\.absoluteString) == ["https://example.com/blank"])
    #expect(view.url == originalURL)
    _ = try await view.evaluateJavaScript("window.open('https://example.com/window', '_blank'); void 0")
    for _ in 0..<200 where opened.count < 2 { try await Task.sleep(for: .milliseconds(25)) }
    #expect(opened.map(\.absoluteString) == ["https://example.com/blank", "https://example.com/window"])
    #expect(view.url == originalURL)
}

@Test @MainActor func webKitRoutesSameOriginBlankToStudioWindow() async throws {
    _ = NSApplication.shared
    var internalURLs: [URL] = []
    var browserURLs: [URL] = []
    let handler = ExternalBrowserWindowDelegate(
        openURL: { browserURLs.append($0); return true },
        openInternalURL: { internalURLs.append($0); return true }
    )
    let observer = PageLoadObserver()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
    view.uiDelegate = handler
    view.navigationDelegate = observer
    defer { view.stopLoading(); view.uiDelegate = nil; view.navigationDelegate = nil }
    view.loadHTMLString(
        "<a id='internal' href='/bots/new' target='_blank' rel='noopener'>Internal</a>",
        baseURL: URL(string: "http://127.0.0.1:3000/overview")!
    )
    for _ in 0..<200 where !observer.finished { try await Task.sleep(for: .milliseconds(25)) }
    try #require(observer.finished)
    let originalURL = view.url
    _ = try await view.evaluateJavaScript("document.getElementById('internal').click(); void 0")
    for _ in 0..<200 where internalURLs.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
    #expect(internalURLs.map(\.absoluteString) == ["http://127.0.0.1:3000/bots/new"])
    #expect(browserURLs.isEmpty)
    #expect(view.url == originalURL)
}
