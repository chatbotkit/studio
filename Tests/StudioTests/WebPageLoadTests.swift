import AppKit
import WebKit
import Testing
@testable import Studio

@Test func startupSurfaceIsRetiredUntilTheStackIsReplaced() {
    var reveal = WebPageRevealState()
    #expect(!reveal.hasRevealedPage)

    reveal.documentBecameReady()
    #expect(reveal.hasRevealedPage)

    reveal.documentStartedLoading()
    #expect(reveal.hasRevealedPage)

    reveal.stackWasReplaced()
    #expect(!reveal.hasRevealedPage)
}

@Test @MainActor func pageTimeoutBecomesRetryableFailure() async throws {
    let load = WebPageLoad(deadline: .milliseconds(20)) { _ in }
    load.begin()
    // Native WebKit/console tests share the main actor. Wait for the event,
    // rather than assuming the timeout task was scheduled before this sleep.
    for _ in 0..<200 where load.state == .loading { try await Task.sleep(for: .milliseconds(10)) }
    if case .failed = load.state {} else { Issue.record("Expected timeout failure") }
    load.begin(); load.documentFinished()
    load.invalidate()
}

@Test @MainActor func supersededAndDismantledLoadsCannotPublishReady() async throws {
    var events: [WebPageState] = []
    let load = WebPageLoad(deadline: .seconds(2), settleDelay: .milliseconds(30)) { events.append($0) }
    load.begin(); load.documentFinished(); load.begin()
    try await Task.sleep(for: .milliseconds(80))
    #expect(events == [.loading, .loading])
    load.documentFinished(); load.invalidate()
    try await Task.sleep(for: .milliseconds(80))
    #expect(events == [.loading, .loading])
}

@Test @MainActor func pageFailureCancelsPendingReadyAndRetryCanSucceed() async throws {
    let load = WebPageLoad(deadline: .seconds(2), settleDelay: .milliseconds(20)) { _ in }
    load.begin(); load.documentFinished(); load.fail("process stopped")
    try await Task.sleep(for: .milliseconds(60))
    #expect(load.state == .failed("process stopped"))
    load.begin(); load.documentFinished()
    for _ in 0..<200 where load.state != .ready { try await Task.sleep(for: .milliseconds(10)) }
    #expect(load.state == .ready)
    load.invalidate()
}

@Test @MainActor func realWebKitRevealsBlackPageAndReportsProcessFailure() async throws {
    _ = NSApplication.shared
    var ready = false
    var failure: String?
    let coordinator = EmbeddedWebView.Coordinator(onEdgeColors: { _, _ in }, onReady: { ready = true }, onFailure: { failure = $0 })
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
    view.navigationDelegate = coordinator
    coordinator.startColorObservation(in: view)
    defer { coordinator.stopColorObservation(); view.stopLoading(); view.navigationDelegate = nil }
    view.loadHTMLString("<html style='background:black'><body style='background:black'></body></html>", baseURL: nil)
    for _ in 0..<200 where !ready { try await Task.sleep(for: .milliseconds(10)) }
    #expect(ready)
    coordinator.webViewWebContentProcessDidTerminate(view)
    #expect(failure?.contains("still running") == true)
}

@Test @MainActor func realNavigationFailureCanRecoverWithoutRestartingRuntime() async throws {
    _ = NSApplication.shared
    var ready = false
    var failure: String?
    let coordinator = EmbeddedWebView.Coordinator(onEdgeColors: { _, _ in }, onReady: { ready = true }, onFailure: { failure = $0 })
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
    view.navigationDelegate = coordinator
    coordinator.startColorObservation(in: view)
    defer { coordinator.stopColorObservation(); view.stopLoading(); view.navigationDelegate = nil }
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("studio-missing-\(UUID().uuidString).html")
    view.loadFileURL(missing, allowingReadAccessTo: missing)
    for _ in 0..<300 where failure == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(failure != nil)
    #expect(!ready)
    view.loadHTMLString("<html><body>Recovered</body></html>", baseURL: nil)
    for _ in 0..<300 where !ready { try await Task.sleep(for: .milliseconds(10)) }
    #expect(ready)
}
