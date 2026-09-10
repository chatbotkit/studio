import AppKit
import ContainerizationExtras
import Foundation
import SwiftUI
import Testing
@testable import Studio

@Test func startupDownloadAggregatesConcurrentLayersAndGrowingTotals() {
    var download = StartupDownload()
    #expect(download.fraction == nil)
    #expect(download.summary == "Connecting…")
    download.apply([.addTotalSize(100), .addSize(100), .addItems(1)])
    #expect(download.fraction == nil) // Manifest complete, not the whole image.
    download.apply([.addTotalSize(900), .addSize(150), .addSize(250)])
    #expect(download.completedBytes == 500)
    #expect(download.totalBytes == 1_000)
    #expect(download.fraction == 0.5)
    #expect(download.summary.contains(" of "))
    download.apply([.addSize(500)])
    #expect(download.fraction == nil) // Still verifying/promoting, not finished.
    #expect(download.summary.hasSuffix(" ready"))
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
    let reporter = StartupDownloadReporter { updates.append($0) }
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
