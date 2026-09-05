import AppKit
import Testing
@testable import Studio

@Test @MainActor func consoleAppendKeepsMultiLineSelection() {
    let view = NSTextView()
    view.isEditable = false
    view.isSelectable = true
    let coordinator = NativeConsoleView.Coordinator()
    var entries = [ContainerLogEntry(service: "redis", message: "first"), ContainerLogEntry(service: "redis", message: "second")]
    coordinator.update(textView: view, entries: entries, streamKey: "all", followsOutput: false)
    let original = view.string
    let selection = NSRange(location: 0, length: (original as NSString).length)
    view.setSelectedRange(selection)
    entries.append(.init(service: "platform", message: "third 👋"))
    coordinator.update(textView: view, entries: entries, streamKey: "all", followsOutput: false)
    #expect(view.string.hasPrefix(original))
    #expect(view.string.hasSuffix("third 👋\n"))
    #expect(view.selectedRange() == selection)
}

@Test @MainActor func consoleSwitchesSourceAndHandlesRetentionAndClear() {
    let view = NSTextView()
    let coordinator = NativeConsoleView.Coordinator()
    let first = ContainerLogEntry(service: "redis", message: "first-marker")
    let second = ContainerLogEntry(service: "platform", message: "second-marker")
    coordinator.update(textView: view, entries: [first, second], streamKey: "all", followsOutput: false)
    coordinator.update(textView: view, entries: [second], streamKey: "platform", followsOutput: false)
    #expect(!view.string.contains("first-marker"))
    #expect(view.string.contains("second-marker"))
    let third = ContainerLogEntry(service: "platform", message: "third-marker")
    coordinator.update(textView: view, entries: [third], streamKey: "platform", followsOutput: false)
    #expect(!view.string.contains("second-marker"))
    #expect(view.string.contains("third-marker"))
    coordinator.update(textView: view, entries: [], streamKey: "platform", followsOutput: false)
    #expect(view.string.isEmpty)
}

@Test @MainActor func consoleUnchangedUpdateDoesNotDuplicateText() {
    let view = NSTextView()
    let coordinator = NativeConsoleView.Coordinator()
    let entries = [ContainerLogEntry(service: "platform", message: "message")]
    coordinator.update(textView: view, entries: entries, streamKey: "all", followsOutput: false)
    let original = view.string
    for _ in 0..<10 {
        coordinator.update(textView: view, entries: entries, streamKey: "all", followsOutput: false)
    }
    #expect(view.string == original)
}
