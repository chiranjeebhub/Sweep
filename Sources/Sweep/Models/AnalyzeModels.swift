import AppKit
import SweepCore

/// One row in the Storage explorer: a folder from the scan, or a file read from disk.
struct ExplorerRow: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let isFolder: Bool
    let size: Int64
    let fileCount: Int?
    let modified: Date?
    let category: SweepCore.Category
    let label: String
    let unreadable: Bool
}

/// Browsing the scan: folders by size, and the largest files.
@MainActor
final class ExplorerModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case folders = "Folders"
        case largest = "Largest items"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case size = "Size", name = "Name", files = "Files", modified = "Modified"
        var id: String { rawValue }
    }

    enum LargestFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case overOneGB = "Over 1 GB"
        case untouchedYear = "Untouched for a year"
        case downloads = "In Downloads"
        case images = "Disk images & archives"
        case media = "Video & audio"
        case models = "Models & data"
        var id: String { rawValue }
    }

    @Published var tab: Tab = .folders
    @Published var currentPath: String?
    @Published var selectedPath: String?
    @Published var sort: Sort = .size
    @Published var search = ""
    @Published var categoryFilter: SweepCore.Category?
    @Published private(set) var files: [ExplorerRow] = []
    @Published private(set) var fileOverflow = 0

    @Published var largestFilter: LargestFilter = .all
    @Published var largestSearch = ""
    @Published var largestSelected: Set<String> = []
    @Published var plan: CleanupPlan?
    @Published var message: String?

    let storage: StorageModel
    static let listingLimit = 1_000

    init(storage: StorageModel) {
        self.storage = storage
    }

    var root: DirNode? { storage.result?.root }
    var current: DirNode? {
        guard let root else { return nil }
        if let currentPath, let node = root.node(at: currentPath) { return node }
        return root
    }

    /// The folders from the root down to the current one, for the path bar.
    var breadcrumbs: [DirNode] {
        var trail: [DirNode] = []
        var node = current
        while let current = node { trail.insert(current, at: 0); node = current.parent }
        return trail
    }

    func open(_ path: String) {
        currentPath = path
        selectedPath = nil
        Task { await loadFiles() }
    }

    /// Reads the files directly inside the current folder, which the scan only counted.
    func loadFiles() async {
        guard let node = current else { files = []; return }
        let path = node.path
        let classification = node.classification
        let limit = Self.listingLimit
        let listed: ([ExplorerRow], Int) = await background {
            let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
            guard let urls = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys) else {
                return ([], 0)
            }
            var rows: [ExplorerRow] = []
            for url in urls {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true || values.isSymbolicLink == true else { continue }
                let (category, label) = Classifier.fileCategory(for: url.path, in: classification)
                rows.append(ExplorerRow(path: url.path, name: url.lastPathComponent, isFolder: false,
                                        size: Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0),
                                        fileCount: nil, modified: values.contentModificationDate,
                                        category: category, label: label, unreadable: false))
            }
            rows.sort { $0.size > $1.size }
            let overflow = max(0, rows.count - limit)
            return (Array(rows.prefix(limit)), overflow)
        }
        if current?.path == path {
            files = listed.0
            fileOverflow = listed.1
        }
    }

    var rows: [ExplorerRow] {
        guard let node = current else { return [] }
        var rows = node.children.map { child in
            ExplorerRow(path: child.path, name: child.name, isFolder: true, size: child.size, fileCount: child.fileCount,
                        modified: child.modified, category: child.classification?.rule.category ?? .unknown,
                        label: child.classification?.rule.label ?? "Folder", unreadable: child.unreadable)
        }
        rows += files
        if !search.isEmpty { rows = rows.filter { $0.name.localizedCaseInsensitiveContains(search) } }
        if let categoryFilter { rows = rows.filter { $0.category == categoryFilter } }
        switch sort {
        case .size: rows.sort { $0.size > $1.size }
        case .name: rows.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .files: rows.sort { ($0.fileCount ?? 1) > ($1.fileCount ?? 1) }
        case .modified: rows.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }
        return rows
    }

    /// Suggestions by path, and how much can be cleaned up inside each folder.
    private var cleanupIndex: (byPath: [String: Recommendation], inside: [String: Int64], key: Int) = ([:], [:], -1)

    private func index() -> (byPath: [String: Recommendation], inside: [String: Int64]) {
        let all = storage.allRecommendations
        let key = all.count &* 31 &+ Int(truncatingIfNeeded: all.reduce(0) { $0 &+ $1.size })
        if cleanupIndex.key == key { return (cleanupIndex.byPath, cleanupIndex.inside) }
        var byPath: [String: Recommendation] = [:]
        var inside: [String: Int64] = [:]
        for item in all {
            for path in item.paths {
                byPath[path] = item
                guard item.isActionable else { continue }
                var parent = (path as NSString).deletingLastPathComponent
                while parent.count > 1 {
                    inside[parent, default: 0] += item.size
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
        }
        cleanupIndex = (byPath, inside, key)
        return (byPath, inside)
    }

    func recommendation(for path: String) -> Recommendation? { index().byPath[path] }
    func cleanable(inside path: String) -> Int64 { index().inside[path] ?? 0 }

    var selectedNode: DirNode? {
        guard let selectedPath else { return nil }
        return root?.node(at: selectedPath)
    }

    var selectedRow: ExplorerRow? {
        guard let selectedPath else { return nil }
        return rows.first { $0.path == selectedPath } ?? files.first { $0.path == selectedPath }
    }

    // MARK: Largest items

    struct LargestRow: Identifiable, Hashable {
        var id: String { path }
        let path: String
        let name: String
        let size: Int64
        let modified: Date?
        let category: SweepCore.Category
        let label: String
    }

    var largest: [LargestRow] {
        guard let result = storage.result else { return [] }
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path + "/"
        let yearAgo = Date().addingTimeInterval(-365 * 86_400)
        return result.largestFiles.compactMap { file -> LargestRow? in
            let folder = result.root.node(at: (file.path as NSString).deletingLastPathComponent)
            let (category, label) = Classifier.fileCategory(for: file.path, in: folder?.classification)
            let ext = (file.path as NSString).pathExtension.lowercased()
            let keep: Bool
            switch largestFilter {
            case .all: keep = true
            case .overOneGB: keep = file.size >= 1_000_000_000
            case .untouchedYear: keep = (file.modified ?? .distantPast) < yearAgo
            case .downloads: keep = file.path.hasPrefix(downloads)
            case .images: keep = ["dmg", "iso", "img", "zip", "tar", "gz", "tgz", "xz", "7z", "rar", "pkg", "xip", "sparseimage"].contains(ext)
            case .media: keep = ["mov", "mp4", "m4v", "mkv", "avi", "wav", "aiff", "flac", "mp3", "m4a"].contains(ext)
            case .models: keep = ["gguf", "safetensors", "ckpt", "pt", "pth", "onnx", "bin", "parquet", "csv", "sqlite", "db", "h5", "npy", "vmdk", "qcow2", "raw"].contains(ext)
            }
            guard keep, largestSearch.isEmpty || file.name.localizedCaseInsensitiveContains(largestSearch) else { return nil }
            return LargestRow(path: file.path, name: file.name, size: file.size, modified: file.modified, category: category, label: label)
        }
    }

    /// Folders holding the most data directly (not in subfolders): where files pile up.
    var accumulating: [DirNode] {
        guard let root else { return [] }
        var nodes: [DirNode] = []
        root.walk { if $0.ownSize >= 200_000_000 { nodes.append($0) } }
        return Array(nodes.sorted { $0.ownSize > $1.ownSize }.prefix(25))
    }

    var largestSelectedSize: Int64 { largest.filter { largestSelected.contains($0.path) }.reduce(0) { $0 + $1.size } }

    func reviewLargestSelection() async {
        let paths = largest.filter { largestSelected.contains($0.path) }.map { (path: $0.path, title: $0.name) }
        guard !paths.isEmpty else { return }
        plan = await background { CleanupPlan(paths: paths, allowsPermanentDelete: false) }
    }

    func runPlan(permanently: Bool) async {
        guard let plan else { return }
        self.plan = nil
        let results = await background { CleanupExecutor(method: .trash).run(plan) }
        HistoryStore.shared.append(HistoryEntry(source: "Largest items", operation: "Moved to the Trash", items: results))
        let freed = results.filter(\.succeeded).reduce(0) { $0 + $1.bytes }
        largestSelected.subtract(results.filter(\.succeeded).map(\.path))
        message = "Moved \(ByteFormat.string(freed)) to the Trash. Rescan to update the lists."
        await storage.refreshTrash()
    }
}

/// The duplicate finder: sets of identical files, and which copy stays.
@MainActor
final class DuplicatesModel: ObservableObject {
    @Published private(set) var groups: [DuplicateGroup] = []
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var phase = ""
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published var minimumSizeMB: Double = 1
    /// The copy that stays in each set, by set id. Defaults to the oldest copy.
    @Published var keepers: [String: String] = [:]
    /// Sets the user chose to clean up.
    @Published var included: Set<String> = []
    @Published var expanded: Set<String> = []
    @Published var plan: CleanupPlan?
    @Published var message: String?
    @Published var search = ""

    let storage: StorageModel
    private var progress: DuplicateProgress?
    private var timer: Timer?

    init(storage: StorageModel) {
        self.storage = storage
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        message = nil
        let progress = DuplicateProgress()
        self.progress = progress
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let progress = self.progress else { return }
                self.phase = progress.phase
                self.done = progress.done
                self.total = progress.total
            }
        }
        let root = storage.scanRoot
        let minimum = Int64(minimumSizeMB * 1_000_000)
        let found = await background { DuplicateFinder(roots: [root], minimumSize: minimum).find(progress: progress) }
        timer?.invalidate()
        timer = nil
        self.progress = nil
        groups = found
        keepers = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0.files[0].path) })
        included = []
        hasScanned = true
        isScanning = false
    }

    func cancel() { progress?.cancel() }

    var visibleGroups: [DuplicateGroup] {
        search.isEmpty ? groups : groups.filter { $0.files.contains { $0.name.localizedCaseInsensitiveContains(search) } }
    }

    var totalReclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimable } }

    func keeper(of group: DuplicateGroup) -> String { keepers[group.id] ?? group.files[0].path }

    /// The copies that would go: every copy in the chosen sets except the one kept.
    var copiesToRemove: [(path: String, keeper: String)] {
        groups.filter { included.contains($0.id) }.flatMap { group in
            let keeper = self.keeper(of: group)
            return group.files.filter { $0.path != keeper }.map { (path: $0.path, keeper: keeper) }
        }
    }

    var selectedReclaimable: Int64 {
        groups.filter { included.contains($0.id) }.reduce(0) { total, group in
            let keeper = self.keeper(of: group)
            return total + group.files.filter { $0.path != keeper && !$0.isClone }.reduce(0) { sum, _ in sum + group.size }
        }
    }

    func selectAll() { included = Set(visibleGroups.map(\.id)) }

    func review() async {
        let copies = copiesToRemove.map { (path: $0.path, title: "Copy of \(($0.keeper as NSString).lastPathComponent)") }
        guard !copies.isEmpty else { return }
        plan = await background { CleanupPlan(paths: copies, allowsPermanentDelete: false) }
    }

    func run() async {
        guard plan != nil else { return }
        plan = nil
        let copies = copiesToRemove
        let results = await background {
            copies.map { DuplicateFinder.removeCopy($0.path, keeping: $0.keeper) }
        }
        HistoryStore.shared.append(HistoryEntry(source: "Duplicates", operation: "Moved to the Trash", items: results))
        let removed = Set(results.filter(\.succeeded).map(\.path))
        groups = groups.compactMap { group in
            let files = group.files.filter { !removed.contains($0.path) }
            return files.count > 1 ? DuplicateGroup(id: group.id, size: group.size, files: files) : nil
        }
        included = included.filter { id in groups.contains { $0.id == id } }
        let freed = results.filter(\.succeeded).reduce(0) { $0 + $1.bytes }
        let failed = results.filter { !$0.succeeded }.count
        message = "Moved \(removed.count) cop\(removed.count == 1 ? "y" : "ies") (\(ByteFormat.string(freed))) to the Trash."
            + (failed > 0 ? " \(failed) were left alone; see History." : "")
        await storage.refreshTrash()
    }
}

/// The Trash, emptied item by item with live progress.
@MainActor
final class TrashBinModel: ObservableObject {
    enum State { case loading, notPermitted, loaded }

    @Published private(set) var items: [TrashItem] = []
    @Published private(set) var state: State = .loading
    @Published private(set) var isEmptying = false
    @Published private(set) var results: [String: CleanupItemResult] = [:]
    @Published private(set) var current: String?
    @Published var confirmEmpty = false
    @Published var message: String?
    private var stopRequested = false

    let storage: StorageModel

    init(storage: StorageModel) {
        self.storage = storage
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var doneCount: Int { results.count }

    func refresh() async {
        if isEmptying { return }
        let read = await background { TrashBins.items() }
        switch read {
        case .success(let found):
            items = found
            state = .loaded
        case .failure:
            items = []
            state = .notPermitted
        }
    }

    func empty() async {
        guard !items.isEmpty else { return }
        isEmptying = true
        stopRequested = false
        results = [:]
        message = nil
        var finished: [CleanupItemResult] = []
        for item in items {
            if stopRequested { break }
            current = item.path
            let result = await background { TrashBins.delete(item) }
            results[item.path] = result
            finished.append(result)
        }
        current = nil
        HistoryStore.shared.append(HistoryEntry(source: "Empty Trash", operation: "Deleted permanently", items: finished))
        let freed = finished.filter(\.succeeded).reduce(0) { $0 + $1.bytes }
        let failed = finished.filter { !$0.succeeded }.count
        message = (stopRequested ? "Stopped. " : "") + "Freed \(ByteFormat.string(freed))."
            + (failed > 0 ? " \(failed) item\(failed == 1 ? "" : "s") couldn't be deleted." : "")
        isEmptying = false
        await refresh()
        await storage.refreshTrash()
    }

    func stop() { stopRequested = true }

    /// Without Full Disk Access Sweep can't see inside the Trash, but Finder can still empty it.
    func emptyWithFinder() async {
        var error: NSDictionary?
        _ = NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
        message = (error?[NSAppleScript.errorMessage] as? String) ?? "Finder emptied the Trash."
        await storage.refreshTrash()
    }
}
