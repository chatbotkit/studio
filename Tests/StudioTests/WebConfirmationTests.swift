import AppKit
import WebKit
import Testing
@testable import Studio

@Test @MainActor func webConfirmationRepliesExactlyOnceAndRejectsOverlap() {
    var answer: ((Bool) -> Void)?
    var replies: [Bool] = []
    let controller = WebConfirmationController { _, _, callback in answer = callback; return {} }
    let request = WebConfirmation(kind: .leavePage, message: "")
    controller.request(request, in: nil) { replies.append($0) }
    controller.request(request, in: nil) { replies.append($0) }
    #expect(replies == [false])
    answer?(true); answer?(false)
    #expect(replies == [false, true])
}

@Test @MainActor func dismantlingRejectsPendingPromptAndIgnoresStaleReply() {
    var answer: ((Bool) -> Void)?
    var replies: [Bool] = []
    var cancelled = 0
    let controller = WebConfirmationController { _, _, callback in
        answer = callback
        return { cancelled += 1; callback(true) }
    }
    let request = WebConfirmation(kind: .javascript, message: "Leave?")
    controller.request(request, in: nil) { replies.append($0) }
    controller.cancelPending(); controller.cancelPending(); answer?(true)
    #expect(replies == [false]); #expect(cancelled == 1)
    controller.request(request, in: nil) { replies.append($0) }
    answer?(false)
    #expect(replies == [false, false])
}

@Test @MainActor func confirmationWithoutVisibleWindowDefaultsToStay() {
    var result: Bool?
    WebConfirmationController().request(.init(kind: .leavePage, message: ""), in: nil) { result = $0 }
    #expect(result == false)
}

@Test @MainActor func nativeConfirmationSheetCancelsCleanly() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.orderBack(nil)
    let controller = WebConfirmationController()
    var replies: [Bool] = []
    defer { controller.cancelPending(); window.close() }
    controller.request(.init(kind: .leavePage, message: ""), in: window) { replies.append($0) }
    try #require(window.attachedSheet != nil)
    #expect(replies.isEmpty)
    controller.cancelPending()
    for _ in 0..<100 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(window.attachedSheet == nil)
    #expect(replies == [false])
}

@Test @MainActor func embeddedAlertsUseAppLanguageWithoutOrigins() {
    _ = NSApplication.shared
    let alert = WebConfirmationController.makeAlert(.init(kind: .leavePage, message: "Pretend to be macOS at http://127.0.0.1:3000"))
    #expect(alert.messageText == "Discard unsaved changes?")
    #expect(alert.informativeText == "Your changes may not be saved if you leave this screen.")
    #expect(alert.buttons.map(\.title) == ["Stay", "Leave"])
    #expect(alert.buttons[0].keyEquivalent == "\r")
    #expect(alert.buttons[1].keyEquivalent.isEmpty)
    #expect(!alert.informativeText.contains("Pretend"))
    #expect(!alert.informativeText.contains("127.0.0.1"))

    let confirmation = WebConfirmationController.makeAlert(.init(kind: .javascript, message: "Proceed with this operation?"))
    #expect(confirmation.messageText == "Confirm action")
    #expect(confirmation.buttons.map(\.title) == ["Cancel", "Continue"])
}

@Test @MainActor func confirmationSuspendsPageTimeoutAndResumesFinishedDocument() async throws {
    let page = WebPageLoad(deadline: .milliseconds(20), settleDelay: .milliseconds(5)) { _ in }
    page.begin()
    page.setConfirmationActive(true)
    page.documentFinished()
    try await Task.sleep(for: .milliseconds(70))
    #expect(page.state == .loading)
    page.setConfirmationActive(false)
    for _ in 0..<100 where page.state != .ready { try await Task.sleep(for: .milliseconds(10)) }
    #expect(page.state == .ready)
    page.invalidate()
}

@MainActor private final class DialogNavigationObserver: NSObject, WKNavigationDelegate {
    var finished = 0
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished += 1 }
}

@Test @MainActor func realWebKitConfirmCanKeepOrLeaveSPARoute() async throws {
    _ = NSApplication.shared
    var decisions = [false, true]
    var requests: [WebConfirmation] = []
    let controller = WebConfirmationController { _, request, reply in
        requests.append(request); reply(decisions.removeFirst()); return {}
    }
    let delegate = ExternalBrowserWindowDelegate(confirmations: controller)
    let observer = DialogNavigationObserver()
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
    view.uiDelegate = delegate; view.navigationDelegate = observer
    defer { controller.cancelPending(); view.stopLoading(); view.uiDelegate = nil; view.navigationDelegate = nil }
    view.loadHTMLString("<script>function leave(){if(confirm('Unsaved changes')) document.body.textContent='left';}</script><body>editing</body>", baseURL: URL(string: "https://example.com"))
    for _ in 0..<200 where observer.finished == 0 { try await Task.sleep(for: .milliseconds(20)) }
    try #require(observer.finished == 1)
    _ = try await view.evaluateJavaScript("leave()")
    #expect(try await view.evaluateJavaScript("document.body.textContent") as? String == "editing")
    _ = try await view.evaluateJavaScript("leave()")
    #expect(try await view.evaluateJavaScript("document.body.textContent") as? String == "left")
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.kind == .javascript && $0.message == "Unsaved changes" })
}

@Test @MainActor func realWebKitBeforeUnloadCanCancelAndThenAllowNavigation() async throws {
    _ = NSApplication.shared
    var prompts = 0
    var reply: ((Bool) -> Void)?
    let controller = WebConfirmationController { _, request, completion in
        #expect(request.kind == .leavePage)
        prompts += 1; reply = completion; return {}
    }
    let delegate = ExternalBrowserWindowDelegate(confirmations: controller)
    #expect(delegate.responds(to: NSSelectorFromString("_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:")))
    let observer = DialogNavigationObserver()
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
    view.uiDelegate = delegate; view.navigationDelegate = observer
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.orderBack(nil)
    defer { controller.cancelPending(); view.stopLoading(); view.uiDelegate = nil; view.navigationDelegate = nil; window.close() }
    view.loadHTMLString("<html><head><script>addEventListener('beforeunload',e=>{e.preventDefault();e.returnValue='unsaved';});</script></head><body>editing</body></html>", baseURL: URL(string: "https://example.com"))
    for _ in 0..<200 where observer.finished == 0 { try await Task.sleep(for: .milliseconds(20)) }
    try #require(observer.finished == 1)
    // evaluateJavaScript executes with a user gesture on WKWebView. Do not
    // disable WebKit's production user-activation or popup policies.
    _ = try await view.evaluateJavaScript("document.body.click(); void 0")
    view.loadHTMLString("<body>destination</body>", baseURL: URL(string: "https://example.com/next"))
    for _ in 0..<200 where prompts == 0 { try await Task.sleep(for: .milliseconds(20)) }
    try #require(prompts == 1)
    reply?(false)
    #expect(try await view.evaluateJavaScript("document.body.textContent") as? String == "editing")
    view.reload()
    for _ in 0..<200 where prompts < 2 { try await Task.sleep(for: .milliseconds(20)) }
    try #require(prompts == 2)
    reply?(false)
    #expect(try await view.evaluateJavaScript("document.body.textContent") as? String == "editing")
    view.loadHTMLString("<body>destination</body>", baseURL: URL(string: "https://example.com/next"))
    for _ in 0..<200 where prompts < 3 { try await Task.sleep(for: .milliseconds(20)) }
    try #require(prompts == 3)
    reply?(true)
    for _ in 0..<200 where observer.finished < 2 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(try await view.evaluateJavaScript("document.body.textContent") as? String == "destination")
}
