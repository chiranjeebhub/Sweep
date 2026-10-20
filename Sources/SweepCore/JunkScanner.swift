import Foundation

/// One removable thing found by a scan: a cache folder, a log file, a large file.
public struct CleanableItem: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let size: Int64
    public let lastUsed: Date?

    public init(url: URL, name: String? = nil, size: Int64, lastUsed: Date? = nil) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.size = size
        self.lastUsed = lastUsed
    }
}

/// A group of junk shown as one row in System Junk ("User cache files").
public struct JunkCategory: Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case userCaches, userLogs, systemLogs, xcode
    }

    public var id: Kind { kind }
    public let kind: Kind
    public let title: String
    public let subtitle: String
    public let items: [CleanableItem]

    public var size: Int64 { items.reduce(0) { $0 + $1.size } }
}

/// Finds caches, logs and developer leftovers that apps recreate on their own.
public struct JunkScanner: Sendable {
    let home: URL
    let systemLibrary: URL
    /// Bundle identifiers whose caches are never offered for cleaning (this app, for one).
    let protectedNames: Set<String>

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemLibrary: URL = URL(fileURLWithPath: "/Library"),
        protectedNames: Set<String> = [Bundle.main.bundleIdentifier ?? "com.sweep.app"]
    ) {
        self.home = home
        self.systemLibrary = systemLibrary
        self.protectedNames = protectedNames
    }

    public func scan() -> [JunkCategory] {
        JunkCategory.Kind.allCases.map { scan($0) }
    }

    public func scan(_ kind: JunkCategory.Kind) -> JunkCategory {
        let library = home.appendingPathComponent("Library")
        switch kind {
        case .userCaches:
            return JunkCategory(
                kind: kind, title: "User cache files",
                subtitle: "Temporary data apps store to load faster",
                items: children(of: library.appendingPathComponent("Caches")))
        case .userLogs:
            return JunkCategory(
                kind: kind, title: "User log files",
                subtitle: "Diagnostic logs written by your apps",
                items: children(of: library.appendingPathComponent("Logs")))
        case .systemLogs:
            return JunkCategory(
                kind: kind, title: "System log files",
                subtitle: "Logs written by macOS and background services",
                items: children(of: systemLibrary.appendingPathComponent("Logs")))
        case .xcode:
            let developer = library.appendingPathComponent("Developer")
            let roots = [
                "Xcode/DerivedData",
                "Xcode/iOS DeviceSupport",
                "Xcode/watchOS DeviceSupport",
                "CoreSimulator/Caches",
            ].map { developer.appendingPathComponent($0) }
            return JunkCategory(
                kind: kind, title: "Xcode junk",
                subtitle: "Build products and device support files Xcode can rebuild",
                items: roots.flatMap { children(of: $0) })
        }
    }

    /// Each direct child of `folder` as one item, largest first. Empty children are skipped.
    func children(of folder: URL) -> [CleanableItem] {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { !protectedNames.contains($0.lastPathComponent) }
            // Items the user can't move to the Trash (owned by root, for example) aren't offered.
            .filter { fileManager.isDeletableFile(atPath: $0.path) }
            .compactMap { url -> CleanableItem? in
                let size = FileSize.allocatedSize(of: url, fileManager: fileManager)
                guard size > 0 else { return nil }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return CleanableItem(url: url, size: size, lastUsed: modified)
            }
            .sorted { $0.size > $1.size }
    }
}
