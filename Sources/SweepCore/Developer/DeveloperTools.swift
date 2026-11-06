import Foundation

/// A line in a tool's Details list.
public struct ToolDetail: Identifiable, Hashable, Sendable {
    public var id: String { path ?? title }
    public let title: String
    public let note: String?
    public let size: Int64?
    public let path: String?
    public let badge: String?

    public init(_ title: String, note: String? = nil, size: Int64? = nil, path: String? = nil, badge: String? = nil) {
        self.title = title
        self.note = note
        self.size = size
        self.path = path
        self.badge = badge
    }
}

/// What one developer tool keeps on disk, and what of it is worth reviewing.
public struct ToolReport: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let version: String?
    /// SF Symbol name.
    public let symbol: String
    public let totalSize: Int64
    public let summary: String
    /// Suggestions that feed into Cleanup.
    public let items: [Recommendation]
    public let details: [ToolDetail]

    public var reviewSize: Int64 { items.filter { $0.tier != .keep }.reduce(0) { $0 + $1.size } }
    public var reviewCount: Int { items.filter { $0.tier != .keep }.count }

    public var badgeCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for item in items { if let badge = item.badge { counts[badge, default: 0] += 1 } }
        for detail in details where !items.contains(where: { $0.primaryPath == detail.path }) {
            if let badge = detail.badge { counts[badge, default: 0] += 1 }
        }
        return counts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

/// Looks at the on-disk layout of editors, AI agents, runtimes and build tools.
///
/// Analyzers only read. Their suggestions go through the same review, plan and safety gate as everything else.
public struct DeveloperAnalyzer: Sendable {
    let home: String
    /// The classified scan, when there is one; used to find project folders without walking the disk again.
    let scan: DirNode?
    static let inactiveDays: Double = 90

    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path, scan: DirNode? = nil) {
        self.home = home
        self.scan = scan
    }

    /// Every analyzer, run in parallel. Tools that aren't installed are left out.
    public func analyzeAll() -> [ToolReport] {
        let analyzers: [@Sendable (DeveloperAnalyzer) -> ToolReport?] = [
            { $0.node() }, { $0.xcode() }, { $0.rust() }, { $0.python() },
            { $0.editor(id: "vscode", name: "VS Code", support: "Code", dotFolder: ".vscode", symbol: "chevron.left.forwardslash.chevron.right") },
            { $0.editor(id: "cursor", name: "Cursor", support: "Cursor", dotFolder: ".cursor", symbol: "cursorarrow.rays") },
            { $0.editor(id: "windsurf", name: "Windsurf", support: "Windsurf", dotFolder: ".windsurf", symbol: "wind") },
            { $0.claudeCode() }, { $0.claudeApp() }, { $0.codex() }, { $0.copilot() }, { $0.otherAgents() },
            { $0.localModels() }, { $0.homebrew() }, { $0.jetBrains() }, { $0.android() }, { $0.gradleAndJava() },
            { $0.goAndOthers() },
        ]
        var reports = [ToolReport?](repeating: nil, count: analyzers.count)
        let lock = NSLock()
        let analyzer = self
        DispatchQueue.concurrentPerform(iterations: analyzers.count) { index in
            let report = analyzers[index](analyzer)
            lock.sync { reports[index] = report }
        }
        var found = reports.compactMap { $0 }
        if let leftovers = olderVersionsAndLeftovers(found) { found.append(leftovers) }
        return found.sorted { $0.totalSize > $1.totalSize }
    }

    // MARK: Helpers

    func path(_ relative: String) -> String { home + "/" + relative }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    func size(_ path: String) -> Int64 { exists(path) ? FileSize.allocatedSize(of: URL(fileURLWithPath: path)) : 0 }
    func children(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
            .filter { $0 != ".DS_Store" }
            .map { path + "/" + $0 }
    }
    func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
    func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
    func json(_ path: String) -> Any? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
    func isInactive(_ date: Date?) -> Bool {
        guard let date else { return true }
        return Date().timeIntervalSince(date) > Self.inactiveDays * 86_400
    }

    /// Folders in the scan whose own rule is `ruleID`.
    func scanned(_ ruleID: String) -> [DirNode] {
        guard let scan else { return [] }
        var nodes: [DirNode] = []
        scan.walk { if $0.ownRule?.id == ruleID { nodes.append($0) } }
        return nodes
    }

    func item(_ tool: String, _ title: String, path: String, size: Int64, tier: Tier, category: Category,
              explanation: String, safe: String, risks: String, action: String, command: String? = nil,
              methods: [CleanupMethod] = [.trash, .delete], badge: String? = nil, lastActivity: Date? = nil,
              before: String? = nil, confidence: Confidence = .high) -> Recommendation {
        Recommendation(id: "dev.\(tool):\(path)", title: title, explanation: explanation, paths: [path], size: size, tier: tier,
                       category: category, confidence: confidence, safeBecause: safe, risks: risks, action: action, command: command,
                       methods: methods, beforeYouStart: before, ruleID: "dev.\(tool)", source: "Developer Tools", badge: badge,
                       lastActivity: lastActivity)
    }

    /// A cache folder that regenerates by itself.
    func cacheItem(_ tool: String, _ title: String, _ path: String, minimum: Int64 = 20_000_000, command: String? = nil,
                   before: String? = nil, badge: String? = nil, explanation: String? = nil) -> Recommendation? {
        let bytes = size(path)
        guard bytes >= minimum else { return nil }
        return item(tool, title, path: path, size: bytes, tier: .likelySafe, category: .cache,
                    explanation: explanation ?? "\(title). Rebuilt or downloaded again when needed.",
                    safe: "It is recreated automatically.", risks: "The next use is a little slower, or needs the network.",
                    action: "Remove it", command: command, badge: badge, before: before)
    }

    func report(_ id: String, _ name: String, version: String? = nil, symbol: String, total: Int64, summary: String,
                items: [Recommendation?], details: [ToolDetail] = []) -> ToolReport? {
        guard total > 0 || !details.isEmpty else { return nil }
        return ToolReport(id: id, name: name, version: version, symbol: symbol, totalSize: total, summary: summary,
                          items: items.compactMap { $0 }.sorted { $0.size > $1.size }, details: details)
    }

    static func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }

    /// Compares dotted version strings numerically ("1.10" > "1.9").
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let parse: (String) -> [Int] = { $0.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }
        let a = parse(lhs), b = parse(rhs)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Older versions and leftovers

    func olderVersionsAndLeftovers(_ reports: [ToolReport]) -> ToolReport? {
        let items = reports.flatMap(\.items).filter { $0.badge == "Superseded" || $0.badge == "Leftover" }
        guard !items.isEmpty else { return nil }
        let leftovers = items.filter { $0.badge == "Leftover" }.count
        let superseded = items.filter { $0.badge == "Superseded" }.count
        // These items stay listed under their own tool too; this card only gathers them.
        return ToolReport(id: "leftovers", name: "Older versions and leftovers", version: nil, symbol: "clock.arrow.circlepath",
                          totalSize: items.reduce(0) { $0 + $1.size },
                          summary: "\(Self.plural(superseded + leftovers, "item")) replaced by something newer or no longer needed.",
                          items: [], details: items.map { ToolDetail($0.title, note: $0.source, size: $0.size, path: $0.primaryPath, badge: $0.badge) })
    }
}
