import Darwin
import Foundation

/// Decides whether Sweep may touch a path at all. Every path is checked when a plan is made
/// and again immediately before it is moved or deleted.
public enum SafetyGate {
    /// Folders that are never removed themselves, though things inside some of them can be.
    static func protectedPaths(home: String) -> Set<String> {
        let inHome = [
            "", "Library", "Library/Application Support", "Library/Caches", "Library/Containers", "Library/Group Containers",
            "Library/Preferences", "Library/Logs", "Library/Developer", "Library/Developer/Xcode", "Documents", "Desktop",
            "Downloads", "Pictures", "Movies", "Music", "Public", "Applications", ".Trash", ".config", ".local", ".local/share",
            ".cache", ".npm", ".cargo", ".rustup", ".gradle", ".nvm", ".docker",
        ]
        return Set(inHome.map { $0.isEmpty ? home : home + "/" + $0 })
    }

    /// Places nothing inside may ever be removed.
    static func forbiddenPrefixes(home: String) -> [String] {
        [".ssh", ".gnupg", "Library/Keychains", "Library/Mobile Documents", "Library/CloudStorage", "Library/Mail",
         "Library/Messages", "Library/Accounts", "Library/Cookies", "Library/Containers/com.docker.docker",
         "Pictures/Photos Library.photoslibrary"].map { home + "/" + $0 }
    }

    /// Nil when the path may be cleaned up, otherwise why not.
    public static func problem(with path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String? {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard path.hasPrefix("/") else { return "Not an absolute path." }
        let standardized = (path as NSString).standardizingPath
        guard standardized == path, !path.contains("/../"), !path.hasSuffix("/..") else { return "The path isn't in its simplest form." }
        guard path.hasPrefix(home + "/") else { return "Sweep only cleans up inside your home folder." }
        if protectedPaths(home: home).contains(path) { return "This folder is protected." }
        if forbiddenPrefixes(home: home).contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "This location holds personal data and is never cleaned up."
        }
        // No symbolic link anywhere from the home folder down, so the path can't lead somewhere else.
        var current = path
        while current.count > home.count {
            var info = stat()
            if lstat(current, &info) != 0 {
                return current == path ? "It no longer exists." : "A folder on the way no longer exists."
            }
            if (info.st_mode & S_IFMT) == S_IFLNK { return "The path goes through a symbolic link." }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }
}

/// What happened to one path during a cleanup.
public struct CleanupItemResult: Codable, Hashable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let bytes: Int64
    public let error: String?
    public var succeeded: Bool { error == nil }

    public init(path: String, bytes: Int64, error: String?) {
        self.path = path
        self.bytes = bytes
        self.error = error
    }
}

/// A checked list of paths, measured again just before the user confirms.
public struct CleanupPlan: Sendable {
    public struct Item: Identifiable, Sendable {
        public var id: String { path }
        public let path: String
        public let title: String
        public let size: Int64
        /// Why the path was left out of the plan, if it was.
        public let problem: String?
    }

    public let items: [Item]
    /// Every item allows deleting outright, because it is all regenerable data.
    public let allowsPermanentDelete: Bool
    public let beforeYouStart: [String]
    public let created = Date()

    public var validItems: [Item] { items.filter { $0.problem == nil } }
    public var totalSize: Int64 { validItems.reduce(0) { $0 + $1.size } }
    /// Plans expire, so nothing runs on measurements that are out of date.
    public var isExpired: Bool { Date().timeIntervalSince(created) > 600 }

    public init(recommendations: [Recommendation], home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        var items: [Item] = []
        for recommendation in recommendations where recommendation.isActionable {
            for path in recommendation.paths {
                let problem = SafetyGate.problem(with: path, home: home)
                let size = problem == nil ? FileSize.allocatedSize(of: URL(fileURLWithPath: path)) : 0
                items.append(Item(path: path, title: recommendation.title, size: size, problem: problem))
            }
        }
        self.items = items
        let actionable = recommendations.filter(\.isActionable)
        allowsPermanentDelete = !actionable.isEmpty && actionable.allSatisfy(\.allowsPermanentDelete)
        beforeYouStart = Array(Set(actionable.compactMap(\.beforeYouStart))).sorted()
    }

    /// A plan for paths that are not from recommendations (duplicates, node_modules folders, Trash items).
    public init(paths: [(path: String, title: String)], allowsPermanentDelete: Bool,
                home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        items = paths.map { entry in
            let problem = SafetyGate.problem(with: entry.path, home: home)
            let size = problem == nil ? FileSize.allocatedSize(of: URL(fileURLWithPath: entry.path)) : 0
            return Item(path: entry.path, title: entry.title, size: size, problem: problem)
        }
        self.allowsPermanentDelete = allowsPermanentDelete
        beforeYouStart = []
    }
}

/// Carries out a plan, one path at a time, checking each again right before it is touched.
public struct CleanupExecutor: Sendable {
    public let method: CleanupMethod
    let home: String

    public init(method: CleanupMethod, home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.method = method
        self.home = home
    }

    public func run(_ plan: CleanupPlan, shouldStop: @Sendable () -> Bool = { false },
                    onItem: @Sendable (CleanupItemResult) -> Void = { _ in }) -> [CleanupItemResult] {
        var results: [CleanupItemResult] = []
        for item in plan.validItems {
            if shouldStop() { break }
            let result = remove(path: item.path, expectedSize: item.size)
            results.append(result)
            onItem(result)
        }
        return results
    }

    public func remove(path: String, expectedSize: Int64? = nil) -> CleanupItemResult {
        if let problem = SafetyGate.problem(with: path, home: home) {
            return CleanupItemResult(path: path, bytes: 0, error: problem)
        }
        let url = URL(fileURLWithPath: path)
        let size = expectedSize ?? FileSize.allocatedSize(of: url)
        do {
            switch method {
            case .trash: try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            // removeItem deletes symbolic links themselves rather than what they point to.
            case .delete: try FileManager.default.removeItem(at: url)
            }
            return CleanupItemResult(path: path, bytes: size, error: nil)
        } catch {
            return CleanupItemResult(path: path, bytes: 0, error: error.localizedDescription)
        }
    }
}

/// One entry in History.
public struct HistoryEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    /// Where it was done: "Cleanup", "Duplicates", "Docker", "Empty Trash"…
    public let source: String
    /// What was done: "Moved to the Trash", "Deleted permanently", or the command that ran.
    public let operation: String
    public let items: [CleanupItemResult]

    public init(source: String, operation: String, items: [CleanupItemResult], date: Date = Date()) {
        id = UUID()
        self.date = date
        self.source = source
        self.operation = operation
        self.items = items
    }

    public var freed: Int64 { items.filter(\.succeeded).reduce(0) { $0 + $1.bytes } }
    public var failures: Int { items.filter { !$0.succeeded }.count }
}

/// Every cleanup Sweep has done, kept in Application Support so it survives restarts.
public final class HistoryStore: @unchecked Sendable {
    public static let shared = HistoryStore()
    private let lock = NSLock()
    private let url: URL

    public init(url: URL = SweepFolders.support.appendingPathComponent("history.json")) {
        self.url = url
    }

    public func load() -> [HistoryEntry] {
        lock.sync {
            guard let data = try? Data(contentsOf: url) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
        }
    }

    public func append(_ entry: HistoryEntry) {
        var entries = load()
        entries.insert(entry, at: 0)
        if entries.count > 1_000 { entries.removeLast(entries.count - 1_000) }
        lock.sync {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(entries) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    public func clear() {
        lock.sync { _ = try? FileManager.default.removeItem(at: url) }
    }
}

/// Where Sweep keeps its own files.
public enum SweepFolders {
    public static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Sweep", isDirectory: true)
    }
}
