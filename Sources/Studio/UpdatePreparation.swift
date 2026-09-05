import Foundation
import Combine

/// The installer must never replace Studio while its VM still owns storage.
@MainActor
final class UpdatePreparation: ObservableObject {
    @Published private(set) var waiting = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var install: (() -> Void)?
    private let busy: () -> Bool
    private let shutdown: @MainActor () async -> Bool
    private let pollInterval: Duration
    private let cancelledShutdown: () -> Void
    private let schedule: (@escaping @MainActor () -> Void) -> Void

    init(busy: @escaping () -> Bool, shutdown: @escaping @MainActor () async -> Bool,
         pollInterval: Duration = .seconds(1),
         cancelledShutdown: @escaping () -> Void = {},
         schedule: @escaping (@escaping @MainActor () -> Void) -> Void = { action in
             // Sparkle may enter a nested AppKit termination loop. Release the
             // Swift main-actor queue before invoking its installation handler.
             RunLoop.main.perform { MainActor.assumeIsolated { action() } }
         }) {
        self.busy = busy; self.shutdown = shutdown
        self.pollInterval = pollInterval; self.schedule = schedule
        self.cancelledShutdown = cancelledShutdown
    }

    func prepare(install: @escaping () -> Void) {
        cancel()
        self.install = install
        retry()
    }

    func retry() {
        guard task == nil, install != nil else { return }
        error = nil; waiting = true
        let run = generation
        task = Task { [weak self] in
            guard let self else { return }
            while self.busy() {
                do { try await Task.sleep(for: self.pollInterval) } catch { return }
                guard self.generation == run else { return }
            }
            guard !Task.isCancelled, self.generation == run else { return }
            let stopped = await self.shutdown()
            guard !Task.isCancelled, self.generation == run else {
                if stopped && self.install == nil { self.cancelledShutdown() }
                return
            }
            self.task = nil
            guard stopped else {
                self.waiting = false
                self.error = "Studio could not safely stop its stack. Check Live Logs, then retry installing the update."
                return
            }
            self.schedule { [weak self] in
                guard let self, self.generation == run, let install = self.install else { return }
                self.install = nil; self.waiting = false
                install()
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel(); task = nil
        install = nil; waiting = false; error = nil
    }
}
