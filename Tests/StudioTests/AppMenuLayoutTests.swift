import AppKit
import Testing
@testable import Studio

@Test @MainActor func updateCommandIsPlacedImmediatelyBelowSettings() {
    let menu = NSMenu()
    menu.addItem(withTitle: "About Studio", action: nil, keyEquivalent: "")
    menu.addItem(withTitle: "Check for Updates…", action: nil, keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Settings…", action: nil, keyEquivalent: ",")
    menu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")

    AppMenuLayout.placeUpdateCommandBelowSettings(in: menu)

    let settingsIndex = menu.items.firstIndex(where: { $0.title == "Settings…" })
    let updateIndex = menu.items.firstIndex(where: { $0.title == "Check for Updates…" })
    #expect(updateIndex == settingsIndex.map { $0 + 1 })
}

@Test @MainActor func menuOrderingIsIdempotent() {
    let menu = NSMenu()
    menu.addItem(withTitle: "Settings…", action: nil, keyEquivalent: ",")
    let updateItem = menu.addItem(withTitle: "Check for Updates…", action: nil, keyEquivalent: "")

    AppMenuLayout.placeUpdateCommandBelowSettings(in: menu)
    AppMenuLayout.placeUpdateCommandBelowSettings(in: menu)

    #expect(menu.items.count == 2)
    #expect(menu.items[1] === updateItem)
}
