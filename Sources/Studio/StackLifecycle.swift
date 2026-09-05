import Foundation

/// The model owns a single lifecycle task. Tests supply an in-memory runtime,
/// never the production kernel, network, image store, or persistent volumes.
protocol StackRuntime: Sendable {
    func start(kernelURL: URL, dataRoot: URL, event: @escaping @MainActor @Sendable (RuntimeEvent) -> Void) async throws -> StackInfo
    func stop() async throws -> [String]
}

enum GracefulShutdown {
    // Clients and initializers must finish before their storage dependencies.
    static let order = ["platform", "garage-init", "db-init", "garage", "qdrant", "redis", "network-init"]

    static func run(
        started: Set<String>,
        terminate: @Sendable (String) async throws -> Void,
        wait: @Sendable (String, Int64) async throws -> Void,
        force: @Sendable (String) async throws -> Void,
        teardown: @Sendable () async throws -> Void
    ) async throws -> [String] {
        var warnings: [String] = []
        for name in order where started.contains(name) {
            do {
                try await terminate(name)
                try await wait(name, 10)
            } catch {
                warnings.append("\(name) could not finish graceful shutdown; forcing it to stop: \(error.localizedDescription)")
                do {
                    // Do not shut down databases while a timed-out client can
                    // still write to them. Confirm it has stopped first.
                    try await force(name)
                    try await wait(name, 2)
                } catch {
                    warnings.append("\(name) could not be confirmed stopped; falling back to immediate VM teardown: \(error.localizedDescription)")
                    break
                }
            }
        }
        do {
            // Final resource cleanup (and fallback for unresponsive services).
            try await teardown()
        } catch {
            throw AppRuntimeError((warnings + ["Private VM teardown failed: \(error.localizedDescription)"]).joined(separator: "\n"))
        }
        return warnings
    }
}

enum ScopedProbe {
    static func run<Value: Sendable>(
        operation: () async throws -> Value,
        cleanup: @escaping @Sendable (Bool) async throws -> Void
    ) async throws -> Value {
        let outcome: Result<Value, Error>
        do { outcome = .success(try await operation()) }
        catch { outcome = .failure(error) }
        let failed: Bool
        switch outcome { case .success: failed = false; case .failure: failed = true }
        do {
            // Cancellation of the probe must not cancel resource cleanup.
            try await Task { try await cleanup(failed) }.value
        } catch {
            let original: String
            switch outcome {
            case .success: original = ""
            case .failure(let failure): original = "\(failure.localizedDescription); "
            }
            throw AppRuntimeError("\(original)probe cleanup failed: \(error.localizedDescription)")
        }
        return try outcome.get()
    }
}
