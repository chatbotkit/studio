import SwiftUI

enum StudioSettingsTab: Hashable {
    case storage
    case updates
}

struct StudioSettingsView: View {
    @ObservedObject var model: AppModel
    @Binding var selection: StudioSettingsTab

    var body: some View {
        TabView(selection: $selection.animation(.easeInOut(duration: 0.22))) {
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
        .windowResizeAnchor(.top)
    }
}
