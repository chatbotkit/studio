import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var allowsAutomaticUpdates = false
    let preparation = UpdatePreparation(
        busy: { AppModel.shared.phase.busy || AppModel.shared.storageBusy },
        shutdown: { await AppModel.shared.shutdown() },
        cancelledShutdown: { AppModel.shared.recoverFromAbortedUpdate() }
    )
    private var started = false
    private var preparingInstall = false
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
    )

    func start() {
        // Development/smoke bundles must never replace themselves with a public
        // release or start a feed request as a side effect of automated tests.
        guard !started, !RuntimeSmokeTest.requested,
              Bundle.main.object(forInfoDictionaryKey: "StudioUpdatesEnabled") as? Bool == true else { return }
        started = true
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloads)
        updater.publisher(for: \.allowsAutomaticUpdates).assign(to: &$allowsAutomaticUpdates)
        controller.startUpdater()
    }

    func checkForUpdates() { if started { controller.checkForUpdates(nil) } }
    func validateConfigurationForSmokeTest() throws {
        guard RuntimeSmokeTest.requested else { return }
        // Only the separately identified diagnostic calls this. Validate the
        // real packaged framework/XPC configuration without checking a feed.
        controller.updater.automaticallyChecksForUpdates = false
        controller.updater.automaticallyDownloadsUpdates = false
        try controller.updater.start()
    }
    func setAutomaticChecks(_ value: Bool) { if started { controller.updater.automaticallyChecksForUpdates = value } }
    func setAutomaticDownloads(_ value: Bool) { if started { controller.updater.automaticallyDownloadsUpdates = value } }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        preparingInstall = true
        preparation.prepare(install: installHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        preparation.cancel()
        if preparingInstall { AppModel.shared.recoverFromAbortedUpdate() }
        preparingInstall = false
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = AppUpdater.shared
    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

struct UpdatesSettingsView: View {
    @ObservedObject private var updater = AppUpdater.shared
    @ObservedObject private var preparation = AppUpdater.shared.preparation
    @ObservedObject var model: AppModel

    private var stackStatus: String {
        if model.stackUpdateChecking { return "Checking…" }
        switch model.stackUpdate {
        case .unchecked: return model.info == nil ? "Available once the workspace is running" : "Up to date at startup"
        case let .upToDate(date): return "Up to date, checked \(date.formatted(date: .omitted, time: .shortened))"
        case .available: return "A new version is available"
        case let .failed(message): return "Couldn’t check: \(message)"
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Installed Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                }
                CheckForUpdatesButton()
            }

            Section {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecks },
                    set: { value in updater.setAutomaticChecks(value) }
                ))
                Toggle("Automatically download and install updates", isOn: Binding(
                    get: { updater.automaticallyDownloads },
                    set: { value in updater.setAutomaticDownloads(value) }
                ))
                .disabled(!updater.allowsAutomaticUpdates)
            }
            Section {
                LabeledContent("Stack") { Text(stackStatus).foregroundStyle(.secondary) }
                if model.stackUpdate.availableDigest != nil {
                    Button("Restart Stack to Update") { model.restart() }
                        .disabled(model.phase.busy)
                } else {
                    Button("Check for Stack Updates") { model.checkForStackUpdate() }
                        .disabled(model.info == nil || model.stackUpdateChecking)
                }
                Toggle("Automatically check for stack updates", isOn: Binding(
                    get: { model.automaticallyChecksForStackUpdates },
                    set: { value in model.setAutomaticStackUpdateChecks(value) }
                ))
            } footer: {
                Text("The workspace stack updates separately from the app. Studio always runs the newest stack when it starts; a restart applies an update found while it is open.")
            }
            if preparation.waiting {
                Label("Preparing update…", systemImage: "clock")
                    .foregroundStyle(.secondary)
            }
            if let error = preparation.error {
                Section {
                    Text(error)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Retry Installing Update") { preparation.retry() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
    }
}
