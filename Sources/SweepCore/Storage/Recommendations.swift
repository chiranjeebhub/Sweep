import Foundation

/// One explained cleanup suggestion. Nothing happens until the user picks it and confirms a plan.
public struct Recommendation: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let title: String
    /// What the item is.
    public let explanation: String
    public let paths: [String]
    public var size: Int64
    public let tier: Tier
    public let category: Category
    public let confidence: Confidence
    public let safeBecause: String
    public let risks: String
    public let action: String
    /// A command the user can run instead. Sweep shows it and never runs it.
    public let command: String?
    public let methods: [CleanupMethod]
    public let beforeYouStart: String?
    /// The rule or analyzer that produced it.
    public let ruleID: String
    /// Where it was found: "Scan", or a Developer tool's name.
    public let source: String
    /// "Leftover", "Superseded" or "Inactive" for items that are no longer needed.
    public let badge: String?
    /// When the related project was last worked on, for dependencies and build output.
    public var lastActivity: Date?

    public init(id: String, title: String, explanation: String, paths: [String], size: Int64, tier: Tier, category: Category,
                confidence: Confidence, safeBecause: String, risks: String, action: String, command: String? = nil,
                methods: [CleanupMethod], beforeYouStart: String? = nil, ruleID: String, source: String = "Scan",
                badge: String? = nil, lastActivity: Date? = nil) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.paths = paths
        self.size = size
        self.tier = tier
        self.category = category
        self.confidence = confidence
        self.safeBecause = safeBecause
        self.risks = risks
        self.action = action
        self.command = command
        self.methods = tier == .keep ? [] : methods
        self.beforeYouStart = beforeYouStart
        self.ruleID = ruleID
        self.source = source
        self.badge = badge
        self.lastActivity = lastActivity
    }

    /// Sweep can remove it itself, rather than only explaining or showing a command.
    public var isActionable: Bool { !methods.isEmpty }
    public var allowsPermanentDelete: Bool { methods.contains(.delete) }
    public var primaryPath: String { paths.first ?? "" }

    public static func == (lhs: Recommendation, rhs: Recommendation) -> Bool { lhs.id == rhs.id && lhs.size == rhs.size }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Turns a classified scan into suggestions by applying each matched rule's policy.
public enum RecommendationEngine {
    public static func recommendations(for root: DirNode) -> [Recommendation] {
        var results: [Recommendation] = []
        root.walk { node in
            guard let rule = node.ownRule, let policy = rule.policy else { return }
            let targets: [DirNode]
            switch policy.expansion {
            case .whole: targets = [node]
            case .children: targets = node.children.filter { $0.ownRule == nil }
            case .childrenOf(let name): targets = node.child(named: name)?.children.filter { $0.ownRule == nil } ?? []
            }
            for target in targets where target.size >= policy.minimumSize {
                let isWhole = target === node
                let title = isWhole ? rule.label : "\(rule.label) · \(displayName(target.name))"
                var lastActivity: Date?
                if rule.category == .buildArtifacts || ["node.modules", "python.venv", "cocoapods.pods"].contains(rule.id) {
                    lastActivity = NodeModulesScanner.lastTouched(project: target.url.deletingLastPathComponent())
                }
                let inactive = lastActivity.map { Date().timeIntervalSince($0) > 90 * 86_400 } ?? false
                results.append(Recommendation(
                    id: "\(rule.id):\(target.path)",
                    title: title,
                    explanation: rule.explanation,
                    paths: [target.path],
                    size: target.size,
                    tier: policy.tier,
                    category: rule.category,
                    confidence: rule.confidence,
                    safeBecause: policy.safeBecause,
                    risks: policy.risks,
                    action: policy.action,
                    command: policy.command,
                    methods: policy.methods,
                    beforeYouStart: policy.beforeYouStart,
                    ruleID: rule.id,
                    badge: inactive ? "Inactive" : nil,
                    lastActivity: lastActivity))
            }
        }
        return results.sorted { $0.size > $1.size }
    }

    /// A friendlier name for a folder: the project for build output, the app's name for an app cache when it can be guessed.
    static func displayName(_ name: String) -> String {
        name
    }
}

/// Totals for the Overview, worked out from a classified scan.
public struct ScanSummary: Sendable {
    public struct CategoryTotal: Identifiable, Sendable {
        public var id: Category { category }
        public let category: Category
        public let size: Int64
        /// The part of it Sweep suggests is likely safe to remove.
        public let recoverable: Int64
    }

    /// A folder Sweep recognized, for "Largest items" on the Overview.
    public struct Location: Identifiable, Sendable {
        public var id: String { path }
        public let path: String
        public let label: String
        public let category: Category
        public let size: Int64
        public let fileCount: Int
    }

    public let categories: [CategoryTotal]
    public let recognizedLocations: [Location]
    public let recoverable: Int64

    public init(root: DirNode, recommendations: [Recommendation]) {
        var totals: [Category: Int64] = [:]
        root.walk { node in
            totals[node.classification?.rule.category ?? .unknown, default: 0] += node.ownSize
        }
        var recoverableByCategory: [Category: Int64] = [:]
        for item in recommendations where item.tier == .likelySafe && item.source == "Scan" {
            recoverableByCategory[item.category, default: 0] += item.size
        }
        categories = totals.filter { $0.value > 0 }
            .map { CategoryTotal(category: $0.key, size: $0.value, recoverable: min($0.value, recoverableByCategory[$0.key] ?? 0)) }
            .sorted { $0.size > $1.size }
        recoverable = recommendations.filter { $0.tier == .likelySafe }.reduce(0) { $0 + $1.size }

        var locations: [Location] = []
        root.walk { node in
            guard let rule = node.ownRule, node !== root else { return }
            locations.append(Location(path: node.path, label: rule.label, category: rule.category, size: node.size, fileCount: node.fileCount))
        }
        // Keep the largest, and drop ones nested inside a larger one already listed.
        var kept: [Location] = []
        for location in locations.sorted(by: { $0.size > $1.size }) where kept.count < 40 {
            if kept.contains(where: { location.path.hasPrefix($0.path + "/") }) { continue }
            kept.append(location)
        }
        recognizedLocations = kept
    }
}
