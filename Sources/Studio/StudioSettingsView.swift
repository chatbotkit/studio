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
    @ObservedObject private var updater = AppUpdater.shared

    /// The app and the workspace stack update separately; either one badges the tab.
    private var pendingUpdates: Int {
        (updater.availableVersion == nil ? 0 : 1) + (model.stackUpdate.availableDigest == nil ? 0 : 1)
    }

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

            UpdatesSettingsView(model: model)
                .tabItem {
                    Label("Update", systemImage: "arrow.triangle.2.circlepath")
                }
                .tag(StudioSettingsTab.updates)
        }
        .frame(width: StudioSettingsLayout.width)
        .windowResizeAnchor(.top)
        .settingsScrollIndicators(selection: selection)
        // Badge labels must match the tab labels above.
        .background(SettingsTabBadge(counts: ["Update": pendingUpdates]))
        // Check on opening Settings so the tab is badged before it is selected.
        // Neither probe prompts: Settings reports what they find.
        .onAppear {
            updater.probeForUpdate()
            model.checkForStackUpdate()
        }
    }
}
