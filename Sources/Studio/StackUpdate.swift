import Foundation

/// The stack follows a moving OCI tag that Studio resolves on every start.
/// While a workspace stays open, a periodic digest comparison reports when the
/// tag has moved. Nothing is downloaded or applied until the stack restarts,
/// which runs the normal verified load path.
enum StackUpdateStatus: Equatable {
    case unchecked
    case upToDate(Date)
    case available(String)
    case failed(String)

    var availableDigest: String? {
        if case let .available(digest) = self { return digest }
        return nil
    }
}

enum StackUpdatePreferences {
    static let automaticChecksKey = "StudioStackUpdateChecksEnabled"
    static let interval: Duration = .seconds(6 * 60 * 60)

    /// A digest prefix that is short enough for a settings row yet still
    /// distinguishes one published stack from the next.
    static func short(_ digest: String) -> String {
        let hex = digest.split(separator: ":").last.map(String.init) ?? digest
        return String(hex.prefix(12))
    }

    static func automaticChecks(in defaults: UserDefaults) -> Bool {
        // On unless the user has explicitly turned it off.
        defaults.object(forKey: automaticChecksKey) as? Bool ?? true
    }
}
