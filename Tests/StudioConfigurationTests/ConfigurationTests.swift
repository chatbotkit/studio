import Testing
@testable import StudioConfiguration

@Test func composeExpansion() throws {
    #expect(try ComposeInterpolation.resolve("[::]:${STORAGE_PORT:-31900}") == "[::]:31900")
    #expect(try ComposeInterpolation.resolve("${URL:-http://garage:${PORT:-31900}}") == "http://garage:31900")
    #expect(try ComposeInterpolation.resolve("$PORT/${PORT}", variables: ["PORT": "4000"]) == "4000/4000")
    #expect(try ComposeInterpolation.resolve("${A:-fallback}/${A-fallback}", variables: ["A": ""]) == "fallback/")
    #expect(try ComposeInterpolation.resolve("${A:+yes}/${A+yes}", variables: ["A": ""]) == "/yes")
    #expect(try ComposeInterpolation.resolve("${A:+$B}") == "")
    #expect(try ComposeInterpolation.resolve("${A:-$MISSING}", variables: ["A": "set"]) == "set")
    #expect(try ComposeInterpolation.resolve("$$PORT/$${PORT}/$5") == "$PORT/${PORT}/$5")
    #expect(try ComposeInterpolation.resolve("${A?required}", variables: ["A": ""]) == "")
    #expect(throws: ConfigurationError.self) { try ComposeInterpolation.resolve("${A:?required}", variables: ["A": ""]) }
}

@Test(arguments: ["$MISSING", "${MISSING}", "${PORT:-31900", "${PORT/foo/bar}", "${}", "${PORT:?required}"])
func invalidConfigurationFailsBeforeLaunch(_ value: String) {
    #expect(throws: ConfigurationError.self) { try ComposeInterpolation.resolve(value) }
}

private func compose(port: String) -> String {
    """
    configs:
      garage-config:
        content: |
          rpc_secret = "${GARAGE_RPC_SECRET:-test-secret}"
          [s3_api]
          api_bind_addr = "[::]:\(port)"
          [admin]
          api_bind_addr = "[::]:3903"
          admin_token = "${GARAGE_ADMIN_TOKEN:-dev-admin-token}"
    volumes:
      garage-data:
    """
}

@Test(arguments: ["${STORAGE_PORT:-31900}", "31900"])
func garageConfigurationRegression(_ port: String) throws {
    let result = try GarageConfiguration.extract(from: compose(port: port), variables: ["STORAGE_PORT": "31900"])
    #expect(result.configuration.contains("api_bind_addr = \"[::]:31900\""))
    #expect(result.configuration.contains("admin_token = \"dev-admin-token\""))
    #expect(!result.configuration.contains("${"))
    #expect(!result.configuration.contains("volumes:"))
}

@Test(arguments: ["${UNKNOWN}", "garbage", "9999"])
func garageRejectsInvalidPort(_ port: String) {
    #expect(throws: ConfigurationError.self) { try GarageConfiguration.extract(from: compose(port: port), variables: ["STORAGE_PORT": "31900"]) }
}

@Test func startupErrorShowsRootCauseFirst() {
    let output = "\u{1B}[32mINFO Loading configuration...\u{1B}[0m\nError: TOML decode error\ninvalid socket address syntax\n"
    let message = StartupFailure.message(service: "garage", output: output, fallback: "No such process", exitCode: 1)
    #expect(message.hasPrefix("garage exited with code 1: Error: TOML decode error"))
    #expect(message.contains("invalid socket address syntax"))
    #expect(!message.contains("\u{1B}"))
    #expect(!message.contains("No such process"))
    #expect(StartupFailure.message(service: "garage", output: "", fallback: "Probe timed out").contains("Probe timed out"))
}
