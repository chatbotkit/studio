import AppKit
import Testing
@testable import Studio

@MainActor private final class SettingsTabsFixture: NSObject, NSToolbarDelegate {
    let identifiers = ["Models", "Storage", "Update"].map { NSToolbarItem.Identifier($0) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = identifier.rawValue
        item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        // Settings tabs are clickable, which is what makes AppKit give them buttons.
        item.target = self
        item.action = #selector(select(_:))
        return item
    }
    @objc func select(_ sender: Any?) {}
}

@MainActor private func badges(in window: NSWindow) -> [SettingsTabBadge.CountView] {
    var found: [SettingsTabBadge.CountView] = []
    func collect(_ view: NSView) {
        if let badge = view as? SettingsTabBadge.CountView { found.append(badge) }
        view.subviews.forEach(collect)
    }
    window.contentView?.superview.map(collect)
    return found
}

@Test @MainActor func settingsTabBadgesSitOnTheirTabsFollowTheCountsAndLeaveWithTheView() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 480, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let tabs = SettingsTabsFixture()
    let toolbar = NSToolbar(identifier: "SettingsTabBadgeTests")
    toolbar.delegate = tabs
    toolbar.displayMode = .iconAndLabel
    window.toolbar = toolbar
    window.toolbarStyle = .preference
    // The toolbar only builds its buttons once the window is ordered in (still offscreen).
    window.orderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    let buttons = SettingsTabBadge.BadgeView.tabButtons(in: window)
    #expect(Set(buttons.keys) == ["Models", "Storage", "Update"])
    let positions = ["Models", "Storage", "Update"].compactMap { buttons[$0] }.map { $0.convert($0.bounds, to: nil).minX }
    #expect(positions == positions.sorted(), "Buttons pair with items in leading-to-trailing order")

    let view = SettingsTabBadge.BadgeView()
    // The app and the stack can both be pending, so Update may show 2.
    view.counts = ["Update": 2, "Storage": 12, "Models": 0, "Missing": 4]
    window.contentView?.addSubview(view)
    let shown = badges(in: window)
    #expect(shown.count == 2)
    let update = try #require(shown.first { $0.superview === buttons["Update"] })
    let storage = try #require(shown.first { $0.superview === buttons["Storage"] })
    #expect(update.accessibilityLabel() == "2")
    #expect(update.frame.size == NSSize(width: 12, height: 12))
    #expect(storage.frame.width > 12, "Two digits widen the badge")
    let button = try #require(buttons["Update"])
    #expect(update.frame.maxX == button.bounds.maxX)
    #expect((button.isFlipped ? update.frame.minY : update.frame.maxY) == (button.isFlipped ? 0 : button.bounds.maxY))
    #expect(update.hitTest(NSPoint(x: 1, y: 1)) == nil, "Clicks pass through to the tab")

    // A changed count keeps the same view, so nothing is rebuilt.
    view.counts["Update"] = 1
    view.apply()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    #expect(badges(in: window).contains { $0 === update })
    #expect(update.accessibilityLabel() == "1")

    view.counts["Update"] = 0
    view.apply()
    #expect(badges(in: window).count == 1)
    // A badge removed behind our back returns before the run loop sleeps.
    storage.removeFromSuperview()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    #expect(badges(in: window).count == 1)

    view.removeFromSuperview()
    #expect(badges(in: window).isEmpty)
}

@Test func updateButtonOffersTheInstallOnceAnUpdateIsFound() {
    #expect(UpdateSettingsButton.title(availableVersion: nil) == "Check for Updates…")
    #expect(UpdateSettingsButton.title(availableVersion: "0.16.0") == "Install Update…")
}

@Test func stackDigestsAreShortenedForSettingsRows() {
    #expect(StackUpdatePreferences.short("sha256:0123456789abcdef0123456789abcdef") == "0123456789ab")
    #expect(StackUpdatePreferences.short("fixture") == "fixture")
}
