import Testing
@testable import Studio

@Test func workspaceShortcutsUseDedicatedHostsAtTheirRoots() {
    #expect(WorkspaceDestination.labs.menuTitle == "Open Labs")
    #expect(WorkspaceDestination.apps.menuTitle == "Open Apps")
    #expect(WorkspaceDestination.labs.url(port: 3000)?.absoluteString == "http://cbk-labs.localhost:3000/")
    #expect(WorkspaceDestination.apps.url(port: 3000)?.absoluteString == "http://cbk-apps.localhost:3000/")
}

@Test func workspaceShortcutsFollowTheRunningStacksPublishedPort() {
    for destination in WorkspaceDestination.allCases {
        #expect(destination.url(port: 3007)?.port == 3007)
        #expect(destination.url(port: 3007)?.path == "/")
        #expect(destination.url(port: 0) == nil)
        #expect(destination.url(port: 65536) == nil)
    }
}
