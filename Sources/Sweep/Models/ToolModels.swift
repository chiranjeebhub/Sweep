import AppKit
import SweepCore

/// State for Malware Removal.
@MainActor
final class MalwareModel: ObservableObject {
    @Published private(set) var threats: [Threat] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isRemoving = false
    @Published private(set) var hasScanned = false
    @Published var selected: Set<URL> = []
    @Published var message: String?

    let xprotectVersion = MalwareScanner.xprotectVersion()

    func scan() async {
        isScanning = true
        let found = await background { MalwareScanner().scan() }
        threats = found
        // Known adware starts out ticked. Merely suspicious items are left for the user to judge.
        selected = Set(found.filter { $0.severity == .high }.map(\.url))
        hasScanned = true
        isScanning = false
    }

    var selectedThreats: [Threat] { threats.filter { selected.contains($0.url) } }

    func isSelected(_ threat: Threat) -> Bool { selected.contains(threat.url) }

    func setSelected(_ threat: Threat, _ on: Bool) {
        if on { selected.insert(threat.url) } else { selected.remove(threat.url) }
    }

    func removeSelected() async {
        isRemoving = true
        let chosen = selectedThreats
        let outcome = await background { MalwareRemover.remove(chosen) }
        LastRun.mark(.protection)
        await scan()
        isRemoving = false
        if outcome.cancelled {
            message = "Some items need your administrator password and were left in place."
        } else if !outcome.result.failures.isEmpty {
            message = "Removed \(outcome.result.removedCount) items. \(outcome.result.failures.count) couldn't be removed."
        } else {
            message = "Removed \(outcome.result.removedCount) items. They're in the Trash."
        }
    }
}

/// State for Maintenance.
@MainActor
final class MaintenanceModel: ObservableObject {
    let tasks = MaintenanceTask.available
    @Published var selected: Set<String> = Set(MaintenanceTask.available.filter(\.selectedByDefault).map(\.id))
    @Published private(set) var results: [String: MaintenanceResult] = [:]
    @Published private(set) var isRunning = false

    var selectedTasks: [MaintenanceTask] { tasks.filter { selected.contains($0.id) } }
    var needsPassword: Bool { selectedTasks.contains(where: \.needsAdmin) }

    func run() async {
        isRunning = true
        results = [:]
        let chosen = selectedTasks
        results = await background { MaintenanceRunner.run(chosen) }
        if results.values.contains(.done) { LastRun.mark(.speed) }
        isRunning = false
    }
}

/// State for the Updater.
@MainActor
final class UpdaterModel: ObservableObject {
    @Published private(set) var updates: [AppUpdate] = []
    @Published private(set) var appCount = 0
    @Published private(set) var isChecking = false
    @Published private(set) var hasChecked = false
    @Published private(set) var installing: Set<URL> = []
    @Published var message: String?

    func check() async {
        isChecking = true
        let apps = await background { AppScanner().installedApps() }
        appCount = apps.count
        updates = await UpdateChecker().check(apps)
        hasChecked = true
        isChecking = false
    }

    func actionTitle(for update: AppUpdate) -> String {
        switch update.source {
        case .appStore: "App Store"
        case .sparkle(let download): UpdateInstaller.canInstall(download) ? "Update" : "Download"
        }
    }

    func update(_ update: AppUpdate) async {
        switch update.source {
        case .appStore(let page):
            NSWorkspace.shared.open(Self.appStoreURL(page))
        case .sparkle(let download):
            guard UpdateInstaller.canInstall(download) else {
                NSWorkspace.shared.open(download)
                return
            }
            if let id = update.app.bundleIdentifier, !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
                message = "Quit \(update.app.name) before updating it."
                return
            }
            installing.insert(update.id)
            do {
                try await UpdateInstaller.install(update)
                updates.removeAll { $0.id == update.id }
                message = "Updated \(update.app.name) to \(update.latestVersion)."
            } catch {
                message = "Couldn't update \(update.app.name). \(error.localizedDescription)"
            }
            installing.remove(update.id)
        }
    }

    /// Opens the store page in the App Store app rather than the browser.
    private static func appStoreURL(_ page: URL?) -> URL {
        if let page, var components = URLComponents(url: page, resolvingAgainstBaseURL: false) {
            components.scheme = "macappstore"
            if let url = components.url { return url }
        }
        return URL(string: "macappstore://showUpdatesPage")!
    }
}
