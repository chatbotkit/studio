import Foundation
import Yams

public struct ResolvedStackConfiguration: Equatable, Sendable {
    public let environments: [String: ComposeEnvironment]
    public let manifest: StackManifest
}

public struct StackPorts: Equatable, Sendable {
    public let site: UInt16
    public let relay: UInt16
    public let storage: UInt16

    public init(site: UInt16, relay: UInt16, storage: UInt16) {
        self.site = site; self.relay = relay; self.storage = storage
    }
}

public struct StackManifest: Codable, Equatable, Sendable {
    public struct Endpoint: Codable, Equatable, Sendable {
        public let service: String
        public let published: String
        public let variable: String
        public let url: String
    }
    public struct Apex: Codable, Equatable, Sendable {
        public let service: String
        public let published: String
        public let variable: String
        public let apex: String
    }
    public let version: Int
    public let endpoints: [String: Endpoint]
    public let apexes: [String: Apex]

    static func load(_ node: Node?, variables: [String: String], services: Set<String>, budget: inout Int) throws -> Self {
        guard let node else { throw ConfigurationError("The stack is missing its x-cbk endpoint manifest.") }
        func mapping(_ node: Node, depth: Int, budget: inout Int) throws -> [String: Node] {
            do { return try ComposeEnvironment.mapping(node, depth: depth, budget: &budget) }
            catch { throw ConfigurationError("Malformed endpoint manifest mapping.") }
        }
        func fields(_ node: Node, depth: Int, keys: Set<String>, budget: inout Int) throws -> [String: Node] {
            let result = try mapping(node, depth: depth, budget: &budget)
            guard Set(result.keys) == keys else { throw ConfigurationError("Malformed endpoint manifest fields.") }
            return result
        }
        func scalar(_ node: Node?) throws -> String {
            guard let node, node.tag != Tag(.null), let value = node.scalar?.string else {
                throw ConfigurationError("Malformed endpoint manifest scalar.")
            }
            do { return try ComposeInterpolation.resolve(value, variables: variables) }
            catch { throw ConfigurationError("Could not resolve endpoint manifest scalar.") }
        }
        let root = try fields(node, depth: 0, keys: ["version", "endpoints", "apexes"], budget: &budget)
        guard try scalar(root["version"]) == "1" else { throw ConfigurationError("Unsupported endpoint manifest version; Studio requires version 1.") }
        let endpointNodes = try mapping(root["endpoints"]!, depth: 1, budget: &budget)
        let apexNodes = try mapping(root["apexes"]!, depth: 1, budget: &budget)
        let endpointVariables = ["site": "SITE_URL", "apps": "APP_MAIN_ORIGIN", "labs": "APP_LABS_ORIGIN", "relay": "RELAY_URL", "storage": "STORAGE_URL"]
        let apexVariables = ["space": "SPACE_APEX", "portal": "PORTAL_APEX"]
        for name in endpointVariables.keys where endpointNodes[name] == nil {
            throw ConfigurationError("Endpoint manifest is missing endpoint: \(name).")
        }
        for name in apexVariables.keys where apexNodes[name] == nil {
            throw ConfigurationError("Endpoint manifest is missing apex: \(name).")
        }
        guard Set(endpointNodes.keys) == Set(endpointVariables.keys), Set(apexNodes.keys) == Set(apexVariables.keys) else {
            throw ConfigurationError("Endpoint manifest contains unsupported entries.")
        }
        var endpoints: [String: Endpoint] = [:]
        var apexes: [String: Apex] = [:]
        for (name, node) in endpointNodes {
            let values = try fields(node, depth: 2, keys: ["service", "published", "variable", "url"], budget: &budget)
            let entry = try Endpoint(service: scalar(values["service"]), published: scalar(values["published"]), variable: scalar(values["variable"]), url: scalar(values["url"]))
            guard services.contains(entry.service), entry.service == (name == "storage" ? "garage" : "platform"), entry.variable == endpointVariables[name] else {
                throw ConfigurationError("Endpoint manifest has an unsupported service or variable for \(name).")
            }
            endpoints[name] = entry
        }
        for (name, node) in apexNodes {
            let values = try fields(node, depth: 2, keys: ["service", "published", "variable", "apex"], budget: &budget)
            let entry = try Apex(service: scalar(values["service"]), published: scalar(values["published"]), variable: scalar(values["variable"]), apex: scalar(values["apex"]))
            guard services.contains(entry.service), entry.service == "platform", entry.variable == apexVariables[name] else {
                throw ConfigurationError("Endpoint manifest has an unsupported service or variable for \(name).")
            }
            apexes[name] = entry
        }
        let result = Self(version: 1, endpoints: endpoints, apexes: apexes)
        try result.validate(ports: result.preferredPorts)
        return result
    }

    public var preferredPorts: StackPorts {
        get throws {
            try StackPorts(site: port(endpoints["site"]?.published), relay: port(endpoints["relay"]?.published), storage: port(endpoints["storage"]?.published))
        }
    }

    private func port(_ value: String?) throws -> UInt16 {
        guard let value, !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }), let port = UInt16(value), port > 0 else {
            throw ConfigurationError("Endpoint manifest contains an invalid published port.")
        }
        return port
    }

    public func validate(ports: StackPorts) throws {
        guard version == 1, ports.site > 0, ports.relay > 0, ports.storage > 0,
              Set([ports.site, ports.relay, ports.storage]).count == 3,
              ![3000, 3001, 3903].contains(ports.storage) else {
            throw ConfigurationError("Endpoint manifest contains conflicting ports or an unsupported version.")
        }
        for (name, entry) in endpoints {
            let expected = name == "relay" ? ports.relay : name == "storage" ? ports.storage : ports.site
            guard try port(entry.published) == expected,
                  let url = URLComponents(string: entry.url), url.scheme == "http",
                  let host = url.host, Self.isLocalHost(host), url.port == Int(expected),
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  !entry.url.contains("%"), url.url != nil else {
                throw ConfigurationError("Endpoint manifest has an invalid local URL or published port for \(name).")
            }
        }
        for (name, entry) in apexes {
            guard Self.isLocalDNSName(entry.apex), try port(entry.published) == ports.site else {
                throw ConfigurationError("Endpoint manifest has an invalid local apex or published port for \(name).")
            }
        }
    }

    public func url(for endpoint: String) -> URL? { endpoints[endpoint].flatMap { URL(string: $0.url) } }

    public static func normalizedHost(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func isLocalHost(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(normalizedHost(host)) || isLocalDNSName(host)
    }

    private static func isLocalDNSName(_ host: String) -> Bool {
        let host = host.lowercased()
        guard host.hasSuffix(".localhost"), host.count <= 253 else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    public var hosts: [String] {
        Array(Set(endpoints.values.compactMap { URLComponents(string: $0.url)?.host.map(Self.normalizedHost) } + apexes.values.map(\.apex))).sorted()
    }

    /// Membership includes the allocated port, not just a familiar hostname.
    /// A different local app on a different port is never part of this stack.
    public func contains(_ url: URL) -> Bool {
        guard url.scheme == "http", let rawHost = url.host, let port = url.port,
              url.user == nil, url.password == nil, Self.isLocalHost(rawHost) else { return false }
        let host = Self.normalizedHost(rawHost)
        if ["127.0.0.1", "localhost", "::1"].contains(host) {
            return endpoints.values.contains { Int($0.published) == port }
        }
        if endpoints.values.contains(where: { URLComponents(string: $0.url)?.host.map(Self.normalizedHost) == host && Int($0.published) == port }) { return true }
        return apexes.values.contains { (host == $0.apex.lowercased() || host.hasSuffix("." + $0.apex.lowercased())) && Int($0.published) == port }
    }
}
