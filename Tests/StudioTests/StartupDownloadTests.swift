import AppKit
import Containerization
import ContainerizationExtras
import Foundation
import SwiftUI
import Testing
@testable import Studio

@Test func startupDownloadAggregatesConcurrentLayersAndGrowingTotals() {
    var download = StartupDownload()
    #expect(download.fraction == nil)
    #expect(download.percentage == nil)
    #expect(download.summary == "Connecting…")
    download.apply([.addTotalSize(100), .addSize(100), .addItems(1)])
    #expect(download.fraction == nil) // Manifest complete, not the whole image.
    download.apply([.addTotalSize(900), .addSize(150), .addSize(250)])
    #expect(download.completedBytes == 500)
    #expect(download.totalBytes == 1_000)
    #expect(download.fraction == 0.5)
    #expect(download.percentage == "50%")
    #expect(download.summary.contains(" of "))
    download.apply([.addSize(500)])
    #expect(download.fraction == nil) // Still verifying/promoting, not finished.
    #expect(download.percentage == nil)
    #expect(download.summary.hasSuffix(" ready"))
}

@Test @MainActor func startupDownloadPublishesModeChangesWithoutWaitingForAnotherBuffer() async {
    var updates: [StartupDownload?] = []
    let reporter = StartupDownloadReporter { updates.append($0) }
    let start = ContinuousClock.now
    await reporter.receive([.addTotalSize(100)], now: start)
    // Metadata finishes, then the importer discovers the image layers, all
    // within the throttle interval. Neither transition may leave a stale bar.
    await reporter.receive([.addSize(100)], now: start.advanced(by: .milliseconds(10)))
    #expect(updates.count == 2)
    #expect(updates.last??.fraction == nil)
    await reporter.receive([.addTotalSize(900)], now: start.advanced(by: .milliseconds(20)))
    #expect(updates.count == 3)
    #expect(updates.last??.fraction == 0.1)
    #expect(updates.last??.percentage == "10%")
    await reporter.finish()
}

@Test @MainActor func startupDownloadDeliversTrailingBytesDuringCallbackPause() async throws {
    var updates: [StartupDownload?] = []
    let delay = StartupPublicationDelay()
    let reporter = StartupDownloadReporter(sleep: { _ in await delay.wait() }) { updates.append($0) }
    let start = ContinuousClock.now
    await reporter.receive([.addTotalSize(1_000)], now: start)
    await reporter.receive([.addSize(400)], now: start)
    #expect(updates.count == 1)
    await delay.release()
    try await Task.sleep(for: .milliseconds(400))
    #expect(updates.count == 2)
    #expect(updates.last??.fraction == 0.4)
    await reporter.finish()
}

@Test @MainActor func startupDownloadFinishCancelsPendingPublication() async throws {
    var updates: [StartupDownload?] = []
    let delay = StartupPublicationDelay()
    let reporter = StartupDownloadReporter(sleep: { _ in await delay.wait() }) { updates.append($0) }
    let start = ContinuousClock.now
    await reporter.receive([.addTotalSize(1_000)], now: start)
    await reporter.receive([.addSize(400)], now: start)
    await reporter.finish()
    await delay.release()
    try await Task.sleep(for: .milliseconds(400))
    #expect(updates.count == 2)
    #expect(updates.last! == nil)
}

private actor StartupPublicationDelay {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

@Test @MainActor func startupProgressBarSwitchesNativeModesInTheSameWindow() async throws {
    let host = NSHostingView(rootView: StudioStartupProgressBar(fraction: nil))
    host.frame = NSRect(x: 0, y: 0, width: 360, height: 40)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    func indicators(in view: NSView) -> [NSProgressIndicator] {
        (view as? NSProgressIndicator).map { [$0] } ?? view.subviews.flatMap { indicators(in: $0) }
    }
    // Exercise activity → downloading → preparation → next image, not just
    // separate static renders that never change an existing control's mode.
    for fraction: Double? in [nil, 0, 0.25, 0.75, nil, 0.1, nil] {
        host.rootView = StudioStartupProgressBar(fraction: fraction)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let controls = indicators(in: host)
        #expect(controls.count == 1)
        let control = try #require(controls.first)
        #expect(control.isIndeterminate == (fraction == nil))
        if let fraction {
            #expect(control.doubleValue == fraction)
            #expect(control.maxValue == 1)
        }
    }
}

@Test func startupDownloadRejectsNegativeDeltasAndBoundsOverflow() {
    var download = StartupDownload()
    download.apply([.addSize(-1), .addTotalSize(-100)])
    #expect(download == StartupDownload())
    download.apply([.addSize(.max), .addSize(20), .addTotalSize(.max), .addTotalSize(20)])
    #expect(download.completedBytes == .max)
    #expect(download.totalBytes == .max)
    #expect(download.fraction == nil)
}

@Test @MainActor func startupDownloadThrottlesWithoutLosingBytesAndIgnoresLateCallbacks() async {
    var updates: [StartupDownload?] = []
    let delay = StartupPublicationDelay()
    let reporter = StartupDownloadReporter(sleep: { _ in await delay.wait() }) { updates.append($0) }
    let start = ContinuousClock.now
    await reporter.receive([.addTotalSize(1_000)], now: start)
    for _ in 0..<100 {
        await reporter.receive([.addSize(1)], now: start.advanced(by: .milliseconds(50)))
    }
    #expect(updates.count == 1)
    await reporter.receive([.addSize(20)], now: start.advanced(by: .milliseconds(250)))
    #expect(updates.count == 2)
    #expect(updates.last??.completedBytes == 120)
    await reporter.finish()
    await delay.release()
    await reporter.receive([.addSize(99)], now: start.advanced(by: .seconds(1)))
    await reporter.finish()
    #expect(updates.count == 3)
    #expect(updates.last! == nil)
}

@Test @MainActor func startupDownloadClearsOnSuccessFailureAndCancellation() async throws {
    var updates: [StartupDownload?] = []
    let value = try await StartupDownloadReporter.track(publish: { updates.append($0) }) { progress in
        await progress([.addTotalSize(100), .addSize(40)])
        return 42
    }
    #expect(value == 42)
    #expect(updates.first! == StartupDownload())
    #expect(updates.last! == nil)
    for cancellation in [false, true] {
        updates = []
        do {
            let _: Int = try await StartupDownloadReporter.track(publish: { updates.append($0) }) { progress in
                await progress([.addTotalSize(100), .addSize(40)])
                if cancellation { throw CancellationError() }
                throw AppRuntimeError("fixture failure")
            }
            Issue.record("Expected failure")
        } catch {
            #expect(updates.first! == StartupDownload())
            #expect(updates.last! == nil)
        }
    }
}

@Test func startupServicesDistinguishWaitingDownloadingAndReady() {
    #expect(ServicePhase.pending.title == "Waiting")
    #expect(ServicePhase.downloading.title == "Downloading")
    #expect(ServicePhase.preparing.title == "Preparing")
    #expect(ServicePhase.prepared.title == "Ready")
}

// Opt-in real importer check: a small public image in an isolated temporary
// store. Never opens Studio, boots a VM, or touches the user's image cache.
@Test(.enabled(if: ProcessInfo.processInfo.environment["STUDIO_DOWNLOAD_SMOKE"] == "1"), .timeLimit(.minutes(1)))
@MainActor func startupDownloadReceivesMeasuredProgressFromRealImagePull() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("studio-download-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ImageStore(path: directory)
    var updates: [StartupDownload?] = []
    _ = try await StartupDownloadReporter.track(publish: { updates.append($0) }) { progress in
        try await store.pull(reference: "docker.io/library/alpine:3.22", platform: .current, progress: progress)
    }
    #expect(updates.contains { ($0?.totalBytes ?? 0) > 1_000_000 && $0?.fraction != nil })
    #expect(updates.contains { ($0?.completedBytes ?? 0) > 1_000_000 })
    #expect(updates.last! == nil)
}

// Optional component renders exercise the real native view without launching a
// stack or replacing/activating the installed app. Files stay in an explicit
// test output directory, and artwork comes from the existing renderer override.
@Test(.enabled(if: ProcessInfo.processInfo.environment["STUDIO_PROGRESS_SNAPSHOTS"] != nil))
@MainActor func renderStartupProgressStates() async throws {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STUDIO_PROGRESS_SNAPSHOTS"]!)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var download = StartupDownload()
    download.apply([.addTotalSize(820_000_000), .addSize(148_000_000)])
    for dark in [false, true] {
        for activeDownload in [false, true] {
            let view = StudioLaunchSurface(
                detail: activeDownload ? "Downloading platform" : "Preparing platform",
                download: activeDownload ? download : nil,
                services: [("db-init", "Ready"), ("redis", "Ready"), ("qdrant", "Ready"), ("garage", "Ready"), ("garage-init", "Ready"), ("platform", activeDownload ? "Downloading" : "Preparing")]
            ).environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 520, height: 570)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("\(dark ? "dark" : "light")-\(activeDownload ? "download" : "prepare").png"))
        }
    }
}
