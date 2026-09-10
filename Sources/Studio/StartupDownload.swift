import ContainerizationExtras
import Foundation

struct StartupDownload: Equatable, Sendable {
    private(set) var completedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0

    mutating func apply(_ events: [ProgressEvent]) {
        for event in events {
            switch event {
            case .addSize(let bytes): completedBytes = adding(bytes, to: completedBytes)
            case .addTotalSize(let bytes): totalBytes = adding(bytes, to: totalBytes)
            default: break
            }
        }
    }

    // The importer discovers more layers as it walks manifests. Reaching the
    // currently known total is not completion: keep activity visible until the
    // entire pull returns (including verification and cache promotion).
    var fraction: Double? {
        guard totalBytes > 0, completedBytes < totalBytes else { return nil }
        return Double(completedBytes) / Double(totalBytes)
    }

    var percentage: String? {
        fraction.map { "\(Int(($0 * 100).rounded(.down)))%" }
    }

    var summary: String {
        guard totalBytes > 0 || completedBytes > 0 else { return "Connecting…" }
        let completed = ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)
        if totalBytes > completedBytes {
            return "\(completed) of \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
        }
        // The importer also counts reused layers: do not label this as network
        // traffic or derive a download speed from it.
        return "\(completed) ready"
    }

    private func adding(_ bytes: Int64, to value: Int64) -> Int64 {
        guard bytes > 0 else { return value }
        let result = value.addingReportingOverflow(bytes)
        return result.overflow ? .max : result.partialValue
    }
}

actor StartupDownloadReporter {
    private var snapshot = StartupDownload()
    private var lastPublication: ContinuousClock.Instant?
    private var lastPublishedSnapshot: StartupDownload?
    private var pendingPublication: Task<Void, Never>?
    private var finished = false
    private let publish: @MainActor @Sendable (StartupDownload?) -> Void
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        publish: @escaping @MainActor @Sendable (StartupDownload?) -> Void
    ) {
        self.sleep = sleep
        self.publish = publish
    }

    func receive(_ events: [ProgressEvent], now: ContinuousClock.Instant = .now) async {
        guard !finished else { return }
        snapshot.apply(events)
        guard snapshot != lastPublishedSnapshot else { return }
        // Layers arrive concurrently and can report every network buffer.
        // Throttle byte updates, but never delay switching between activity and
        // measured progress. Deliver the trailing update even if callbacks stop.
        let modeChanged = (snapshot.fraction != nil) != (lastPublishedSnapshot?.fraction != nil)
        if let lastPublication, !modeChanged, now - lastPublication < .milliseconds(200) {
            if pendingPublication == nil {
                let delay = Duration.milliseconds(200) - (now - lastPublication)
                pendingPublication = Task { [weak self, sleep] in
                    do { try await sleep(delay) } catch { return }
                    guard !Task.isCancelled else { return }
                    await self?.publishPending()
                }
            }
            return
        }
        await publishCurrent(now: now)
    }

    private func publishPending() async {
        guard !finished, snapshot != lastPublishedSnapshot else { return }
        await publishCurrent(now: .now)
    }

    private func publishCurrent(now: ContinuousClock.Instant) async {
        pendingPublication?.cancel()
        pendingPublication = nil
        lastPublication = now
        lastPublishedSnapshot = snapshot
        await publish(snapshot)
    }

    func finish() async {
        guard !finished else { return }
        finished = true
        pendingPublication?.cancel()
        pendingPublication = nil
        await publish(nil)
    }

    static func track<Value: Sendable>(
        publish: @escaping @MainActor @Sendable (StartupDownload?) -> Void,
        operation: @Sendable (@escaping ProgressHandler) async throws -> Value
    ) async throws -> Value {
        let reporter = StartupDownloadReporter(publish: publish)
        await publish(StartupDownload())
        do {
            let value = try await operation { await reporter.receive($0) }
            await reporter.finish()
            return value
        } catch {
            await reporter.finish()
            throw error
        }
    }
}
