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

    static func automaticChecks(in defaults: UserDefaults) -> Bool {
        // On unless the user has explicitly turned it off.
        defaults.object(forKey: automaticChecksKey) as? Bool ?? true
    }
}
