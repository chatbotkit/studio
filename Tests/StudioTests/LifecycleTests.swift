import Foundation
import Testing
import StudioDiagnostics
@testable import Studio

private actor ShutdownRecorder {
    var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

@Test func gracefulShutdownStopsClientsBeforeStorage() async throws {
    let recorder = ShutdownRecorder()
    let warnings = try await GracefulShutdown.run(
        started: ["redis", "platform", "garage", "qdrant"],
        terminate: { await recorder.record("term \($0)") },
        wait: { name, seconds in
            #expect(seconds == 10)
            await recorder.record("wait \(name)")
        },
        force: { _ in Issue.record("Healthy shutdown must not force-kill services") },
        teardown: { await recorder.record("teardown") }
    )
    #expect(warnings.isEmpty)
    #expect(await recorder.events == ["term platform", "wait platform", "term garage", "wait garage", "term qdrant", "wait qdrant", "term redis", "wait redis", "teardown"])
}

@Test func gracefulShutdownStillTearsDownAfterTimeoutOrSignalFailure() async throws {
    let recorder = ShutdownRecorder()
    let warnings = try await GracefulShutdown.run(
        started: ["platform", "garage", "redis"],
        terminate: { name in
            await recorder.record("term \(name)")
            if name == "garage" { throw AppRuntimeError("already exited") }
        },
        wait: { name, seconds in
            await recorder.record("wait \(name)")
            if name == "platform", seconds == 10 { throw AppRuntimeError("timeout") }
        },
        force: { await recorder.record("kill \($0)") },
        teardown: { await recorder.record("teardown") }
    )
    #expect(warnings.count == 2)
    #expect(warnings[0].contains("platform"))
    #expect(warnings[1].contains("garage"))
    #expect(await recorder.events == ["term platform", "wait platform", "kill platform", "wait platform", "term garage", "kill garage", "wait garage", "term redis", "wait redis", "teardown"])
}

@Test func teardownFailureIsNotSwallowed() async {
    do {
        _ = try await GracefulShutdown.run(started: [], terminate: { _ in }, wait: { _, _ in }, force: { _ in }, teardown: { throw AppRuntimeError("VM stuck") })
        Issue.record("Expected teardown to fail")
    } catch { #expect(error.localizedDescription.contains("VM stuck")) }
}

@Test func failedForceStopDoesNotGracefullyStopDependenciesUnderLiveClient() async throws {
    let recorder = ShutdownRecorder()
    let warnings = try await GracefulShutdown.run(
        started: ["platform", "redis"],
        terminate: { await recorder.record("term \($0)") },
        wait: { _, _ in throw AppRuntimeError("not stopped") },
        force: { await recorder.record("kill \($0)") },
        teardown: { await recorder.record("teardown") }
    )
    #expect(warnings.count == 2)
    #expect(await recorder.events == ["term platform", "kill platform", "teardown"])
}

@Test func probesCleanUpOnSuccessAndFailure() async throws {
    let recorder = ShutdownRecorder()
    let value = try await ScopedProbe.run(operation: { 42 }, cleanup: { failed in
        #expect(!failed)
        await recorder.record("success cleanup")
    })
    #expect(value == 42)
    do {
        let _: Int = try await ScopedProbe.run(operation: { throw AppRuntimeError("probe timeout") }, cleanup: { failed in
            #expect(failed)
            await recorder.record("failure cleanup")
        })
        Issue.record("Expected probe failure")
    } catch { #expect(error.localizedDescription == "probe timeout") }
    #expect(await recorder.events == ["success cleanup", "failure cleanup"])
}

@Test func cancelledProbeStillPerformsUncancelledCleanup() async {
    let recorder = ShutdownRecorder()
    let task = Task {
        try await ScopedProbe.run(operation: {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(30))
        }, cleanup: { failed in
            #expect(failed)
            #expect(!Task.isCancelled)
            await recorder.record("cleanup")
        })
    }
    task.cancel()
    do { try await task.value; Issue.record("Expected cancellation") }
    catch { #expect(error is CancellationError) }
    #expect(await recorder.events == ["cleanup"])
}

@Test func probeCleanupFailureRetainsOriginalDiagnostic() async {
    do {
        let _: Int = try await ScopedProbe.run(operation: { throw AppRuntimeError("original failure") }, cleanup: { _ in throw AppRuntimeError("delete failure") })
        Issue.record("Expected cleanup failure")
    } catch {
        #expect(error.localizedDescription.contains("original failure"))
        #expect(error.localizedDescription.contains("delete failure"))
    }
}

private actor FakeStackRuntime: StackRuntime {
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var overlap = false
    private var starting = false
    private var holdStart = false
    private var holdStop = false
    private var failStop = false
    private var startGate: CheckedContinuation<Void, Never>?
    private var stopGate: CheckedContinuation<Void, Never>?
    private var callbacks: [@MainActor @Sendable (RuntimeEvent) -> Void] = []

    func configure(holdStart: Bool = false, holdStop: Bool = false, failStop: Bool = false) {
        self.holdStart = holdStart; self.holdStop = holdStop; self.failStop = failStop
    }

    func start(kernelURL: URL, dataRoot: URL, event: @escaping @MainActor @Sendable (RuntimeEvent) -> Void) async throws -> StackInfo {
        starts += 1
        starting = true
        callbacks.append(event)
        if holdStart { await withCheckedContinuation { startGate = $0 } }
        starting = false
        // Deliberately ignore cancellation, like a dependency completing late.
        return StackInfo(url: URL(string: "http://127.0.0.1:3000")!, podID: "fixture-\(starts)", dataRoot: "/unused", sourceReference: "fixture", resolvedDigest: "fixture", composeYAML: "", publishedPort: 3000)
    }

    func stop() async throws -> [String] {
        stops += 1
        overlap = overlap || starting
        if holdStop { await withCheckedContinuation { stopGate = $0 } }
        if failStop { throw AppRuntimeError("fixture teardown failed") }
        return []
    }

    func releaseStart() { holdStart = false; startGate?.resume(); startGate = nil }
    func releaseStop() { holdStop = false; stopGate?.resume(); stopGate = nil }
    func emitOldEvent() async { await callbacks.first?(.phase(.failed("stale callback"))) }
    func emitLog() async { await callbacks.last?(.containerLines("platform", ["fixture service output"])) }
    var startWaiting: Bool { startGate != nil }
    var stopWaiting: Bool { stopGate != nil }
}

@MainActor private func fixture(_ runtime: FakeStackRuntime) -> AppModel {
    AppModel(runtime: runtime, resources: { (URL(filePath: "/unused-kernel"), URL(filePath: "/unused-data")) })
}

@Test @MainActor func modelPersistsServiceOutputAndLifecycleWithoutTouchingRealData() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = FakeStackRuntime()
    let model = AppModel(runtime: runtime, diagnostics: try DiagnosticLog(directory: directory), resources: {
        (URL(filePath: "/unused-kernel"), URL(filePath: "/unused-data"))
    })
    model.start()
    try await eventually { model.info != nil }
    await runtime.emitLog()
    model.clearLogs()
    #expect(model.containerLogs.isEmpty)
    #expect(await model.shutdown())
    let saved = try String(contentsOf: directory.appendingPathComponent("current.jsonl"), encoding: .utf8)
    #expect(saved.contains("fixture service output"))
    #expect(saved.contains("Workspace ready"))
    #expect(saved.contains("Shutdown started"))
    #expect(saved.contains("Shutdown completed"))
}

@MainActor private func eventually(_ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<1_000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    try #require(await condition(), "Lifecycle fixture did not reach its expected state")
}

@Test @MainActor func duplicateStartIsClaimedSynchronously() async throws {
    let runtime = FakeStackRuntime()
    let model = fixture(runtime)
    model.start()
    #expect(model.phase == .resolving)
    model.start()
    try await eventually { model.info != nil }
    #expect(await runtime.starts == 1)
    #expect(await model.shutdown())
}

@Test @MainActor func abortedUpdateAfterShutdownAllowsExplicitStackRestart() async throws {
    let runtime = FakeStackRuntime()
    let model = fixture(runtime)
    model.start()
    try await eventually { model.info != nil }
    #expect(await model.shutdown())
    #expect(model.hasCompletedShutdown)
    model.recoverFromAbortedUpdate()
    #expect(!model.hasCompletedShutdown)
    #expect(!model.isShuttingDown)
    model.restart()
    try await eventually { model.info != nil }
    #expect(await runtime.starts == 2)
    #expect(await model.shutdown())
}

@Test @MainActor func shutdownAwaitsStartupAndCoalescesConcurrentRequests() async throws {
    let runtime = FakeStackRuntime()
    await runtime.configure(holdStart: true)
    let model = fixture(runtime)
    model.start()
    try await eventually { await runtime.startWaiting }
    let first = Task { await model.shutdown() }
    try await eventually { model.phase == .stopping }
    let second = Task { await model.shutdown() }
    model.start()
    model.restart()
    #expect(await runtime.stops == 0)
    await runtime.releaseStart()
    #expect(await first.value)
    #expect(await second.value)
    #expect(await runtime.starts == 1)
    #expect(await runtime.stops == 1)
    #expect(await runtime.overlap == false)
    #expect(model.info == nil)
    await runtime.emitOldEvent()
    #expect(model.phase == .idle)
    model.start()
    #expect(model.phase == .idle)
}

@Test @MainActor func duplicateRestartAndStaleEventsCannotReplaceNewRun() async throws {
    let runtime = FakeStackRuntime()
    let model = fixture(runtime)
    model.start()
    try await eventually { model.info != nil }
    await runtime.configure(holdStop: true)
    model.restart()
    #expect(model.phase == .stopping)
    model.restart()
    try await eventually { await runtime.stopWaiting }
    #expect(await runtime.stops == 1)
    await runtime.releaseStop()
    try await eventually { model.info?.podID == "fixture-2" }
    await runtime.emitOldEvent()
    #expect(model.info?.podID == "fixture-2")
    #expect(await runtime.starts == 2)
    #expect(await model.shutdown())
}

@Test @MainActor func quittingDuringRestartCannotStartAnotherStack() async throws {
    let runtime = FakeStackRuntime()
    let model = fixture(runtime)
    model.start()
    try await eventually { model.info != nil }
    await runtime.configure(holdStop: true)
    model.restart()
    try await eventually { await runtime.stopWaiting }
    let quitting = Task { await model.shutdown() }
    try await eventually { model.isShuttingDown }
    await runtime.releaseStop()
    #expect(await quitting.value)
    #expect(await runtime.starts == 1)
    #expect(await runtime.overlap == false)
}

@Test @MainActor func failedShutdownStaysOpenAndCanBeRetried() async throws {
    let runtime = FakeStackRuntime()
    let model = fixture(runtime)
    model.start()
    try await eventually { model.info != nil }
    await runtime.configure(failStop: true)
    #expect(await model.shutdown() == false)
    #expect(model.phase == .failed("fixture teardown failed"))
    await runtime.configure()
    #expect(await model.shutdown())
    #expect(await runtime.stops == 2)
}

@Test @MainActor func immediateQuitDoesNotAcquireStartupResources() async {
    let runtime = FakeStackRuntime()
    var resourceReads = 0
    let model = AppModel(runtime: runtime, resources: {
        resourceReads += 1
        return (URL(filePath: "/unused-kernel"), URL(filePath: "/unused-data"))
    })
    model.start()
    #expect(await model.shutdown())
    #expect(resourceReads == 0)
    #expect(await runtime.starts == 0)
}

@Test @MainActor func missingResourcesFailWithoutStartingRuntime() async throws {
    let runtime = FakeStackRuntime()
    let model = AppModel(runtime: runtime, resources: { throw AppRuntimeError("missing fixture kernel") })
    model.start()
    try await eventually { model.phase == .failed("missing fixture kernel") }
    #expect(await runtime.starts == 0)
    #expect(model.containerLogs.contains { $0.message.contains("missing fixture kernel") })
    #expect(await model.shutdown())
}

@Test @MainActor func failedRestartDoesNotLaunchOverAnUnstoppedVM() async throws {
    let runtime = FakeStackRuntime()
    let model = fixture(runtime)
    model.start()
    try await eventually { model.info != nil }
    await runtime.configure(failStop: true)
    model.restart()
    try await eventually { model.phase == .failed("fixture teardown failed") }
    #expect(await runtime.starts == 1)
    await runtime.configure()
    model.restart()
    try await eventually { model.info?.podID == "fixture-2" }
    #expect(await model.shutdown())
}
