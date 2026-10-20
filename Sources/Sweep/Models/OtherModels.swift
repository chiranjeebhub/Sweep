import AppKit
import SweepCore

/// State for Privacy.
@MainActor
final class PrivacyModel: ObservableObject {
    @Published private(set) var sources: [PrivacySource] = []
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published var focusedSourceID: String?
    @Published var selectedItemIDs: Set<String> = []
    /// Browsers that were open during the last clean and were skipped.
    @Published var skippedBrowsers: [String] = []

    func scan() async {
        isScanning = true
        let found = await background { PrivacyScanner().scan() }
        sources = found
        selectedItemIDs = Set(found.flatMap { $0.items.filter(\.selectedByDefault).map(\.id) })
        if focusedSourceID == nil || !found.contains(where: { $0.id == focusedSourceID }) {
            focusedSourceID = found.first?.id
        }
        hasScanned = true
        isScanning = false
    }

    var focused: PrivacySource? { sources.first { $0.id == focusedSourceID } }
    var needsFullDiskAccess: Bool { sources.contains(where: \.needsFullDiskAccess) }
    var selectedItems: [PrivacyItem] { sources.flatMap(\.items).filter { selectedItemIDs.contains($0.id) } }
    var selectedCount: Int { selectedItems.count }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func isSelected(_ source: PrivacySource) -> Bool {
        source.items.contains { selectedItemIDs.contains($0.id) }
    }

    func setSelected(_ source: PrivacySource, _ on: Bool) {
        for item in source.items { setSelected(item, on) }
    }

    func isSelected(_ item: PrivacyItem) -> Bool { selectedItemIDs.contains(item.id) }

    func setSelected(_ item: PrivacyItem, _ on: Bool) {
        if on { selectedItemIDs.insert(item.id) } else { selectedItemIDs.remove(item.id) }
    }

    /// Selected sources whose app is open right now. Browsers rewrite their files on quit,
    /// so cleaning them while they run would be undone.
    var runningSelectedApps: [NSRunningApplication] {
        sources.filter { isSelected($0) }.compactMap(\.bundleIdentifier).flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }
    }

    func quitRunningApps() {
        runningSelectedApps.forEach { $0.terminate() }
    }

    @discardableResult
    func clean() async -> CleanResult {
        var urls: [URL] = []
        var skipped: [String] = []
        for source in sources where isSelected(source) {
            if let id = source.bundleIdentifier, !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
                skipped.append(source.name)
                continue
            }
            urls += source.items.filter { isSelected($0) }.flatMap(\.urls)
        }
        let result = await background { Trasher().trash(urls) }
        skippedBrowsers = skipped
        LastRun.mark(.protection)
        await scan()
        return result
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// An app using a lot of memory right now.
struct HeavyApp: Identifiable {
    let id: pid_t
    let name: String
    let icon: NSImage?
    let memory: Int64
    let app: NSRunningApplication
}

/// State for Optimization.
@MainActor
final class OptimizationModel: ObservableObject {
    @Published private(set) var snapshot: SystemSnapshot?
    @Published private(set) var heavyApps: [HeavyApp] = []
    @Published private(set) var backgroundItemCount = 0
    @Published private(set) var isRunning = false
    @Published var freeMemory = true
    @Published var flushDNS = true
    @Published var lastMessage: String?

    private let stats = SystemStats()
    private var timer: Timer?

    func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSnapshot() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        refreshSnapshot()
        backgroundItemCount = BackgroundItems.launchAgents().count
        heavyApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0 != NSRunningApplication.current }
            .map { app in
                HeavyApp(id: app.processIdentifier, name: app.localizedName ?? "App", icon: app.icon,
                         memory: SystemStats.memoryFootprint(of: app.processIdentifier), app: app)
            }
            .filter { $0.memory > 0 }
            .sorted { $0.memory > $1.memory }
            .prefix(5)
            .map { $0 }
    }

    private func refreshSnapshot() {
        snapshot = stats.sample()
    }

    var selectedTaskCount: Int { (freeMemory ? 1 : 0) + (flushDNS ? 1 : 0) }

    /// Runs the ticked maintenance commands behind one administrator prompt.
    func runSelectedTasks() {
        let commands = [
            freeMemory ? PrivilegedRunner.freeMemoryCommand : nil,
            flushDNS ? PrivilegedRunner.flushDNSCommand : nil,
        ].compactMap { $0 }
        guard !commands.isEmpty else { return }
        isRunning = true
        let before = snapshot?.memoryUsed ?? 0
        switch PrivilegedRunner.run(commands.joined(separator: "; ")) {
        case .success:
            LastRun.mark(.speed)
            refresh()
            let freed = max(0, before - (snapshot?.memoryUsed ?? before))
            lastMessage = freeMemory && freed > 0 ? "Done. Freed \(ByteFormat.string(freed)) of memory." : "Done."
        case .failure(.cancelled):
            lastMessage = nil
        case .failure(.failed(let message)):
            lastMessage = "Couldn't finish: \(message)"
        }
        isRunning = false
    }

    func quit(_ app: HeavyApp) {
        app.app.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// State for the Uninstaller.
@MainActor
final class UninstallerModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All apps"
        case unused = "Unused"
        case leftovers = "Leftovers"
        var id: String { rawValue }
    }

    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var leftovers: [Leftover] = []
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published var filter: Filter = .all
    @Published var focusedAppURL: URL? { didSet { loadRemnants() } }
    @Published private(set) var remnants: AppRemnants?
    @Published var excludedGroups: Set<String> = []
    @Published var selectedLeftovers: Set<URL> = []
    @Published var message: String?

    private let scanner = AppScanner()

    func scan() async {
        isScanning = true
        let scanner = scanner
        let found = await background { scanner.installedApps() }
        let installedIDs = Set(found.compactMap(\.bundleIdentifier))
        leftovers = await background {
            scanner.leftovers { id in
                installedIDs.contains(id) || NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
            }
        }
        apps = found
        if focusedAppURL == nil || !found.contains(where: { $0.url == focusedAppURL }) {
            focusedAppURL = visibleApps.first?.url
        }
        hasScanned = true
        isScanning = false
    }

    var visibleApps: [InstalledApp] {
        filter == .unused ? apps.filter { $0.isUnused() } : apps
    }

    var unusedCount: Int { apps.filter { $0.isUnused() }.count }
    var focusedApp: InstalledApp? { apps.first { $0.url == focusedAppURL } }

    private func loadRemnants() {
        remnants = nil
        excludedGroups = []
        guard let app = focusedApp else { return }
        let scanner = scanner
        Task {
            let found = await background { scanner.remnants(of: app) }
            if focusedAppURL == app.url { remnants = found }
        }
    }

    var selectedRemnantURLs: [URL] {
        (remnants?.groups ?? []).filter { !excludedGroups.contains($0.title) }.flatMap(\.urls)
    }

    var removalSize: Int64 {
        let groups = (remnants?.groups ?? []).filter { !excludedGroups.contains($0.title) }
        return (focusedApp?.size ?? 0) + groups.reduce(0) { $0 + $1.size }
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    /// Moves the app and its selected support files to the Trash.
    func uninstallFocused() async {
        guard let app = focusedApp else { return }
        if isRunning(app) {
            message = "Quit \(app.name) before uninstalling it."
            return
        }
        let urls = [app.url] + selectedRemnantURLs
        let result = await background { Trasher().trash(urls) }
        message = result.failures.contains(app.url)
            ? "\(app.name) couldn't be moved to the Trash. It may be protected by macOS."
            : "Moved \(app.name) to the Trash, freeing \(ByteFormat.string(result.freedBytes))."
        focusedAppURL = nil
        await scan()
    }

    /// Removes the app's support files but keeps the app, so it starts fresh next time.
    func resetFocused() async {
        guard let app = focusedApp else { return }
        if isRunning(app) {
            message = "Quit \(app.name) before resetting it."
            return
        }
        let urls = selectedRemnantURLs
        let result = await background { Trasher().trash(urls) }
        message = "Reset \(app.name), freeing \(ByteFormat.string(result.freedBytes))."
        loadRemnants()
    }

    func removeSelectedLeftovers() async {
        let urls = Array(selectedLeftovers)
        let result = await background { Trasher().trash(urls) }
        message = "Removed \(result.removedCount) leftover folders, freeing \(ByteFormat.string(result.freedBytes))."
        selectedLeftovers = []
        await scan()
    }

    var selectedLeftoverSize: Int64 {
        leftovers.filter { selectedLeftovers.contains($0.url) }.reduce(0) { $0 + $1.size }
    }
}
