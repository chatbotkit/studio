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
    /// The newer version Sparkle last found, from any check. Skipped versions are not found.
    @Published private(set) var availableVersion: String?
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
    /// Asks Sparkle whether an update exists without offering it.
    func probeForUpdate() {
        if started, controller.updater.canCheckForUpdates { controller.updater.checkForUpdateInformation() }
    }
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

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        availableVersion = nil
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

/// The update button on the Settings Update tab. Sparkle's user-initiated check
/// offers the update it finds, so one action serves both titles.
struct UpdateSettingsButton: View {
    let availableVersion: String?
    let canCheck: Bool
    let action: () -> Void

    var body: some View {
        Button(Self.title(availableVersion: availableVersion), action: action).disabled(!canCheck)
    }

    static func title(availableVersion: String?) -> String {
        availableVersion == nil ? "Check for Updates…" : "Install Update…"
    }
}

struct UpdatesSettingsView: View {
    @ObservedObject private var updater = AppUpdater.shared
    @ObservedObject private var preparation = AppUpdater.shared.preparation
    @ObservedObject var model: AppModel

    private var runningStack: String {
        guard let digest = model.info?.resolvedDigest else { return "Not running" }
        return StackUpdatePreferences.short(digest)
    }

    private var stackStatus: String? {
        if model.stackUpdateChecking { return "Checking…" }
        switch model.stackUpdate {
        case .unchecked, .available: return nil
        case let .upToDate(date): return "Up to date — checked \(date.formatted(date: .omitted, time: .shortened))"
        case let .failed(message): return "Couldn’t check — \(message)"
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Installed Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                }
                if let version = updater.availableVersion {
                    Text("Update available — \(version)").font(.caption).foregroundStyle(.orange)
                }
                UpdateSettingsButton(availableVersion: updater.availableVersion, canCheck: updater.canCheckForUpdates,
                                     action: updater.checkForUpdates)
            }

            Section {
                LabeledContent("Running Stack") { Text(runningStack) }
                if let digest = model.stackUpdate.availableDigest {
                    Text("Update available — \(StackUpdatePreferences.short(digest))").font(.caption).foregroundStyle(.orange)
                } else if let stackStatus {
                    Text(stackStatus).font(.caption).foregroundStyle(.secondary)
                }
                if model.stackUpdate.availableDigest != nil {
                    Button("Restart Stack to Update") { model.restart() }
                        .disabled(model.phase.busy)
                } else {
                    Button("Check for Stack Updates") { model.checkForStackUpdate() }
                        .disabled(model.info == nil || model.stackUpdateChecking)
                }
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
                Toggle("Automatically check for stack updates", isOn: Binding(
                    get: { model.automaticallyChecksForStackUpdates },
                    set: { value in model.setAutomaticStackUpdateChecks(value) }
                ))
                .help("The workspace stack updates separately from the app. Studio runs the newest stack whenever it starts; restarting applies an update found while it is open.")
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
