import Foundation

enum WebPageState: Equatable { case loading, ready, failed(String) }

@MainActor
final class WebPageLoad {
    private var generation = UUID()
    private var timeout: Task<Void, Never>?
    private var settled: Task<Void, Never>?
    private var paused = false
    private var finishedDocument = false
    private(set) var state: WebPageState = .loading
    private let deadline: Duration
    private let settleDelay: Duration
    private let changed: @MainActor (WebPageState) -> Void

    init(deadline: Duration = .seconds(30), settleDelay: Duration = .milliseconds(120), changed: @escaping @MainActor (WebPageState) -> Void) {
        self.deadline = deadline; self.settleDelay = settleDelay; self.changed = changed
    }

    func begin() {
        invalidate()
        finishedDocument = false
        publish(.loading)
        guard !paused else { return }
        let run = generation
        timeout = Task { [weak self, deadline] in
            do { try await Task.sleep(for: deadline) } catch { return }
            guard let self, self.generation == run else { return }
            self.fail("The page took too long to load. Your stack is still running; reload the page to try again.")
        }
    }

    func documentFinished() {
        guard state == .loading else { return }
        finishedDocument = true
        // Once WebKit has finished the document, the loading deadline must not
        // race the visual settling task (especially while native sheets animate).
        timeout?.cancel(); timeout = nil
        guard !paused else { return }
        settled?.cancel()
        let run = generation
        // didFinish is a document signal, independent of page brightness. Give
        // WebKit a short settling interval, not repeated full-page snapshots.
        settled = Task { [weak self, settleDelay] in
            do { try await Task.sleep(for: settleDelay) } catch { return }
            guard let self, self.generation == run else { return }
            self.timeout?.cancel()
            self.publish(.ready)
        }
    }

    func fail(_ message: String) {
        invalidate()
        publish(.failed(String(message.prefix(1_024))))
    }

    func setConfirmationActive(_ active: Bool) {
        guard paused != active else { return }
        paused = active
        if active {
            timeout?.cancel(); timeout = nil
            settled?.cancel(); settled = nil
        } else if state == .loading {
            let finished = finishedDocument
            begin()
            if finished { documentFinished() }
        }
    }

    func invalidate() {
        generation = UUID()
        timeout?.cancel(); timeout = nil
        settled?.cancel(); settled = nil
    }

    private func publish(_ state: WebPageState) { self.state = state; changed(state) }
}
