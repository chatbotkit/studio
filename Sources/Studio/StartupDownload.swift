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
    private var finished = false
    private let publish: @MainActor @Sendable (StartupDownload?) -> Void

    init(publish: @escaping @MainActor @Sendable (StartupDownload?) -> Void) {
        self.publish = publish
    }

    func receive(_ events: [ProgressEvent], now: ContinuousClock.Instant = .now) async {
        guard !finished else { return }
        snapshot.apply(events)
        // Layers arrive concurrently and can report every network buffer.
        // Aggregate off the main actor and update the UI at most five times/sec.
        if let lastPublication, now - lastPublication < .milliseconds(200) { return }
        lastPublication = now
        await publish(snapshot)
    }

    func finish() async {
        guard !finished else { return }
        finished = true
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
