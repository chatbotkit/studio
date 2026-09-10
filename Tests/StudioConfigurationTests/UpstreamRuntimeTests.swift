import Foundation
import Testing
@testable import StudioConfiguration

private func resolvedRuntime(_ yaml: String, site: UInt16 = 31000, relay: UInt16 = 31001, storage: UInt16 = 31900) throws -> (ResolvedStackConfiguration, GarageConfiguration.Resolved) {
    let result = try PrivateStackEnvironment.load(yaml, sitePort: site, relayPort: relay, storagePort: storage)
    let garage = try GarageConfiguration.extract(from: yaml, variables: PrivateStackEnvironment.variables(sitePort: site, relayPort: relay, storagePort: storage))
    return (result, garage)
}

@Test func currentPublishedStackDrivesBridgeAndHealthChecks() throws {
    let (result, garage) = try resolvedRuntime(studioFixture())
    #expect(try result.bridgePorts(garage: garage) == [31000, 31001, 31900])
    #expect(try result.healthCheck(for: "platform") == ["node", "-e", "fetch('http://localhost:' + process.env.PORT + '/').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"])
    #expect(try result.healthCheck(for: "redis") == ["redis-cli", "ping"])
    #expect(try result.healthCheck(for: "qdrant") == ["/bin/sh", "-c", "bash -c \": > /dev/tcp/127.0.0.1/6333\" || exit 1"])
    #expect(try result.healthCheck(for: "garage") == ["/garage", "-c", "/etc/garage.toml", "status"])
}

@Test func upstreamCanChangeAllListenerPortsWithoutDesktopDefaults() throws {
    let yaml = try studioFixture().replacingOccurrences(of: "[::]:3903", with: "[::]:9003")
    let (result, garage) = try resolvedRuntime(yaml, site: 9000, relay: 9001, storage: 9002)
    #expect(try result.bridgePorts(garage: garage) == [9000, 9001, 9002])
    #expect(garage.adminPort == 9003)
    #expect(result.environments["platform"]?.values["PORT"] == "9000")
    #expect(result.manifest.url(for: "apps")?.port == 9000)
}

@Test func fixedUpstreamInternalPortsNeedNotEqualPublishedPorts() throws {
    // The previous artifact used fixed listeners; they remain valid when
    // explicitly declared, but are never fallback values in the desktop app.
    let yaml = try studioFixture()
        .replacingOccurrences(of: "      PORT: ${PLATFORM_PORT:-31000}", with: "      PORT: 3000")
        .replacingOccurrences(of: "      RELAY_PORT: ${RELAY_PORT:-31001}", with: "      RELAY_PORT: 3001")
    let (result, garage) = try resolvedRuntime(yaml, site: 31002)
    #expect(try result.bridgePorts(garage: garage) == [3000, 3001, 31900])
    #expect(result.manifest.url(for: "site")?.port == 31002)
}

@Test(arguments: ["      PORT: ${PLATFORM_PORT:-31000}", "      RELAY_PORT: ${RELAY_PORT:-31001}"])
func missingInternalPortDoesNotFallBack(_ field: String) throws {
    let yaml = try studioFixture().replacingOccurrences(of: field, with: "")
    #expect(throws: ConfigurationError.self) { try resolvedRuntime(yaml) }
}

@Test(arguments: ["31000", "31900", "3903"])
func realInternalListenerCollisionsAreRejected(_ relay: String) throws {
    let yaml = try studioFixture().replacingOccurrences(of: "      RELAY_PORT: ${RELAY_PORT:-31001}", with: "      RELAY_PORT: \(relay)")
    #expect(throws: ConfigurationError.self) {
        let (result, garage) = try resolvedRuntime(yaml)
        _ = try result.bridgePorts(garage: garage)
    }
}

@Test(arguments: [3000, 3001, 3903])
func storageHasNoHistoricalPortBlacklist(_ port: UInt16) throws {
    let yaml = try studioFixture().replacingOccurrences(of: "[::]:3903", with: "[::]:9003")
    let (result, garage) = try resolvedRuntime(yaml, storage: port)
    #expect(try result.bridgePorts(garage: garage) == [31000, 31001, port])
}

@Test func garageAdminAndStorageCannotShareAListener() throws {
    let yaml = try studioFixture().replacingOccurrences(of: "[::]:3903", with: "[::]:31900")
    #expect(throws: ConfigurationError.self) { try resolvedRuntime(yaml) }
}

private func withRedisHealth(_ test: String) throws -> String {
    try studioFixture().replacingOccurrences(of: "['CMD', 'redis-cli', 'ping']", with: test)
}

@Test func healthChecksPreserveContainerExpansionAndArgumentBoundaries() throws {
    let exec = try ComposeEnvironment.loadStack(withRedisHealth("['CMD', 'probe', 'one argument', '${PROBE:-default}', '$$PORT']"), variables: ["PROBE": "9000"])
    #expect(try exec.healthCheck(for: "redis") == ["probe", "one argument", "9000", "$PORT"])
    for test in ["['CMD-SHELL', 'probe $$PORT']", "'probe $$PORT'"] {
        let shell = try ComposeEnvironment.loadStack(withRedisHealth(test))
        #expect(try shell.healthCheck(for: "redis") == ["/bin/sh", "-c", "probe $PORT"])
    }
}

@Test(arguments: ["[]", "['NONE']", "['CMD']", "['CMD', '']", "['CMD-SHELL', '']", "['CMD-SHELL', 'one', 'two']", "['OTHER', 'command']", "null", "{}", "''", "['CMD', {}]"])
func malformedHealthChecksFailBeforeLaunch(_ test: String) throws {
    #expect(throws: ConfigurationError.self) { try ComposeEnvironment.loadStack(withRedisHealth(test)) }
}

@Test func missingOrDisabledRequiredHealthChecksDoNotUseNativeDefaults() throws {
    let yaml = try studioFixture()
    let disabled = yaml.replacingOccurrences(of: "test: ['CMD', 'redis-cli', 'ping']", with: "disable: true")
    #expect(throws: ConfigurationError.self) { try ComposeEnvironment.loadStack(disabled) }
    let missing = try ComposeEnvironment.loadStack(yaml.replacingOccurrences(of: "    healthcheck:", with: "    x-healthcheck:"))
    #expect(throws: ConfigurationError.self) { try missing.healthCheck(for: "redis") }
}
