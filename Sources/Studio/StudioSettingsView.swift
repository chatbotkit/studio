import SwiftUI

enum StudioSettingsTab: Hashable {
    case storage
    case updates
}

struct StudioSettingsView: View {
    @ObservedObject var model: AppModel
    @Binding var selection: StudioSettingsTab

    var body: some View {
        TabView(selection: $selection) {
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
        .frame(width: 580, height: 380)
    }
}
