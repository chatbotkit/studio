import Foundation
import Yams

/// The environment subset of Compose, not a general-purpose Compose executor.
/// Never inherits host credentials or reads .env/env_file from the host.
public struct ComposeEnvironment: Sendable, Equatable {
    public var values: [String: String] = [:]
    public var unset: Set<String> = []
    public init() {}

    public func merging(imageEnvironment: [String]) -> [String] {
        var result: [String: String] = [:]
        for item in imageEnvironment {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
        for key in unset { result.removeValue(forKey: key) }
        result.merge(values) { _, value in value }
        return result.keys.sorted().map { "\($0)=\(result[$0]!)" }
    }

    public static func load(_ yaml: String, variables: [String: String] = [:]) throws -> [String: ComposeEnvironment] {
        var budget = 10_000
        return try environments(from: root(yaml, budget: &budget), variables: variables, budget: &budget)
    }

    public static func loadStack(_ yaml: String, variables: [String: String] = [:]) throws -> ResolvedStackConfiguration {
        var budget = 10_000
        let root = try root(yaml, budget: &budget)
        let environments = try environments(from: root, variables: variables, budget: &budget)
        let manifest = try StackManifest.load(root["x-cbk"], variables: variables, services: Set(environments.keys), budget: &budget)
        return ResolvedStackConfiguration(environments: environments, manifest: manifest)
    }

    private static func root(_ yaml: String, budget: inout Int) throws -> [String: Node] {
        guard yaml.utf8.count <= 2 * 1_024 * 1_024 else { throw invalid() }
        let node: Node
        do {
            guard let parsed = try Yams.compose(yaml: yaml, .default, .default, .utf8) else { throw invalid() }
            node = parsed
        } catch { throw ConfigurationError("Invalid Compose YAML; environment was not applied.") }
        return try mapping(node, depth: 0, budget: &budget)
    }

    private static func environments(from root: [String: Node], variables: [String: String], budget: inout Int) throws -> [String: ComposeEnvironment] {
        guard let services = root["services"] else { throw invalid() }
        let serviceMap = try mapping(services, depth: 0, budget: &budget)
        var result: [String: ComposeEnvironment] = [:]
        for (name, service) in serviceMap {
            let fields = try mapping(service, depth: 0, budget: &budget)
            guard fields["env_file"] == nil, fields["extends"] == nil else {
                throw ConfigurationError("Compose env_file and extends are not supported by the private runtime.")
            }
            var environment = ComposeEnvironment()
            if let env = fields["environment"], env.tag != Tag(.null) {
                if let sequence = env.sequence {
                    var seen: Set<String> = []
                    for item in sequence {
                        guard let scalar = item.scalar else { throw invalid() }
                        let expanded = try ComposeInterpolation.resolve(scalar.string, variables: variables)
                        let parts = expanded.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                        let key = String(parts.first ?? "")
                        guard seen.insert(key).inserted else { throw invalid() }
                        try environment.set(key, value: parts.count == 2 ? String(parts[1]) : variables[key])
                    }
                } else {
                    for (key, value) in try mapping(env, depth: 0, budget: &budget) {
                        guard let scalar = value.scalar else { throw invalid() }
                        let resolved = value.tag == Tag(.null) ? variables[key] : try ComposeInterpolation.resolve(scalar.string, variables: variables)
                        try environment.set(key, value: resolved)
                    }
                }
            }
            result[name] = environment
        }
        return result
    }

    private mutating func set(_ key: String, value: String?) throws {
        guard !key.isEmpty, !key.contains("="), !key.contains("\0"), value?.contains("\0") != true else { throw Self.invalid() }
        if let value { values[key] = value } else { unset.insert(key) }
    }

    /// Merge aliases before interpolation. Explicit keys override merged keys;
    /// earlier maps in a merge sequence take precedence, as YAML specifies.
    static func mapping(_ node: Node, depth: Int, budget: inout Int) throws -> [String: Node] {
        guard depth < 32, let map = node.mapping else { throw invalid() }
        budget -= map.count + 1
        guard budget >= 0 else { throw invalid() }
        var result: [String: Node] = [:]
        var explicit: [String: Node] = [:]
        var merged = false
        for (keyNode, value) in map {
            guard let key = keyNode.scalar?.string else { throw invalid() }
            if keyNode.tag == Tag(.merge) {
                guard !merged else { throw invalid() }
                merged = true
                let sources = value.sequence.map(Array.init) ?? [value]
                for source in sources {
                    for (key, value) in try mapping(source, depth: depth + 1, budget: &budget) where result[key] == nil {
                        result[key] = value
                    }
                }
            } else {
                guard explicit[key] == nil else { throw invalid() }
                explicit[key] = value
            }
        }
        result.merge(explicit) { _, value in value }
        return result
    }

    private static func invalid() -> ConfigurationError {
        ConfigurationError("Unsupported or ambiguous Compose environment configuration.")
    }
}

/// Only topology-dependent substitutions differ from Docker Compose. All
/// feature flags, credentials/defaults and service settings come from YAML.
public enum PrivateStackEnvironment {
    public static func variables(sitePort: UInt16, relayPort: UInt16, storagePort: UInt16) -> [String: String] {
        let origin = "http://127.0.0.1:\(sitePort)"
        return [
            "PLATFORM_PORT": String(sitePort), "RELAY_PORT": String(relayPort), "STORAGE_PORT": String(storagePort),
            "SITE_URL": origin, "NEXTAUTH_URL": origin,
            "STORAGE_URL": "http://127.0.0.1:\(storagePort)",
            "RELAY_URL": "http://127.0.0.1:\(relayPort)"
        ]
    }

    public static func load(_ yaml: String, sitePort: UInt16, relayPort: UInt16, storagePort: UInt16) throws -> ResolvedStackConfiguration {
        let result = try ComposeEnvironment.loadStack(yaml, variables: variables(sitePort: sitePort, relayPort: relayPort, storagePort: storagePort))
        try result.manifest.validate(ports: .init(site: sitePort, relay: relayPort, storage: storagePort))
        guard let platform = result.environments["platform"], platform.values["PORT"] == "3000",
              platform.values["RELAY_PORT"] == nil || platform.values["RELAY_PORT"] == "3001" else {
            throw ConfigurationError("The private runtime requires platform port 3000 and relay port 3001.")
        }
        // These endpoints are used inside and outside the shared pod. A literal
        // environment override must not silently disagree with the manifest.
        let expected = ["SITE_URL": "site", "NEXTAUTH_URL": "site", "APP_MAIN_ORIGIN": "apps", "APP_LABS_ORIGIN": "labs", "RELAY_URL": "relay", "STORAGE_ENDPOINT": "storage"]
        for (variable, endpoint) in expected {
            guard platform.values[variable] == result.manifest.endpoints[endpoint]?.url else {
                throw ConfigurationError("Platform environment does not match endpoint manifest: \(variable).")
            }
        }
        for (variable, apex) in [("SPACE_APEX", "space"), ("PORTAL_APEX", "portal")] {
            guard platform.values[variable] == result.manifest.apexes[apex]?.apex else {
                throw ConfigurationError("Platform environment does not match endpoint manifest: \(variable).")
            }
        }
        return result
    }
}
