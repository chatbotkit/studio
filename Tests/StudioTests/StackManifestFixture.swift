import Foundation
import StudioConfiguration

func testStackManifest(sitePort: UInt16 = 31000, appsHost: String = "cbk-apps.localhost") throws -> StackManifest {
    var yaml = "x-cbk:\n  version: 1\n  endpoints:\n"
    for (name, service, port, variable, host) in [
        ("site", "platform", sitePort, "SITE_URL", "127.0.0.1"),
        ("apps", "platform", sitePort, "APP_MAIN_ORIGIN", appsHost),
        ("labs", "platform", sitePort, "APP_LABS_ORIGIN", "cbk-labs.localhost"),
        ("relay", "platform", UInt16(31001), "RELAY_URL", "127.0.0.1"),
        ("storage", "garage", UInt16(31900), "STORAGE_URL", "127.0.0.1")
    ] {
        yaml += "    \(name): {service: \(service), published: '\(port)', variable: \(variable), url: 'http://\(host):\(port)/'}\n"
    }
    yaml += "  apexes:\n"
    for (name, variable) in [("space", "SPACE_APEX"), ("portal", "PORTAL_APEX")] {
        yaml += "    \(name): {service: platform, published: '\(sitePort)', variable: \(variable), apex: cbk-\(name).localhost}\n"
    }
    yaml += "services:\n  platform: {}\n  garage: {}\n"
    return try ComposeEnvironment.loadStack(yaml).manifest
}
