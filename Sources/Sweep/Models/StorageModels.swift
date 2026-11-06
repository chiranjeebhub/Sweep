import AppKit
import SweepCore

/// The ObjC runtime also exports a `Category` type; pin the name to SweepCore's enum in this module.
typealias Category = SweepCore.Category

/// The scan behind Overview, Cleanup and Storage: what was found, classified and suggested.
@MainActor
final class StorageModel: ObservableObject {
    static let scanRootKey = "scan.root"

    @Published private(set) var result: ScanResult?
    @Published private(set) var summary: ScanSummary?
    @Published private(set) var recommendations: [Recommendation] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isLoading = false
    @Published private(set) var progressFiles = 0
    @Published private(set) var progressBytes: Int64 = 0
    @Published private(set) var volume: VolumeInfo?
    /// Nil when macOS doesn't let Sweep look inside the Trash yet.
    @Published private(set) var trashSize: Int64?
    @Published private(set) var trashCount = 0
    /// Suggestions from Developer tools and other analyzers, merged in with the scan's own.
    @Published private(set) var extraRecommendations: [Recommendation] = []

    private var progress: ScanProgress?
    private var timer: Timer?
    private var hasLoaded = false

    var scanRoot: URL {
        if let path = UserDefaults.standard.string(forKey: Self.scanRootKey), !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Everything to show in Cleanup: the scan's suggestions plus the analyzers', without duplicates.
    var allRecommendations: [Recommendation] {
        var seen = Set<String>()
        var merged: [Recommendation] = []
        // Analyzer items know more (leftover, superseded), so they win when both point at the same folder.
        for item in extraRecommendations + recommendations {
            let key = item.paths.sorted().joined(separator: "|")
            if !key.isEmpty, !seen.insert(key).inserted { continue }
            // Skip scan items inside a folder an analyzer already suggests as a whole, and the reverse.
            merged.append(item)
        }
        return merged.sorted { $0.size > $1.size }
    }

    var likelyRecoverable: Int64 { allRecommendations.filter { $0.tier == .likelySafe }.reduce(0) { $0 + $1.size } }
    var actionableCount: Int { allRecommendations.filter(\.isActionable).count }

    /// Loads the last saved scan once, so the Overview isn't empty after a restart.
    func loadSavedIfNeeded() async {
        refreshVolume()
        await refreshTrash()
        guard !hasLoaded else { return }
        hasLoaded = true
        isLoading = true
        let loaded: (ScanResult, [Recommendation], ScanSummary)? = await background {
            guard let result = ScanStore.load() else { return nil }
            return Self.analyze(result)
        }
        if let loaded, result == nil {
            apply(loaded)
        }
        isLoading = false
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        progressFiles = 0
        progressBytes = 0
        let progress = ScanProgress()
        self.progress = progress
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let progress = self.progress else { return }
                self.progressFiles = progress.files
                self.progressBytes = progress.bytes
            }
        }
        let root = scanRoot
        let analyzed = await background { () -> (ScanResult, [Recommendation], ScanSummary)? in
            let result = DiskScanner(root: root).scan(progress: progress)
            if progress.isCancelled { return nil }
            ScanStore.save(result)
            return Self.analyze(result)
        }
        timer?.invalidate()
        timer = nil
        self.progress = nil
        if let analyzed { apply(analyzed) }
        isScanning = false
        refreshVolume()
        await refreshTrash()
    }

    func cancelScan() { progress?.cancel() }

    nonisolated private static func analyze(_ result: ScanResult) -> (ScanResult, [Recommendation], ScanSummary) {
        Classifier().classify(result.root)
        let recommendations = RecommendationEngine.recommendations(for: result.root)
        return (result, recommendations, ScanSummary(root: result.root, recommendations: recommendations))
    }

    private func apply(_ analyzed: (ScanResult, [Recommendation], ScanSummary)) {
        result = analyzed.0
        recommendations = analyzed.1
        summary = analyzed.2
    }

    func setExtraRecommendations(_ items: [Recommendation]) { extraRecommendations = items }

    /// Drops suggestions whose folders were just removed, so the lists are right before the next scan.
    func forget(paths: Set<String>) {
        recommendations.removeAll { $0.paths.allSatisfy(paths.contains) }
        extraRecommendations.removeAll { $0.paths.allSatisfy(paths.contains) }
    }

    func refreshVolume() { volume = VolumeInfo.current(for: scanRoot) }

    func refreshTrash() async {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let found: (Int64, Int)? = await background {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return nil }
            return (FileSize.allocatedSize(of: url), items.filter { $0 != ".DS_Store" }.count)
        }
        trashSize = found?.0
        trashCount = found?.1 ?? 0
    }

    /// Recognized folders ranked for Overview's "Largest items".
    var largestRecognized: [ScanSummary.Location] { Array(summary?.recognizedLocations.prefix(8) ?? []) }

    /// The space on the disk that this scan did not cover (other users, the system, apps outside home).
    var notScanned: Int64 {
        guard let volume, let result else { return 0 }
        return max(0, volume.used - result.totalSize)
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Selection, review and the cleanup run for the Cleanup screen.
@MainActor
final class CleanupModel: ObservableObject {
    enum Filter: Hashable {
        case all
        case tier(Tier)
        case badge(String)
    }

    @Published var filter: Filter = .all
    @Published var selected: Set<String> = []
    @Published var expanded: Set<String> = []
    @Published var plan: CleanupPlan?
    @Published private(set) var isPlanning = false
    @Published private(set) var isRunning = false
    @Published private(set) var runProgress: (done: Int, total: Int) = (0, 0)
    @Published var message: String?

    let storage: StorageModel

    init(storage: StorageModel) {
        self.storage = storage
    }

    var visible: [Recommendation] {
        storage.allRecommendations.filter { item in
            switch filter {
            case .all: true
            case .tier(let tier): item.tier == tier
            case .badge(let badge): item.badge == badge
            }
        }
    }

    func size(of tier: Tier) -> Int64 { storage.allRecommendations.filter { $0.tier == tier }.reduce(0) { $0 + $1.size } }
    func count(badge: String) -> Int { storage.allRecommendations.filter { $0.badge == badge }.count }

    var selectedItems: [Recommendation] { storage.allRecommendations.filter { selected.contains($0.id) && $0.isActionable } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func toggle(_ item: Recommendation) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    func toggleExpanded(_ item: Recommendation) {
        if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
    }

    func selectAllLikelySafe() {
        for item in storage.allRecommendations where item.tier == .likelySafe && item.isActionable {
            selected.insert(item.id)
        }
    }

    func selectOnly(_ ids: [String]) {
        selected = Set(ids)
    }

    /// Builds the plan the user reviews: every path, checked and measured again.
    func review() async {
        let items = selectedItems
        guard !items.isEmpty else { return }
        isPlanning = true
        plan = await background { CleanupPlan(recommendations: items) }
        isPlanning = false
    }

    func run(permanently: Bool) async {
        guard let plan else { return }
        if plan.isExpired {
            message = "The review was more than ten minutes old, so it was checked again. Review it once more."
            await review()
            return
        }
        self.plan = nil
        isRunning = true
        runProgress = (0, plan.validItems.count)
        let method: CleanupMethod = permanently && plan.allowsPermanentDelete ? .delete : .trash
        let counter = ProgressCounter()
        let results = await background {
            CleanupExecutor(method: method).run(plan, onItem: { _ in counter.increment() })
        }
        _ = counter
        HistoryStore.shared.append(HistoryEntry(
            source: "Cleanup",
            operation: method == .trash ? "Moved to the Trash" : "Deleted permanently",
            items: results))
        let removed = Set(results.filter(\.succeeded).map(\.path))
        storage.forget(paths: removed)
        selected.subtract(selected.filter { id in !storage.allRecommendations.contains { $0.id == id } })
        let freed = results.filter(\.succeeded).reduce(0) { $0 + $1.bytes }
        let failures = results.filter { !$0.succeeded }.count
        message = (method == .trash ? "Moved \(ByteFormat.string(freed)) to the Trash." : "Freed \(ByteFormat.string(freed)).")
            + (failures > 0 ? " \(failures) item\(failures == 1 ? "" : "s") couldn't be removed; see History." : "")
        isRunning = false
        await storage.refreshTrash()
    }
}

/// Counts finished items from a background thread.
final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// History of every cleanup.
@MainActor
final class HistoryModel: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    @Published var expanded: Set<UUID> = []

    func reload() async {
        entries = await background { HistoryStore.shared.load() }
    }

    func clear() async {
        await background { HistoryStore.shared.clear() }
        await reload()
    }

    var totalFreed: Int64 { entries.reduce(0) { $0 + $1.freed } }
}
