import Testing
@testable import Studio

@Test func workspaceShortcutsUseDedicatedHostsAtTheirRoots() throws {
    let manifest = try testStackManifest()
    #expect(WorkspaceDestination.allCases.map(\.menuTitle) == ["Open Apps", "Open Labs"])
    #expect(WorkspaceDestination.labs.menuTitle == "Open Labs")
    #expect(WorkspaceDestination.apps.menuTitle == "Open Apps")
    #expect(WorkspaceDestination.labs.url(manifest: manifest)?.absoluteString == "http://cbk-labs.localhost:31000/")
    #expect(WorkspaceDestination.apps.url(manifest: manifest)?.absoluteString == "http://cbk-apps.localhost:31000/")
}

@Test func workspaceShortcutsFollowTheRunningStacksPublishedPort() throws {
    let manifest = try testStackManifest(sitePort: 31007, appsHost: "custom-apps.localhost")
    #expect(WorkspaceDestination.apps.url(manifest: manifest)?.host == "custom-apps.localhost")
    for destination in WorkspaceDestination.allCases {
        #expect(destination.url(manifest: manifest)?.port == 31007)
        #expect(destination.url(manifest: manifest)?.path == "/")
    }
}
