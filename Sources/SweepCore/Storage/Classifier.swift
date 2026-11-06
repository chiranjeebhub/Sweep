import Foundation

/// The kind of data a folder holds. Every folder in a scan ends up in exactly one.
public enum Category: String, CaseIterable, Codable, Sendable, Identifiable {
    case applicationData, cache, buildArtifacts, developerTools, dockerStorage, logs, downloads, userData, binaryData, systemFiles, unknown

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .applicationData: "Application data"
        case .cache: "Cache"
        case .buildArtifacts: "Build artifacts"
        case .developerTools: "Developer tools"
        case .dockerStorage: "Docker storage"
        case .logs: "Logs"
        case .downloads: "Downloads"
        case .userData: "User data"
        case .binaryData: "Large binary data"
        case .systemFiles: "System files"
        case .unknown: "Unrecognized"
        }
    }
}

/// How sure a rule is about what it matched.
public enum Confidence: String, Codable, Sendable, Comparable {
    case low, medium, high

    public var title: String { rawValue.capitalized }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        let order: [Confidence] = [.low, .medium, .high]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

/// How much Sweep trusts an item to be safe to remove.
public enum Tier: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Well understood and regenerated automatically. Still reviewed and confirmed by the user.
    case likelySafe
    /// Possibly disposable, but something may still depend on it.
    case reviewFirst
    /// Important or not understood well enough. Explained, never offered for removal.
    case keep

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .likelySafe: "Likely safe"
        case .reviewFirst: "Review first"
        case .keep: "Keep"
        }
    }

    public var blurb: String {
        switch self {
        case .likelySafe: "Well understood, regenerated automatically. Still reviewed and confirmed by you."
        case .reviewFirst: "Probably disposable, but a project or app may still need it."
        case .keep: "Important or not understood well enough. Explained, never offered for removal."
        }
    }
}

/// What Sweep may do with an item.
public enum CleanupMethod: String, Codable, Sendable {
    case trash, delete
}

/// How a cleanup policy turns a matched folder into suggestions.
public enum Expansion: Sendable {
    /// One suggestion for the whole folder.
    case whole
    /// One suggestion per folder inside it (one per app cache, for example).
    case children
    /// One suggestion per folder inside a fixed subfolder.
    case childrenOf(String)
}

/// How a rule's matches should be cleaned up. A rule without a policy only explains.
public struct Policy: Sendable {
    public let tier: Tier
    public let methods: [CleanupMethod]
    public let safeBecause: String
    public let risks: String
    public let action: String
    /// A command the user can run themselves instead. Sweep never runs it.
    public let command: String?
    public let expansion: Expansion
    public let minimumSize: Int64
    public let beforeYouStart: String?

    public init(_ tier: Tier, methods: [CleanupMethod] = [.trash, .delete], safe: String, risks: String, action: String,
                command: String? = nil, expansion: Expansion = .whole, minimumSize: Int64 = 50_000_000, before: String? = nil) {
        self.tier = tier
        self.methods = tier == .keep ? [] : methods
        self.safeBecause = safe
        self.risks = risks
        self.action = action
        self.command = command
        self.expansion = expansion
        self.minimumSize = minimumSize
        self.beforeYouStart = before
    }
}

/// Which folders a rule matches.
public enum Matcher: Sendable {
    /// A path inside the home folder, by its components.
    case home([String])
    /// An absolute path.
    case absolute(String)
    /// A folder with one of these names, anywhere.
    case name(Set<String>)
    /// A folder with one of these names, next to one of these files (`target` beside `Cargo.toml`).
    case nameBeside(Set<String>, [String])
    /// A folder that directly contains one of these entries (a folder holding `.git`). Never the home folder.
    case containing([String])
}

/// One classification rule: what a folder is and, optionally, how to clean it up.
public struct Rule: Sendable, Identifiable {
    public let id: String
    let matcher: Matcher
    /// A leaf owns everything inside it: no other rule is tried below it.
    public let isLeaf: Bool
    public let category: Category
    public let confidence: Confidence
    public let label: String
    public let explanation: String
    public let policy: Policy?
    /// Position in the table. When several rules match, the first wins.
    let order: Int
}

/// What a folder was classified as, and where that came from.
public struct Classification: Sendable {
    public let rule: Rule
    /// The folder the rule matched: this folder, or a parent it was inherited from.
    public let originPath: String
}

/// Matches folders against the rule table.
public struct Classifier: Sendable {
    let home: String
    private let homeRules: [String: Rule]
    private let absoluteRules: [String: Rule]
    private let nameRules: [String: [Rule]]
    private let besideRules: [String: [Rule]]
    private let containingRules: [Rule]

    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path, rules: [Rule] = RuleTable.all) {
        self.home = home.hasSuffix("/") ? String(home.dropLast()) : home
        var homeRules: [String: Rule] = [:], absoluteRules: [String: Rule] = [:]
        var nameRules: [String: [Rule]] = [:], besideRules: [String: [Rule]] = [:], containing: [Rule] = []
        for rule in rules {
            switch rule.matcher {
            case .home(let parts): if homeRules[parts.joined(separator: "/")] == nil { homeRules[parts.joined(separator: "/")] = rule }
            case .absolute(let path): if absoluteRules[path] == nil { absoluteRules[path] = rule }
            case .name(let names): for name in names { nameRules[name, default: []].append(rule) }
            case .nameBeside(let names, _): for name in names { besideRules[name, default: []].append(rule) }
            case .containing: containing.append(rule)
            }
        }
        self.homeRules = homeRules
        self.absoluteRules = absoluteRules
        self.nameRules = nameRules
        self.besideRules = besideRules
        self.containingRules = containing
    }

    /// The first rule that matches a folder, if any.
    func match(path: String, name: String, childNames: () -> Set<String>) -> Rule? {
        var candidates: [Rule] = []
        if path.hasPrefix(home + "/") {
            let relative = String(path.dropFirst(home.count + 1))
            if let rule = homeRules[relative] { candidates.append(rule) }
        }
        if let rule = absoluteRules[path] { candidates.append(rule) }
        if let rules = nameRules[name] { candidates += rules }
        if let rules = besideRules[name] {
            let parent = (path as NSString).deletingLastPathComponent
            for rule in rules {
                guard case .nameBeside(_, let siblings) = rule.matcher else { continue }
                if siblings.contains(where: { FileManager.default.fileExists(atPath: parent + "/" + $0) }) {
                    candidates.append(rule)
                }
            }
        }
        if !containingRules.isEmpty, path != home {
            let names = childNames()
            for rule in containingRules {
                guard case .containing(let entries) = rule.matcher else { continue }
                if entries.contains(where: names.contains) { candidates.append(rule) }
            }
        }
        return candidates.min { $0.order < $1.order }
    }

    /// Classifies every folder in a scanned tree, parents first.
    public func classify(_ root: DirNode) {
        var stack: [(DirNode, Classification?)] = [(root, nil)]
        while let item = stack.popLast() {
            let (node, inherited) = item
            if let inherited, inherited.rule.isLeaf {
                node.ownRule = nil
                node.classification = inherited
            } else if let rule = match(path: node.path, name: node.name, childNames: { Set(node.children.map(\.name)) }) {
                node.ownRule = rule
                node.classification = Classification(rule: rule, originPath: node.path)
            } else {
                node.ownRule = nil
                node.classification = inherited
            }
            for child in node.children { stack.append((child, node.classification)) }
        }
    }

    /// The category for a file with this extension inside a folder classified as `folder`.
    public static func fileCategory(for path: String, in folder: Classification?) -> (Category, String) {
        let ext = (path as NSString).pathExtension.lowercased()
        if let rule = folder?.rule, rule.isLeaf || !rule.allowsFileRules {
            return (rule.category, rule.label)
        }
        if let match = RuleTable.fileKinds.first(where: { $0.extensions.contains(ext) }) {
            return (match.category, match.label)
        }
        return (folder?.rule.category ?? .unknown, folder?.rule.label ?? "File")
    }
}

extension Rule {
    /// Containers like Documents let file types refine what is inside; Downloads stays Downloads.
    var allowsFileRules: Bool { !isLeaf && [Category.userData, .unknown].contains(category) }
}
