import Foundation
import Testing
@testable import StudioConfiguration

@Test(arguments: ["", "plain text", "$", "$5", "$-", "$é", "$$", "$$$$"])
func literalInputNeverReadsHostEnvironment(_ source: String) throws {
    let expected = source.replacingOccurrences(of: "$$", with: "$")
    #expect(try ComposeInterpolation.resolve(source) == expected)
}

@Test func composeValuesAreNotRecursivelyInterpreted() throws {
    #expect(try ComposeInterpolation.resolve("$VALUE", variables: ["VALUE": "${SECRET}/$HOME/$$"]) == "${SECRET}/$HOME/$$")
    #expect(throws: ConfigurationError.self) { try ComposeInterpolation.resolve("$HOME") }
}

@Test func composeOperatorsDistinguishUnsetEmptyAndPresent() throws {
    for (variables, expected) in [
        ([:], "fallback|fallback||"),
        (["V": ""], "fallback|||alternative"),
        (["V": "set"], "set|set|alternative|alternative")
    ] {
        #expect(try ComposeInterpolation.resolve("${V:-fallback}|${V-fallback}|${V:+alternative}|${V+alternative}", variables: variables) == expected)
    }
}

@Test func requiredVariableErrorsDoNotRevealSecretDefaults() {
    do {
        _ = try ComposeInterpolation.resolve("${TOKEN:?private-secret-value}")
        Issue.record("Expected missing required variable")
    } catch {
        #expect(error.localizedDescription.contains("TOKEN"))
        #expect(!error.localizedDescription.contains("private-secret-value"))
    }
}

@Test func nestedDefaultsAndUnusedBranchesAreLazy() throws {
    #expect(try ComposeInterpolation.resolve("${A:-${B:-${C:-done}}}") == "done")
    #expect(try ComposeInterpolation.resolve("${A:+${MISSING:?required}}") == "")
    #expect(try ComposeInterpolation.resolve("${A:-${MISSING:?required}}", variables: ["A": "present"]) == "present")
}

@Test(arguments: ["${", "${1BAD}", "${A:", "${A:=x}", "${A!x}", "${A:-${B:-x}"])
func malformedExpansionsAreRejected(_ source: String) {
    #expect(throws: ConfigurationError.self) { try ComposeInterpolation.resolve(source) }
}

@Test func garageMustNotReadAnotherConfigsContent() {
    let yaml = """
    configs:
      garage-config:
        file: ./garage.toml
      unrelated-config:
        content: |
          [s3_api]
          api_bind_addr = "[::]:3900"
          [admin]
          api_bind_addr = "[::]:3903"
    """
    #expect(throws: ConfigurationError.self) { try GarageConfiguration.extract(from: yaml) }
}

@Test func garageRejectsMissingConfiguration() {
    #expect(throws: ConfigurationError.self) { try GarageConfiguration.extract(from: "services:\n  platform:\n    image: example") }
    #expect(throws: ConfigurationError.self) { try GarageConfiguration.extract(from: "configs:\n  garage-config:\n    content: |\n") }
}

@Test func garageRejectsDuplicateConfigsAndOutOfScopeMarkers() {
    let config = "  garage-config:\n    content: |\n      [s3_api]\n      api_bind_addr = \"[::]:3900\"\n      [admin]\n      api_bind_addr = \"[::]:3903\"\n"
    #expect(throws: ConfigurationError.self) { try GarageConfiguration.extract(from: "configs:\n" + config + config) }
    #expect(throws: ConfigurationError.self) { try GarageConfiguration.extract(from: "configs:\n  other:\n    file: other.toml\nservices:\n" + config) }
}

@Test func garageAcceptsCRLFDocuments() throws {
    let yaml = "configs:\n  garage-config:\n    content: |\n      [s3_api]\n      api_bind_addr = \"[::]:3900\"\n      [admin]\n      api_bind_addr = \"[::]:3903\"\n"
    let expected = try GarageConfiguration.extract(from: yaml)
    let actual = try GarageConfiguration.extract(from: yaml.replacingOccurrences(of: "\n", with: "\r\n"))
    #expect(actual == expected)
}

@Test func startupSummaryChoosesFatalLineAndStripsANSI() {
    let output = "\u{1B}[1;31mFATAL database unavailable\u{1B}[0m\ncleanup finished\n"
    let message = StartupFailure.message(service: "db-init", output: output, fallback: "probe failed")
    #expect(message.hasPrefix("db-init did not become healthy: FATAL database unavailable"))
    #expect(!message.contains("\u{1B}"))
}

@Test func startupSummaryUsesLastMeaningfulLineOrFallback() {
    #expect(StartupFailure.message(service: "redis", output: "first\nlast\n \n", fallback: "fallback").hasPrefix("redis did not become healthy: last"))
    #expect(StartupFailure.message(service: "redis", output: "\n \n", fallback: "fallback", exitCode: 2).hasPrefix("redis exited with code 2: fallback"))
}

@Test func startupSummaryHasBoundedSizeForOneHugeLine() {
    let output = "Error: " + String(repeating: "x", count: 100_000)
    let message = StartupFailure.message(service: "platform", output: output, fallback: "timeout")
    #expect(message.count < 4_096)
}
