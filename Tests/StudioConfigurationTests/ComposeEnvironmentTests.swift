import Foundation
import Testing
@testable import StudioConfiguration

private func document(_ environment: String) -> String {
    "services:\n  platform:\n    environment:\n" + environment.split(separator: "\n", omittingEmptySubsequences: false).map { "      " + $0 }.joined(separator: "\n")
}

@Test func studioArtifactEnvironmentMatchesComposeDefaults() throws {
    let path = try #require(Bundle.module.url(forResource: "studio-compose", withExtension: "yml", subdirectory: "Fixtures"))
    let yaml = try String(contentsOf: path, encoding: .utf8)
    let docker = try ComposeEnvironment.load(yaml)
    let expectedPath = try #require(Bundle.module.url(forResource: "docker-compose-environment", withExtension: "json", subdirectory: "Fixtures"))
    let expected = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: expectedPath))
    #expect(docker.mapValues(\.values) == expected)
    let native = try PrivateStackEnvironment.load(yaml, hostPort: 3010)
    #expect(native.count == 6)
    let platform = try #require(native["platform"])
    #expect(platform.values["NEXTAUTH_TRUSTED_SIGNIN"] == "true")
    #expect(platform.values["SANDBOX_DATA_DIR"] == "/data/sandbox")
    #expect(platform.values["CLOAK_ENCRYPTION_KEY"] == "")
    #expect(platform.values["STORAGE_REGION"] == "garage")
    #expect(platform.values["STORAGE_FORCE_PATH_STYLE"] == "true")
    #expect(platform.values["SITE_URL"] == "http://127.0.0.1:3010")
    #expect(platform.values["NEXTAUTH_URL"] == platform.values["SITE_URL"])
    #expect(platform.values["STORAGE_ENDPOINT"] == "http://127.0.0.1:3900")
    #expect(platform.values["RELAY_URL"] == "http://127.0.0.1:3001")
    #expect(platform.values["APP_MAIN_ORIGIN"] == "http://cbk-apps.localhost:3010")
    #expect(native["garage"]?.values["RUST_LOG"] == "warn")
    #expect(native["garage-init"]?.values["GARAGE_S3_URL"] == "http://garage:3900")
    let topology = Set(["SITE_URL", "NEXTAUTH_URL", "STORAGE_ENDPOINT", "RELAY_URL", "APP_MAIN_ORIGIN", "APP_LABS_ORIGIN"])
    for (service, environment) in docker {
        #expect(environment.values.filter { !topology.contains($0.key) } == native[service]?.values.filter { !topology.contains($0.key) })
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

@Test func incompatibleNativePortsAreRejected() {
    #expect(throws: ConfigurationError.self) { try PrivateStackEnvironment.load(document("PORT: 8000"), hostPort: 3000) }
    #expect(throws: ConfigurationError.self) { try PrivateStackEnvironment.load(document("PORT: 3000\nRELAY_PORT: 8001"), hostPort: 3000) }
}
