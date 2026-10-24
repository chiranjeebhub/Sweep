import Foundation

/// A `node_modules` folder and the project it belongs to.
public struct NodeModulesFolder: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    /// The `node_modules` folder itself.
    public let url: URL
    public let size: Int64
    /// When the project's own files last changed, or nil when nothing in it could be dated.
    public let lastTouched: Date?

    public var project: URL { url.deletingLastPathComponent() }
    public var projectName: String { project.lastPathComponent }
    public var projectPath: String { project.abbreviatedPath }

    public init(url: URL, size: Int64, lastTouched: Date?) {
        self.url = url
        self.size = size
        self.lastTouched = lastTouched
    }

    /// Whole days since the project was last touched. Undated projects count as very old.
    public func daysSinceTouched(now: Date = Date()) -> Int {
        guard let lastTouched else { return .max }
        return max(0, Int(now.timeIntervalSince(lastTouched) / 86_400))
    }
}

/// How the Node Modules list is ordered.
public enum NodeModulesSort: String, CaseIterable, Identifiable, Sendable {
    case size = "Largest"
    case age = "Oldest"
    case name = "Name"
    public var id: String { rawValue }
}

extension Array where Element == NodeModulesFolder {
    /// Folders whose project hasn't been touched for at least `days` days.
    public func untouched(forAtLeast days: Int, now: Date = Date()) -> [NodeModulesFolder] {
        filter { $0.daysSinceTouched(now: now) >= days }
    }

    public func ordered(by order: NodeModulesSort) -> [NodeModulesFolder] {
        switch order {
        case .size:
            return sorted { $0.size > $1.size }
        case .age:
            return sorted { ($0.lastTouched ?? .distantPast) < ($1.lastTouched ?? .distantPast) }
        case .name:
            return sorted {
                $0.projectName.localizedStandardCompare($1.projectName) == .orderedAscending
            }
        }
    }
}

/// Finds `node_modules` folders under the home folder and works out how long ago each project was worked on.
///
/// The search skips `~/Library`, hidden folders, app bundles and other packages, and never looks inside a
/// `node_modules` folder for more of them.
public struct NodeModulesScanner: Sendable {
    /// Folders inside a project that change on their own (installs, builds, caches), so they don't count
    /// as the project being worked on. Hidden folders such as `.git` and `.next` are ignored as well.
    public static let ignoredProjectFolders: Set<String> = [
        "node_modules", "dist", "build", "out", "coverage", "target", "tmp", "bower_components",
    ]

    /// The most files looked at when dating one project, so a stray `node_modules` in a huge folder
    /// doesn't stall the scan.
    static let maxFilesPerProject = 20_000

    let roots: [URL]
    let skipped: Set<String>
    /// Last path components of `skipped`, so most folders can be ruled out without resolving their path.
    let skippedNames: Set<String>

    public init(roots: [URL]? = nil, skipping: [URL]? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.roots = roots ?? [home]
        let skipping = skipping ?? [home.appendingPathComponent("Library")]
        skipped = Set(skipping.map { $0.resolvingSymlinksInPath().path })
        skippedNames = Set(skipping.map(\.lastPathComponent))
    }

    /// All `node_modules` folders found, largest first.
    public func scan() -> [NodeModulesFolder] {
        let folders = findFolders()
        var results = [NodeModulesFolder?](repeating: nil, count: folders.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: folders.count) { index in
            let url = folders[index]
            let folder = NodeModulesFolder(
                url: url,
                size: FileSize.allocatedSize(of: url),
                lastTouched: Self.lastTouched(project: url.deletingLastPathComponent()))
            lock.lock()
            results[index] = folder
            lock.unlock()
        }
        return results.compactMap { $0 }.ordered(by: .size)
    }

    /// The `node_modules` folders under the roots, without measuring them.
    public func findFolders() -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        var found: [URL] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                if skippedNames.contains(url.lastPathComponent), skipped.contains(url.resolvingSymlinksInPath().path) {
                    enumerator.skipDescendants()
                } else if url.lastPathComponent == "node_modules" {
                    found.append(url)
                    enumerator.skipDescendants()
                }
            }
        }
        return found
    }

    /// When the project's own files last changed. Installs, build output, `.git` and other hidden folders
    /// don't count. When there is nothing else to go by, the last git activity is used.
    public static func lastTouched(project: URL) -> Date? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        var latest: Date?
        if let enumerator = FileManager.default.enumerator(
            at: project,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) {
            var count = 0
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true {
                    if ignoredProjectFolders.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                    continue
                }
                if let date = values.contentModificationDate, date > (latest ?? .distantPast) { latest = date }
                count += 1
                if count >= maxFilesPerProject { break }
            }
        }
        return latest ?? lastGitActivity(project: project)
    }

    /// The time of the last commit, checkout or pull in the project's git repository, read from
    /// `.git/logs/HEAD` so no git tools are needed.
    public static func lastGitActivity(project: URL) -> Date? {
        let log = project.appendingPathComponent(".git/logs/HEAD")
        guard let text = try? String(contentsOf: log, encoding: .utf8),
              let line = text.split(separator: "\n").last else { return nil }
        // "<old> <new> Name <email> <unix time> <zone>\t<message>"
        let header = line.split(separator: "\t", maxSplits: 1).first ?? line
        let parts = header.split(separator: " ")
        guard parts.count >= 2, let seconds = TimeInterval(parts[parts.count - 2]) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
