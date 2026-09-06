import AppKit

struct WebConfirmation {
    enum Kind { case leavePage, javascript }
    let kind: Kind
    let origin: String
    let message: String
}

/// Owns WebKit's pending reply. A page being dismantled, a duplicate callback,
/// or a missing parent window must never silently approve a destructive action.
@MainActor
final class WebConfirmationController {
    typealias Presenter = @MainActor (NSWindow?, WebConfirmation, @escaping (Bool) -> Void) -> (() -> Void)
    private let presenter: Presenter
    var onActivityChanged: (Bool) -> Void = { _ in }
    private var pending: (id: UUID, reply: (Bool) -> Void, cancel: (() -> Void)?)?

    init(presenter: @escaping Presenter = WebConfirmationController.presentSheet) {
        self.presenter = presenter
    }

    func request(_ request: WebConfirmation, in window: NSWindow?, reply: @escaping (Bool) -> Void) {
        guard pending == nil else { reply(false); return }
        let id = UUID()
        pending = (id, reply, nil)
        onActivityChanged(true)
        let cancel = presenter(window, request) { [weak self] answer in
            guard let self, self.pending?.id == id else { return }
            let completion = self.pending!.reply
            self.pending = nil
            self.onActivityChanged(false)
            completion(answer)
        }
        if pending?.id == id { pending?.cancel = cancel }
    }

    func cancelPending() {
        guard let request = pending else { return }
        pending = nil
        onActivityChanged(false)
        request.cancel?()
        request.reply(false)
    }

    static func makeAlert(_ request: WebConfirmation) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch request.kind {
        case .leavePage:
            alert.messageText = "Leave this page?"
            alert.informativeText = "Changes you made on \(request.origin) may not be saved."
            alert.addButton(withTitle: "Stay on Page")
            alert.addButton(withTitle: "Leave Page")
        case .javascript:
            alert.messageText = "Message from \(request.origin)"
            alert.informativeText = String(request.message.prefix(2_000))
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "OK")
        }
        // Return chooses the non-destructive answer; the sheet handles Escape
        // explicitly rather than relying on AppKit's button-title heuristics.
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        return alert
    }

    private static func presentSheet(_ window: NSWindow?, _ request: WebConfirmation, reply: @escaping (Bool) -> Void) -> () -> Void {
        guard let window, window.isVisible, window.attachedSheet == nil else { reply(false); return {} }
        let alert = makeAlert(request)
        let escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.window === alert.window, event.keyCode == 53 {
                window.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
                return nil
            }
            return event
        }
        alert.beginSheetModal(for: window) { response in
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            reply(response == .alertSecondButtonReturn)
        }
        return { [weak window] in
            if alert.window.sheetParent != nil {
                window?.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
            }
        }
    }
}
