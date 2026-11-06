import SwiftUI
import SweepCore

/// An optional chat with Claude about this Mac's storage.
///
/// Claude only gets read-only tools over what Sweep already measured. It can select suggestions in
/// Cleanup, but removing anything still takes the user's own review and confirmation there.
@MainActor
final class AssistantModel: ObservableObject {
    struct Line: Identifiable {
        enum Role { case user, assistant, tool, error }
        let id = UUID()
        let role: Role
        let text: String
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var isThinking = false
    @Published private(set) var hasKey = APIKeyStore.load() != nil
    @Published var draft = ""

    private var conversation: [[String: Any]] = []
    private let app: AppModel

    init(app: AppModel) { self.app = app }

    func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hasKey = APIKeyStore.save(trimmed)
    }

    func refreshKey() { hasKey = APIKeyStore.load() != nil }

    func forgetKey() {
        APIKeyStore.delete()
        hasKey = false
    }

    func reset() {
        conversation = []
        lines = []
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking, let key = APIKeyStore.load() else { return }
        draft = ""
        lines.append(Line(role: .user, text: text))
        conversation.append(["role": "user", "content": text])
        isThinking = true
        defer { isThinking = false }
        let client = ClaudeClient(key: key)
        do {
            for _ in 0..<12 {
                let response = try await client.send(system: Self.system, tools: Self.tools, messages: conversation)
                let content = response["content"] as? [[String: Any]] ?? []
                // The whole content goes back unchanged on the next turn, thinking blocks included.
                conversation.append(["role": "assistant", "content": content])
                for block in content where block["type"] as? String == "text" {
                    if let text = block["text"] as? String, !text.isEmpty { lines.append(Line(role: .assistant, text: text)) }
                }
                let stop = response["stop_reason"] as? String
                if stop == "refusal" {
                    lines.append(Line(role: .error, text: "Claude declined to answer that."))
                    return
                }
                let calls = content.filter { $0["type"] as? String == "tool_use" }
                guard stop == "tool_use", !calls.isEmpty else {
                    if stop == "max_tokens" { lines.append(Line(role: .error, text: "The answer was cut off. Ask Claude to continue.")) }
                    return
                }
                var results: [[String: Any]] = []
                for call in calls {
                    let name = call["name"] as? String ?? ""
                    let input = call["input"] as? [String: Any] ?? [:]
                    lines.append(Line(role: .tool, text: Self.toolLabel(name, input)))
                    let output = runTool(name, input)
                    var result: [String: Any] = ["type": "tool_result", "tool_use_id": call["id"] as? String ?? "", "content": output.text]
                    if output.isError { result["is_error"] = true }
                    results.append(result)
                }
                conversation.append(["role": "user", "content": results])
            }
            lines.append(Line(role: .error, text: "Stopped after many steps. Ask a narrower question."))
        } catch {
            lines.append(Line(role: .error, text: error.localizedDescription))
            // Drop the unanswered question so the conversation stays valid for the next one.
            if conversation.last?["role"] as? String == "user" { conversation.removeLast() }
        }
    }

    // MARK: Prompt and tools

    static let system = """
    You are the assistant inside Sweep, a Mac disk cleaner. You help the user understand what uses space on their Mac \
    and what they could safely clean up. Use the tools to look at Sweep's last scan and analyses; don't guess sizes or paths.

    You can't delete anything. When the user wants to clean something, use select_for_cleanup with suggestion ids, then \
    tell them to review and confirm in Cleanup. Prefer suggestions in the "Likely safe" tier, explain the risks of \
    "Review first" ones, and never suggest removing personal documents, photos, keychains or anything in the "Keep" tier.

    If there is no scan yet, say so and suggest pressing Scan. Keep answers short and concrete, with sizes.
    """

    static func schema(_ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    static let tools: [[String: Any]] = [
        ["name": "disk_overview",
         "description": "Disk capacity and free space, when the last scan ran, space by category, and the total Sweep considers likely safe to remove.",
         "input_schema": schema()],
        ["name": "list_suggestions",
         "description": "Cleanup suggestions from the scan and developer tool analysis, largest first. Each has an id, title, size, tier (Likely safe, Review first, Keep), badge, path, why it's safe and its risks.",
         "input_schema": schema(["tier": ["type": "string", "enum": ["any", "likely_safe", "review_first"]],
                                 "limit": ["type": "integer", "description": "How many to return, at most 60."]], required: ["tier", "limit"])],
        ["name": "folder_contents",
         "description": "The largest subfolders of a folder from the last scan, with sizes. Use ~ for the home folder.",
         "input_schema": schema(["path": ["type": "string"]], required: ["path"])],
        ["name": "largest_files",
         "description": "The largest individual files found by the last scan.",
         "input_schema": schema(["limit": ["type": "integer", "description": "At most 50."]], required: ["limit"])],
        ["name": "developer_tools",
         "description": "Developer tools found (editors, AI agents, runtimes, build tools) with sizes, summaries and how much is worth reviewing.",
         "input_schema": schema()],
        ["name": "docker_usage",
         "description": "Docker's disk use by type with reclaimable amounts, if Docker has been checked in Sweep.",
         "input_schema": schema()],
        ["name": "select_for_cleanup",
         "description": "Select suggestions by id in Sweep's Cleanup screen so the user can review them. Nothing is removed.",
         "input_schema": schema(["ids": ["type": "array", "items": ["type": "string"]]], required: ["ids"])],
    ]

    static func toolLabel(_ name: String, _ input: [String: Any]) -> String {
        switch name {
        case "disk_overview": return "Looked at the disk overview"
        case "list_suggestions": return "Read cleanup suggestions"
        case "folder_contents": return "Looked inside \(input["path"] as? String ?? "a folder")"
        case "largest_files": return "Listed the largest files"
        case "developer_tools": return "Read the developer tools analysis"
        case "docker_usage": return "Read Docker's disk use"
        case "select_for_cleanup": return "Selected \((input["ids"] as? [Any])?.count ?? 0) suggestions in Cleanup"
        default: return name
        }
    }

    private func runTool(_ name: String, _ input: [String: Any]) -> (text: String, isError: Bool) {
        let storage = app.storage
        let size = { (bytes: Int64) in ByteFormat.string(bytes) }
        switch name {
        case "disk_overview":
            var out: [String] = []
            if let volume = storage.volume {
                out.append("Disk \(volume.name): \(size(volume.used)) used of \(size(volume.total)), \(size(volume.available)) free.")
            }
            guard let result = storage.result, let summary = storage.summary else {
                return ((out + ["No scan yet."]).joined(separator: "\n"), false)
            }
            out.append("Last scan \(RelativeDate.string(result.date)) of \(result.root.path): \(size(result.root.size)).")
            out.append("Likely safe to remove: \(size(storage.likelyRecoverable)).")
            if let trash = storage.trashSize { out.append("Trash: \(size(trash)).") }
            out.append("By category:")
            for category in summary.categories { out.append("- \(category.category.title): \(size(category.size))") }
            out.append("Unreadable folders: \(result.unreadable.count).")
            return (out.joined(separator: "\n"), false)

        case "list_suggestions":
            let tier = input["tier"] as? String ?? "any"
            let limit = min(max(input["limit"] as? Int ?? 20, 1), 60)
            let items = storage.allRecommendations.filter {
                switch tier {
                case "likely_safe": return $0.tier == .likelySafe
                case "review_first": return $0.tier == .reviewFirst
                default: return $0.tier != .keep
                }
            }
            if items.isEmpty { return ("No suggestions. A scan may be needed.", false) }
            let text = items.prefix(limit).map { item in
                "- id: \(item.id)\n  \(item.title) · \(size(item.size)) · \(item.tier.title)\(item.badge.map { " · \($0)" } ?? "")\n" +
                "  path: \(URL(fileURLWithPath: item.primaryPath).abbreviatedPath)\n  safe because: \(item.safeBecause)\n  risks: \(item.risks)" +
                (item.isActionable ? "" : "\n  removed with a command, not by Sweep: \(item.command ?? "")")
            }.joined(separator: "\n")
            return ("\(items.count) suggestions; showing \(min(limit, items.count)).\n" + text, false)

        case "folder_contents":
            guard let result = storage.result else { return ("No scan yet.", true) }
            var path = input["path"] as? String ?? "~"
            if path.hasPrefix("~") { path = FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst() }
            path = (path as NSString).standardizingPath
            guard let node = result.root.node(at: path) ?? (path == result.root.path ? result.root : nil) else {
                return ("That folder isn't in the last scan.", true)
            }
            let children = node.children.sorted { $0.size > $1.size }.prefix(30)
            var text = "\(URL(fileURLWithPath: node.path).abbreviatedPath): \(size(node.size)), \(node.fileCount) files"
            if let rule = node.classification?.rule { text += ", recognized as \(rule.label)" }
            text += "\n" + children.map { "- \($0.name): \(size($0.size))" }.joined(separator: "\n")
            return (text, false)

        case "largest_files":
            guard let result = storage.result else { return ("No scan yet.", true) }
            let limit = min(max(input["limit"] as? Int ?? 20, 1), 50)
            return (result.largestFiles.prefix(limit).map {
                "- \(URL(fileURLWithPath: $0.path).abbreviatedPath): \(size($0.size)), modified \(RelativeDate.string($0.modified))"
            }.joined(separator: "\n"), false)

        case "developer_tools":
            let reports = app.developer.reports
            if reports.isEmpty { return ("The developer tools analysis hasn't run yet.", false) }
            return (reports.map { "- \($0.name)\($0.version.map { " \($0)" } ?? ""): \(size($0.totalSize)), \(size($0.reviewSize)) worth reviewing. \($0.summary)" }
                .joined(separator: "\n"), false)

        case "docker_usage":
            guard let snapshot = app.docker.snapshot else { return ("Docker hasn't been checked yet. The user can open the Docker screen.", false) }
            switch snapshot.status {
            case .notInstalled: return ("Docker isn't installed.", false)
            case .notRunning(let engine): return ("\(engine) isn't running.", false)
            case .running(let engine, let version):
                let rows = snapshot.usage.map { "- \($0.type): \(size($0.size)), \(size($0.reclaimable)) reclaimable" }
                return ((["\(engine), Docker \(version)"] + rows + ["Volumes: \(snapshot.volumes.count) (never removed by Sweep)"]).joined(separator: "\n"), false)
            }

        case "select_for_cleanup":
            let wanted = Set((input["ids"] as? [String]) ?? [])
            let valid = storage.allRecommendations.filter { wanted.contains($0.id) && $0.isActionable && $0.tier != .keep }
            guard !valid.isEmpty else { return ("None of those ids match a suggestion Sweep can remove.", true) }
            app.cleanup.filter = .all
            app.cleanup.selectOnly(valid.map(\.id))
            return ("Selected \(valid.count) suggestions (\(size(valid.reduce(0) { $0 + $1.size })) in total) in Cleanup. The user must review and confirm there.", false)

        default:
            return ("Unknown tool \(name).", true)
        }
    }
}
