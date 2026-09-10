import Foundation
import Testing
import WebKit
@testable import Studio

@Test @MainActor func manifestNewWindowsRespectHostAndPortBoundaries() throws {
    let manifest = try testStackManifest()
    var internalURLs: [URL] = []
    var externalURLs: [URL] = []
    let delegate = ExternalBrowserWindowDelegate(manifest: manifest,
        openURL: { externalURLs.append($0); return true },
        openInternalURL: { internalURLs.append($0); return true })
    let source = try #require(manifest.url(for: "site"))
    let local = ["http://cbk-apps.localhost:31000/app", "http://cbk-labs.localhost:31000/lab", "http://team.cbk-space.localhost:31000/"]
    let external = ["http://cbk-apps.localhost:9999/", "http://undeclared.localhost:31000/", "https://example.com/", "http://evilcbk-space.localhost:31000/"]
    for address in local + external {
        #expect(delegate.openNewWindow(URLRequest(url: try #require(URL(string: address))), from: source))
    }
    #expect(internalURLs.map(\.absoluteString) == local)
    #expect(externalURLs.map(\.absoluteString) == external)
    #expect(delegate.openNewWindow(URLRequest(url: source), from: URL(string: "https://example.com")))
    #expect(externalURLs.last == source)
}

@Test @MainActor func manifestMicrophoneStillRequiresExactLoadedOrigin() throws {
    let manifest = try testStackManifest()
    for (host, port, expected) in [("cbk-apps.localhost", 31000, true), ("team.cbk-space.localhost", 31000, true), ("cbk-apps.localhost", 9999, false), ("undeclared.localhost", 31000, false)] {
        let page = URL(string: "http://\(host):\(port)/")!
        #expect(ExternalBrowserWindowDelegate.mediaCaptureDecision(type: .microphone, scheme: "http", host: host, port: port, pageURL: page, manifest: manifest) == (expected ? .grant : .deny))
        #expect(ExternalBrowserWindowDelegate.mediaCaptureDecision(type: .cameraAndMicrophone, scheme: "http", host: host, port: port, pageURL: page, manifest: manifest) == .deny)
    }
    #expect(ExternalBrowserWindowDelegate.mediaCaptureDecision(type: .microphone, scheme: "http", host: "cbk-labs.localhost", port: 31000, pageURL: manifest.url(for: "apps"), manifest: manifest) == .deny)
}

@Test func sitePortFallbackSkipsBothAuxiliaryReservations() async throws {
    let blocker = LocalTCPForwarder()
    let site = LocalTCPForwarder()
    let fixed = LocalTCPForwarder()
    defer { blocker.stop(); site.stop(); fixed.stop() }
    // Reserve our own high port, without touching another application's listener.
    let preferred = try await blocker.start(preferredPort: UInt16.random(in: 50000...59000), targetUnixSocketPath: "/tmp/studio-unused-test.sock")
    let chosen = try await site.start(preferredPort: preferred, targetUnixSocketPath: "/tmp/studio-unused-test.sock", excluding: [preferred + 1, preferred + 2])
    #expect(chosen >= preferred + 3 && chosen <= preferred + 9)
    do {
        _ = try await fixed.start(preferredPort: preferred, targetUnixSocketPath: "/tmp/studio-unused-test.sock", allowFallback: false)
        Issue.record("An occupied auxiliary port must fail, not fall back")
    } catch { #expect(error is AppRuntimeError) }
}
