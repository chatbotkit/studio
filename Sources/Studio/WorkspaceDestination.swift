import Foundation

enum WorkspaceDestination: CaseIterable {
    case labs
    case apps

    var menuTitle: String {
        switch self {
        case .labs: "Open Labs"
        case .apps: "Open Apps"
        }
    }

    func url(port: Int) -> URL? {
        guard (1...65535).contains(port) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        switch self {
        case .labs: components.host = "cbk-labs.localhost"
        case .apps: components.host = "cbk-apps.localhost"
        }
        components.port = port
        components.path = "/"
        return components.url
    }
}
