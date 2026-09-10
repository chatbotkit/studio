import Foundation
import Testing
@testable import StudioConfiguration

@Test(arguments: ["null", "[]", "unexpected", "{version: 1, endpoints: [], apexes: {}}"])
func malformedManifestTypesNameTheProblem(_ value: String) throws {
    do {
        _ = try ComposeEnvironment.loadStack("x-cbk: \(value)\nservices: {}")
        Issue.record("Expected a malformed manifest")
    } catch {
        #expect(error is ConfigurationError)
        #expect(error.localizedDescription.contains("endpoint manifest"))
    }
}

@Test(arguments: [
    ("x-cbk:", "x-other:", "missing"),
    ("  version: 1", "  version: 2", "version"),
    ("    labs:", "    other:", "labs"),
    ("    space:", "    other:", "space"),
    ("      variable: SITE_URL", "      variable: NOT_SITE_URL", "variable"),
    ("      service: garage", "      service: absent", "service"),
    ("      service: platform", "      service: redis", "service")
])
func invalidManifestShapeFailsClosed(_ change: (String, String, String)) throws {
    let yaml = try studioFixture().replacingOccurrences(of: change.0, with: change.1)
    do {
        _ = try ComposeEnvironment.loadStack(yaml)
        Issue.record("Expected an invalid manifest")
    } catch {
        #expect(error is ConfigurationError)
        #expect(error.localizedDescription.lowercased().contains(change.2))
    }
}

@Test(arguments: ["https://cbk.localhost:31000", "http://example.com:31000", "http://localhost", "http://127.0.0.2:31000", "http://localhost:9000", "http://private:secret@localhost:31000", "http://evil.localhost.example.com:31000", "http://localhost:31000/#private-secret", "http://%6cocalhost:31000"])
func manifestRejectsUnsafeOrMismatchedURL(_ url: String) throws {
    do {
        _ = try ComposeEnvironment.loadStack(studioFixture(), variables: ["SITE_URL": url])
        Issue.record("Expected an invalid endpoint")
    } catch {
        #expect(error is ConfigurationError)
        #expect(!error.localizedDescription.contains("private-secret"))
        #expect(!error.localizedDescription.contains(url))
    }
}

@Test(arguments: ["localhost", "https://space.localhost", "space.localhost:31000", "space.localhost/path", "*.space.localhost", "space..localhost", "space.localhost.", "-space.localhost", "space.localhost.example.com"])
func manifestRejectsMalformedApex(_ apex: String) throws {
    #expect(throws: ConfigurationError.self) { try ComposeEnvironment.loadStack(studioFixture(), variables: ["SPACE_APEX": apex]) }
}

@Test(arguments: ["0", "65536", "-1", "abc", "31001", "31900"])
func manifestRejectsInvalidOrCollidingPublishedPorts(_ port: String) throws {
    #expect(throws: ConfigurationError.self) { try ComposeEnvironment.loadStack(studioFixture(), variables: ["PLATFORM_PORT": port]) }
}

@Test func allocatedPortsMustMatchTheManifest() throws {
    let manifest = try ComposeEnvironment.loadStack(studioFixture()).manifest
    #expect(try manifest.preferredPorts == StackPorts(site: 31000, relay: 31001, storage: 31900))
    #expect(throws: ConfigurationError.self) { try manifest.validate(ports: .init(site: 31002, relay: 31001, storage: 31900)) }
}

@Test func fallbackPortPropagatesWithoutChangingAuxiliaryPortsOrContainerPorts() throws {
    let yaml = try studioFixture().replacingOccurrences(of: "cbk-apps.localhost", with: "custom-apps.localhost")
    let resolved = try PrivateStackEnvironment.load(yaml, sitePort: 31002, relayPort: 31001, storagePort: 31900)
    let platform = try #require(resolved.environments["platform"]?.values)
    #expect(platform["SITE_URL"] == "http://127.0.0.1:31002")
    #expect(platform["NEXTAUTH_URL"] == platform["SITE_URL"])
    #expect(platform["APP_MAIN_ORIGIN"] == "http://custom-apps.localhost:31002")
    #expect(platform["RELAY_URL"] == "http://127.0.0.1:31001")
    #expect(platform["STORAGE_ENDPOINT"] == "http://127.0.0.1:31900")
    #expect(platform["PORT"] == "3000")
    #expect(platform["RELAY_PORT"] == "3001")
    #expect(resolved.environments["garage-init"]?.values["GARAGE_S3_URL"] == "http://garage:31900")
    #expect(resolved.manifest.url(for: "apps")?.host == "custom-apps.localhost")
    #expect(resolved.manifest.hosts.contains("cbk-space.localhost"))
    #expect(!resolved.manifest.hosts.contains("cbk-apps.localhost"))
}

@Test func garageMustBindTheAllocatedStoragePort() throws {
    let yaml = try studioFixture()
    let vars = PrivateStackEnvironment.variables(sitePort: 31002, relayPort: 31001, storagePort: 32000)
    #expect(try GarageConfiguration.extract(from: yaml, variables: vars).s3Port == 32000)
    #expect(throws: ConfigurationError.self) { try GarageConfiguration.extract(from: yaml.replacingOccurrences(of: "[::]:${STORAGE_PORT:-31900}", with: "[::]:31901"), variables: vars) }
    #expect(throws: ConfigurationError.self) { try GarageConfiguration.extract(from: yaml.replacingOccurrences(of: "[::]:3903", with: "[::]:3904"), variables: vars) }
}

@Test func manifestOriginsAreBoundToDeclaredHostsPortsAndApexBoundaries() throws {
    let manifest = try PrivateStackEnvironment.load(studioFixture(), sitePort: 31000, relayPort: 31001, storagePort: 31900).manifest
    for address in ["http://127.0.0.1:31000/", "http://localhost:31000/", "http://[::1]:31000/", "http://cbk-apps.localhost:31000/", "http://acme.cbk-space.localhost:31000/", "http://one.two.cbk-portal.localhost:31000/"] {
        #expect(manifest.contains(try #require(URL(string: address))))
    }
    for address in ["http://cbk-apps.localhost:3000/", "http://127.0.0.1:9999/", "https://cbk-apps.localhost:31000/", "http://evilcbk-space.localhost:31000/", "http://acme.cbk-space.localhost.evil.com:31000/", "http://undeclared.localhost:31000/"] {
        #expect(!manifest.contains(try #require(URL(string: address))))
    }
}
