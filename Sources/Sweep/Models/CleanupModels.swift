import AppKit
import SweepCore

/// State for System Junk.
@MainActor
final class JunkModel: ObservableObject {
    @Published private(set) var categories: [JunkCategory] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var hasScanned = false
    @Published var focusedCategory: JunkCategory.Kind = .userCaches
    /// Items the user unticked. Everything else found by the scan is selected.
    @Published var excluded: Set<URL> = []

    func scan() async {
        isScanning = true
        let found = await background { JunkScanner().scan() }
        categories = found
        excluded = []
        if let first = found.first(where: { !$0.items.isEmpty }) { focusedCategory = first.kind }
        hasScanned = true
        isScanning = false
    }

    var totalSize: Int64 { categories.reduce(0) { $0 + $1.size } }
    var selectedItems: [CleanableItem] { categories.flatMap(\.items).filter { !excluded.contains($0.url) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var focused: JunkCategory? { categories.first { $0.kind == focusedCategory } }

    func isSelected(_ item: CleanableItem) -> Bool { !excluded.contains(item.url) }

    func setSelected(_ item: CleanableItem, _ on: Bool) {
        if on { excluded.remove(item.url) } else { excluded.insert(item.url) }
    }

    /// A category is ticked when at least one of its items is.
    func isSelected(_ category: JunkCategory) -> Bool {
        category.items.contains { !excluded.contains($0.url) }
    }

    func setSelected(_ category: JunkCategory, _ on: Bool) {
        for item in category.items { setSelected(item, on) }
    }

    func selectedSize(of category: JunkCategory) -> Int64 {
        category.items.filter { !excluded.contains($0.url) }.reduce(0) { $0 + $1.size }
    }

    @discardableResult
    func clean() async -> CleanResult {
        isCleaning = true
        let urls = selectedItems.map(\.url)
        let result = await background { Trasher().trash(urls) }
        LastRun.mark(.cleanup)
        isCleaning = false
        await scan()
        return result
    }
}

/// State for Large & Old Files.
@MainActor
final class LargeFilesModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All files"
        case overOneGB = "Over 1 GB"
        case unusedYear = "Not opened in a year"
        case downloads = "Downloads"
        case videos = "Videos"
        case archives = "Archives"
        case diskImages = "Disk images"
        var id: String { rawValue }
    }

    @Published private(set) var files: [LargeFile] = []
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published var selected: Set<URL> = []
    @Published var filter: Filter = .all
    @Published var search = ""

    func scan() async {
        isScanning = true
        files = await background { LargeFileScanner().scan() }
        selected = selected.filter { url in files.contains { $0.url == url } }
        hasScanned = true
        isScanning = false
    }

    var visibleFiles: [LargeFile] {
        let yearAgo = Date().addingTimeInterval(-365 * 24 * 60 * 60)
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        return files.filter { file in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .overOneGB: matchesFilter = file.size >= 1_000_000_000
            case .unusedYear: matchesFilter = (file.lastOpened ?? .distantPast) < yearAgo
            case .downloads: matchesFilter = file.url.path.hasPrefix(downloads)
            case .videos: matchesFilter = file.kind == .video
            case .archives: matchesFilter = file.kind == .archive
            case .diskImages: matchesFilter = file.kind == .diskImage
            }
            return matchesFilter && (search.isEmpty || file.name.localizedCaseInsensitiveContains(search))
        }
    }

    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
    var selectedFiles: [LargeFile] { files.filter { selected.contains($0.url) } }
    var selectedSize: Int64 { selectedFiles.reduce(0) { $0 + $1.size } }

    func size(of kind: LargeFile.Kind) -> Int64 {
        files.filter { $0.kind == kind }.reduce(0) { $0 + $1.size }
    }

    func revealSelected() {
        NSWorkspace.shared.activateFileViewerSelecting(selectedFiles.map(\.url))
    }

    func removeSelected() async {
        let urls = Array(selected)
        _ = await background { Trasher().trash(urls) }
        selected = []
        await scan()
    }
}

/// State for Trash Bins.
@MainActor
final class TrashModel: ObservableObject {
    /// Nil when macOS doesn't let the app look inside the Trash yet.
    @Published private(set) var size: Int64?
    @Published private(set) var itemCount = 0
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    private var trashURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash") }

    func refresh() async {
        let url = trashURL
        let result: (Int64, Int)? = await background {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return nil }
            return (FileSize.allocatedSize(of: url), items.filter { $0 != ".DS_Store" }.count)
        }
        size = result?.0
        itemCount = result?.1 ?? 0
    }

    /// Asks Finder to empty the Trash, the same as choosing Finder > Empty Trash.
    func empty() async {
        isWorking = true
        // NSAppleScript must run on the main thread.
        var error: NSDictionary?
        _ = NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
        errorMessage = error?[NSAppleScript.errorMessage] as? String
        isWorking = false
        await refresh()
    }
}
