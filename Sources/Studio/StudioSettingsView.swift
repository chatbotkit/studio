import SwiftUI

enum StudioSettingsLayout {
    static let width: CGFloat = 580
}

enum StudioSettingsTab: Hashable {
    case models
    case storage
    case updates
}

struct StudioSettingsView: View {
    @ObservedObject var model: AppModel
    @Binding var selection: StudioSettingsTab

    var body: some View {
        TabView(selection: $selection.animation(.easeInOut(duration: 0.22))) {
            ModelProvidersSettingsView(model: model)
                .tabItem {
                    Label("Models", systemImage: "key.horizontal")
                }
                .tag(StudioSettingsTab.models)

            StorageView(model: model)
                .tabItem {
                    Label("Storage", systemImage: "internaldrive")
                }
                .tag(StudioSettingsTab.storage)

            UpdatesSettingsView()
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }
                .tag(StudioSettingsTab.updates)
        }
        .frame(width: StudioSettingsLayout.width)
        .windowResizeAnchor(.top)
    }
}
