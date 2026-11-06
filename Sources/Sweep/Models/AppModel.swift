import SwiftUI
import SweepCore

/// Shared state for the whole window: the selected screen and each screen's model.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// Opens the main window again after it was closed; set by the window itself.
    var openMainWindow: (() -> Void)?
    @Published var selection: Module = .overview {
        didSet { lastTab[selection.group.id] = selection }
    }
    /// The tab last used in each sidebar entry, so coming back lands where the user left off.
    private var lastTab: [String: Module] = [:]

    func open(_ group: NavGroup) {
        selection = lastTab[group.id] ?? group.modules[0]
    }

    let storage: StorageModel
    let cleanup: CleanupModel
    let history = HistoryModel()
    let explorer: ExplorerModel
    let duplicates: DuplicatesModel
    let trash: TrashBinModel
    let developer: DeveloperModel
    let docker = DockerModel()
    lazy var assistant = AssistantModel(app: self)

    let junk: JunkModel
    let nodeModules = NodeModulesModel()
    let privacy: PrivacyModel
    let optimization: OptimizationModel
    let uninstaller = UninstallerModel()
    let malware = MalwareModel()
    let maintenance = MaintenanceModel()
    let updater = UpdaterModel()
    let smartScan: SmartScanModel

    init() {
        let junk = JunkModel(), privacy = PrivacyModel(), optimization = OptimizationModel()
        let storage = StorageModel()
        self.storage = storage
        let cleanup = CleanupModel(storage: storage)
        self.cleanup = cleanup
        explorer = ExplorerModel(storage: storage)
        duplicates = DuplicatesModel(storage: storage)
        trash = TrashBinModel(storage: storage)
        developer = DeveloperModel(storage: storage, cleanup: cleanup)
        self.junk = junk
        self.privacy = privacy
        self.optimization = optimization
        smartScan = SmartScanModel(junk: junk, privacy: privacy, optimization: optimization)
    }
}

/// Runs Cleanup, Protection and Speed together and cleans everything in one go.
@MainActor
final class SmartScanModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning(String)
        case results(duration: TimeInterval)
        case running
        case done(freed: Int64, skipped: [String], message: String?)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var includeCleanup = true
    @Published var includeProtection = true
    @Published var includeSpeed = true

    let junk: JunkModel
    let privacy: PrivacyModel
    let optimization: OptimizationModel

    init(junk: JunkModel, privacy: PrivacyModel, optimization: OptimizationModel) {
        self.junk = junk
        self.privacy = privacy
        self.optimization = optimization
    }

    func scan() async {
        let started = Date()
        phase = .scanning("Looking for junk")
        await junk.scan()
        phase = .scanning("Checking privacy traces")
        await privacy.scan()
        phase = .scanning("Measuring performance")
        optimization.refresh()
        phase = .results(duration: Date().timeIntervalSince(started))
    }

    func runAll() async {
        phase = .running
        var freed: Int64 = 0
        if includeCleanup { freed += await junk.clean().freedBytes }
        if includeProtection { freed += await privacy.clean().freedBytes }
        if includeSpeed { optimization.runSelectedTasks() }
        phase = .done(freed: freed, skipped: privacy.skippedBrowsers,
                      message: includeSpeed ? optimization.lastMessage : nil)
    }

    func reset() { phase = .idle }
}
