import Foundation

public struct ConfigurationError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Compose-style value expansion without importing the host process environment
/// or executing a shell. Missing bare variables fail early rather than becoming
/// empty strings: Studio has no interactive Compose warning stream.
public enum ComposeInterpolation {
    public static func resolve(_ source: String, variables: [String: String] = [:]) throws -> String {
        var parser = Parser(input: Array(source), variables: variables)
        return try parser.expand()
    }

    private struct Parser {
        let input: [Character]
        let variables: [String: String]
        var offset = 0

        func isStart(_ character: Character) -> Bool {
            character == "_" || character.isASCII && character.isLetter
        }

        func isName(_ character: Character) -> Bool {
            isStart(character) || character.isASCII && character.isNumber
        }

        mutating func expand() throws -> String {
            var result = ""
            while offset < input.count {
                let character = input[offset]
                offset += 1
                guard character == "$", offset < input.count else {
                    result.append(character)
                    continue
                }
                if input[offset] == "$" {
                    result.append("$")
                    offset += 1
                } else if input[offset] == "{" {
                    offset += 1
                    result += try expression()
                } else if isStart(input[offset]) {
                    let name = readName()
                    guard let value = variables[name] else {
                        throw ConfigurationError("Missing configuration variable: \(name)")
                    }
                    result += value
                } else {
                    result.append("$")
                }
            }
            return result
        }

        mutating func readName() -> String {
            let start = offset
            while offset < input.count, isName(input[offset]) { offset += 1 }
            return String(input[start..<offset])
        }

        mutating func expression() throws -> String {
            guard offset < input.count, isStart(input[offset]) else {
                throw ConfigurationError("Invalid configuration variable expression")
            }
            let name = readName()
            guard offset < input.count else {
                throw ConfigurationError("Unclosed configuration variable: \(name)")
            }
            if input[offset] == "}" {
                offset += 1
                guard let value = variables[name] else {
                    throw ConfigurationError("Missing configuration variable: \(name)")
                }
                return value
            }
            let nonEmpty: Bool
            if input[offset] == ":" {
                nonEmpty = true
                offset += 1
            } else {
                nonEmpty = false
            }
            guard offset < input.count, ["-", "+", "?"].contains(input[offset]) else {
                throw ConfigurationError("Unsupported configuration expansion for \(name)")
            }
            let operation = input[offset]
            offset += 1
            let start = offset
            var depth = 0
            while offset < input.count {
                if input[offset] == "{" { depth += 1 }
                if input[offset] == "}" {
                    if depth == 0 { break }
                    depth -= 1
                }
                offset += 1
            }
            guard offset < input.count else {
                throw ConfigurationError("Unclosed configuration variable: \(name)")
            }
            let word = String(input[start..<offset])
            offset += 1
            let value = variables[name]
            let present = value != nil && (!nonEmpty || value != "")
            switch operation {
            case "-":
                return present ? value! : try ComposeInterpolation.resolve(word, variables: variables)
            case "+":
                return present ? try ComposeInterpolation.resolve(word, variables: variables) : ""
            default:
                guard present else {
                    // Do not echo expanded user data or secret defaults in errors.
                    throw ConfigurationError("Required configuration variable is missing: \(name)")
                }
                return value!
            }
        }
    }
}

public enum GarageConfiguration {
    public struct Resolved: Equatable, Sendable {
        public let configuration: String
        public let s3Port: UInt16
    }

    public static func extract(from yaml: String, variables: [String: String]) throws -> Resolved {
        guard let requested = variables["STORAGE_PORT"], let storagePort = UInt16(requested), storagePort > 0 else {
            throw ConfigurationError("Garage configuration requires an allocated STORAGE_PORT.")
        }
        let lines = yaml.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        func endOfBlock(after index: Int, indent: Int) -> Int {
            lines.indices.dropFirst(index + 1).first { index in
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#") && line.prefix { $0 == " " }.count <= indent
            } ?? lines.count
        }
        guard let configs = lines.firstIndex(of: "configs:") else {
            throw ConfigurationError("The artifact is missing its inline Garage configuration.")
        }
        let configEnd = endOfBlock(after: configs, indent: 0)
        let markers = ((configs + 1)..<configEnd).filter { lines[$0] == "  garage-config:" }
        guard markers.count == 1, let marker = markers.first else {
            throw ConfigurationError("The artifact must contain exactly one inline Garage configuration.")
        }
        let garageEnd = endOfBlock(after: marker, indent: 2)
        let contents = ((marker + 1)..<garageEnd).filter { lines[$0] == "    content: |" }
        guard contents.count == 1, let content = contents.first else {
            throw ConfigurationError("The artifact is missing its inline Garage configuration.")
        }
        var collected: [String] = []
        for line in lines[(content + 1)..<garageEnd] {
            let indent = line.prefix { $0 == " " }.count
            if !line.trimmingCharacters(in: .whitespaces).isEmpty, indent < 6 { break }
            collected.append(indent >= 6 ? String(line.dropFirst(6)) : "")
        }
        let resolved = try ComposeInterpolation.resolve(collected.joined(separator: "\n") + "\n", variables: variables)
        var s3Port: UInt16?
        for section in ["s3_api", "admin"] {
            let sectionPattern = "(?ms)^\\[\(section)\\][^\\[]*?^api_bind_addr\\s*=\\s*\"([^\"]+)\""
            let regex = try NSRegularExpression(pattern: sectionPattern)
            let range = NSRange(resolved.startIndex..., in: resolved)
            let matches = regex.matches(in: resolved, range: range)
            guard matches.count == 1, let match = matches.first,
                  let addressRange = Range(match.range(at: 1), in: resolved),
                  let portText = resolved[addressRange].split(separator: ":").last,
                  let port = UInt16(portText), port > 0,
                  ["[::]:\(port)", "0.0.0.0:\(port)", "127.0.0.1:\(port)"].contains(String(resolved[addressRange])) else {
                throw ConfigurationError("Garage configuration: \(section).api_bind_addr must use a valid port with a supported bind address.")
            }
            if section == "admin", port != 3903 { throw ConfigurationError("Garage configuration: admin.api_bind_addr must use internal port 3903 with a supported bind address.") }
            if section == "s3_api" { s3Port = port }
        }
        guard s3Port == storagePort else { throw ConfigurationError("Garage S3 port does not match the allocated STORAGE_PORT.") }
        return Resolved(configuration: resolved, s3Port: storagePort)
    }
}

public enum StartupFailure {
    public static func message(service: String, output: String, fallback: String, exitCode: Int32? = nil) -> String {
        let clean = output.replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        let lines = clean.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let errorLine = lines.first { line in
            let lower = line.lowercased()
            return lower.contains("error:") || lower.contains(" error ") || lower.contains("panicked") || lower.contains("fatal")
        }
        let reason = String((errorLine ?? lines.last ?? fallback).prefix(512))
        let status = exitCode.map { " exited with code \($0)" } ?? " did not become healthy"
        return "\(service)\(status): \(reason)\n\(clean.suffix(2000))"
    }
}
