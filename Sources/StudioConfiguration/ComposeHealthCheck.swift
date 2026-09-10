import Yams

/// Compose health checks execute only inside their service container. Never
/// run these commands on the Mac or interpolate the host's environment.
enum ComposeHealthCheck {
    static func load(_ services: Node, variables: [String: String], budget: inout Int) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (name, service) in try ComposeEnvironment.mapping(services, depth: 0, budget: &budget) {
            let fields = try ComposeEnvironment.mapping(service, depth: 0, budget: &budget)
            guard let node = fields["healthcheck"] else { continue }
            let health = try ComposeEnvironment.mapping(node, depth: 0, budget: &budget)
            guard health["disable"]?.scalar?.string != "true", let test = health["test"] else {
                throw ConfigurationError("The stack must enable its \(name) health check.")
            }
            func string(_ node: Node) throws -> String {
                guard node.tag != Tag(.null), let scalar = node.scalar else {
                    throw ConfigurationError("Invalid health check for \(name).")
                }
                let value = try ComposeInterpolation.resolve(scalar.string, variables: variables)
                guard !value.contains("\0") else { throw ConfigurationError("Invalid health check for \(name).") }
                return value
            }
            let command: [String]
            if let sequence = test.sequence {
                let parts = try sequence.map(string)
                switch parts.first {
                case "CMD" where parts.count > 1 && !parts[1].isEmpty:
                    command = Array(parts.dropFirst())
                case "CMD-SHELL" where parts.count == 2 && !parts[1].isEmpty:
                    command = ["/bin/sh", "-c", parts[1]]
                default:
                    throw ConfigurationError("Unsupported health check for \(name).")
                }
            } else {
                let value = try string(test)
                guard !value.isEmpty else { throw ConfigurationError("Invalid health check for \(name).") }
                command = ["/bin/sh", "-c", value]
            }
            result[name] = command
        }
        return result
    }
}
