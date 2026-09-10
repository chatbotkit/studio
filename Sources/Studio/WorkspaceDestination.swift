import Foundation
import StudioConfiguration

enum WorkspaceDestination: CaseIterable {
    case apps
    case labs

    var menuTitle: String {
        switch self {
        case .labs: "Open Labs"
        case .apps: "Open Apps"
        }
    }

    func url(manifest: StackManifest) -> URL? {
        switch self {
        case .labs: manifest.url(for: "labs")
        case .apps: manifest.url(for: "apps")
        }
    }
}
