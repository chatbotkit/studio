import Foundation
import Testing
@testable import StudioConfiguration

private func document(_ environment: String) -> String {
    "services:\n  platform:\n    environment:\n" + environment.split(separator: "\n", omittingEmptySubsequences: false).map { "      " + $0 }.joined(separator: "\n")
}

struct ComposeReference: Decodable {
    let environments: [String: [String: String]]
    let manifest: StackManifest
}

func studioFixture() throws -> String {
    let path = try #require(Bundle.module.url(forResource: "studio-compose", withExtension: "yml", subdirectory: "Fixtures"))
    return try String(contentsOf: path, encoding: .utf8)
}

@Test func studioArtifactEnvironmentMatchesComposeDefaults() throws {
    let yaml = try studioFixture()
    for native in [false, true] {
        let result = try native
            ? PrivateStackEnvironment.load(yaml, sitePort: 31000, relayPort: 31001, storagePort: 31900)
            : ComposeEnvironment.loadStack(yaml)
        let name = native ? "docker-compose-native" : "docker-compose-environment"
        let path = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        let reference = try JSONDecoder().decode(ComposeReference.self, from: Data(contentsOf: path))
        #expect(result.environments.mapValues(\.values) == reference.environments)
        #expect(result.manifest == reference.manifest)
        let garage = try GarageConfiguration.extract(from: yaml, variables: ["STORAGE_PORT": "31900"])
        #expect(garage.s3Port == 31900)
        #expect(garage.configuration.contains("[::]:31900"))
    }
}

@Test func explicitEmptyTrustedSignInIsPreserved() throws {
    let yaml = document("NEXTAUTH_TRUSTED_SIGNIN: ${NEXTAUTH_TRUSTED_SIGNIN-true}\nEMPTY: ''\nFALLBACK: ${EMPTY:-fallback}")
    let env = try #require(ComposeEnvironment.load(yaml, variables: ["NEXTAUTH_TRUSTED_SIGNIN": "", "EMPTY": ""])["platform"])
    #expect(env.values["NEXTAUTH_TRUSTED_SIGNIN"] == "")
    #expect(env.values["EMPTY"] == "")
    #expect(env.values["FALLBACK"] == "fallback")
}

@Test func nullAndBareVariablesRemoveImageDefaultsWithoutHostInheritance() throws {
    for yaml in [document("HOME:\nEMPTY: ''\nKEEP: changed"), document("- HOME\n- EMPTY=\n- KEEP=changed")] {
        let env = try #require(ComposeEnvironment.load(yaml)["platform"])
        #expect(env.merging(imageEnvironment: ["HOME=/root", "EMPTY=old", "KEEP=old", "PATH=/bin"]) == ["EMPTY=", "KEEP=changed", "PATH=/bin"])
    }
}

@Test func yamlAnchorsAndMergePrecedenceWork() throws {
    let yaml = """
    x-first: &first {A: first, B: first}
    x-second: &second {A: second, C: second}
    services:
      platform:
        environment:
          <<: [*first, *second]
          B: local
          NUMBER: 3000
          BOOL: true
          QUOTED: 'a: b # not a comment'
          ESCAPED: $$HOME
    """
    let env = try #require(ComposeEnvironment.load(yaml)["platform"])
    #expect(env.values == ["A": "first", "B": "local", "C": "second", "NUMBER": "3000", "BOOL": "true", "QUOTED": "a: b # not a comment", "ESCAPED": "$HOME"])
    #expect(try ComposeEnvironment.load(yaml.replacingOccurrences(of: "\n", with: "\r\n")) == ["platform": env])
}

@Test(arguments: ["A: one\nA: two", "- A=one\n- A=two", "A: [one, two]", "A: {nested: no}", "A: ${REQUIRED:?secret}", "<<: *missing", "'=bad': x"])
func malformedEnvironmentsFailClosed(_ text: String) {
    #expect(throws: ConfigurationError.self) { try ComposeEnvironment.load(document(text)) }
}

@Test(arguments: ["env_file: private.env", "extends: platform"])
func externalComposeEnvironmentSourcesAreRejected(_ field: String) {
    #expect(throws: ConfigurationError.self) { try ComposeEnvironment.load("services:\n  platform:\n    \(field)") }
}

@Test func duplicateServicesAndExtraDocumentsAreRejected() {
    #expect(throws: ConfigurationError.self) { try ComposeEnvironment.load("services:\n  platform: {}\n  platform: {}") }
    #expect(throws: ConfigurationError.self) { try ComposeEnvironment.load("services: {}\n---\nservices: {}") }
}

@Test(arguments: ["0", "65536", "-1", "+9000", "abc", "", " 9000"])
func invalidInternalPortsAreRejected(_ value: String) throws {
    let yaml = try studioFixture()
    for field in ["      PORT: ${PLATFORM_PORT:-31000}", "      RELAY_PORT: ${RELAY_PORT:-31001}"] {
        #expect(yaml.contains(field))
        #expect(throws: ConfigurationError.self) { try PrivateStackEnvironment.load(yaml.replacingOccurrences(of: field, with: field.components(separatedBy: ":")[0] + ": '\(value)'"), sitePort: 31000, relayPort: 31001, storagePort: 31900) }
    }
}
