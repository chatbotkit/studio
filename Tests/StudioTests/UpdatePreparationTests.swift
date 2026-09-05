import Testing
@testable import Studio

@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

@Test @MainActor func updateWaitsForBusyOperationsThenShutdownBeforeInstall() async throws {
    var busy = true
    var events: [String] = []
    let gate = UpdatePreparation(busy: { busy }, shutdown: { events.append("shutdown"); return true }, pollInterval: .milliseconds(5), schedule: { $0() })
    gate.prepare { events.append("install") }
    try await Task.sleep(for: .milliseconds(30))
    #expect(events.isEmpty)
    #expect(gate.waiting)
    busy = false
    try await waitUntil { events.count == 2 }
    #expect(events == ["shutdown", "install"])
    #expect(!gate.waiting)
    gate.retry()
    #expect(events.count == 2)
}

@Test @MainActor func failedUpdateShutdownNeverInstallsAndCanRetry() async throws {
    var stops = 0, installs = 0
    let gate = UpdatePreparation(busy: { false }, shutdown: { stops += 1; return stops > 1 }, schedule: { $0() })
    gate.prepare { installs += 1 }
    try await waitUntil { gate.error != nil }
    #expect(installs == 0)
    #expect(!gate.waiting)
    gate.retry(); gate.retry()
    try await waitUntil { installs == 1 }
    #expect(stops == 2)
    #expect(gate.error == nil)
}

@Test @MainActor func abortedUpdateCannotInvokeQueuedInstallHandler() async throws {
    var scheduled: (@MainActor () -> Void)?
    var installs = 0
    let gate = UpdatePreparation(busy: { false }, shutdown: { true }, schedule: { scheduled = $0 })
    gate.prepare { installs += 1 }
    try await waitUntil { scheduled != nil }
    gate.cancel()
    scheduled?()
    #expect(installs == 0)
    #expect(!gate.waiting)
}

@Test @MainActor func replacementUpdateDiscardsPreviousInstallCallback() async throws {
    var busy = true, first = 0, second = 0
    let gate = UpdatePreparation(busy: { busy }, shutdown: { true }, pollInterval: .milliseconds(5), schedule: { $0() })
    gate.prepare { first += 1 }
    gate.prepare { second += 1 }
    busy = false
    try await waitUntil { second == 1 }
    #expect(first == 0)
}

@Test @MainActor func abortDuringShutdownCannotInstallAfterLateCompletion() async throws {
    var resume: CheckedContinuation<Bool, Never>?
    var installs = 0
    var recovered = false
    let gate = UpdatePreparation(busy: { false }, shutdown: {
        await withCheckedContinuation { resume = $0 }
    }, cancelledShutdown: { recovered = true }, schedule: { $0() })
    gate.prepare { installs += 1 }
    try await waitUntil { resume != nil }
    gate.cancel()
    resume?.resume(returning: true)
    try await waitUntil { recovered }
    #expect(installs == 0)
}
