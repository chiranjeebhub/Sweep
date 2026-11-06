import Foundation

extension DeveloperAnalyzer {
    // MARK: Shared helpers

    /// The folder a symbolic link points at, resolved against the link's own folder.
    func linkTarget(_ link: String) -> String? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else { return nil }
        if destination.hasPrefix("/") { return (destination as NSString).standardizingPath }
        return (((link as NSString).deletingLastPathComponent as NSString).appendingPathComponent(destination) as NSString).standardizingPath
    }

    /// Versions a self-updating CLI keeps side by side. The one the launcher links to is current; older ones are superseded.
    func installedVersions(tool: String, name: String, folder: String, launcher: String,
                           items: inout [Recommendation?], details: inout [ToolDetail], total: inout Int64) -> String? {
        let versions = children(folder)
        guard !versions.isEmpty else { return nil }
        let target = linkTarget(launcher)
        let current = versions.first { version in target.map { $0 == version || $0.hasPrefix(version + "/") } ?? false }
            ?? versions.max { Self.isNewer(($1 as NSString).lastPathComponent, than: ($0 as NSString).lastPathComponent) }
        let currentName = current.map { ($0 as NSString).lastPathComponent }
        for version in versions {
            let label = (version as NSString).lastPathComponent
            let bytes = size(version)
            total += bytes
            let isCurrent = version == current
            details.append(ToolDetail("\(name) \(label)", note: isCurrent ? "In use" : "Older version", size: bytes, path: version,
                                      badge: isCurrent ? nil : "Superseded"))
            if !isCurrent, bytes >= 1_000_000 {
                items.append(item(tool, "\(name) \(label)", path: version, size: bytes, tier: .likelySafe, category: .developerTools,
                                  explanation: "An older copy of \(name) kept after it updated itself to \(currentName ?? "a newer version").",
                                  safe: "The launcher points at the newer version, so nothing runs this one.",
                                  risks: "None, unless you pinned this version by hand.", action: "Remove it", badge: "Superseded"))
            }
        }
        return currentName
    }

    /// The working folder a transcript was recorded in, from its first lines.
    func transcriptFolder(_ file: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: file) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 64 * 1024)
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(40) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let cwd = object["cwd"] as? String { return cwd }
            if let payload = object["payload"] as? [String: Any], let cwd = payload["cwd"] as? String { return cwd }
        }
        return nil
    }

    func appVersion(_ app: String) -> String? {
        NSDictionary(contentsOfFile: app + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String
    }

    func sortedDetails(_ details: [ToolDetail]) -> [ToolDetail] { details.sorted { ($0.size ?? 0) > ($1.size ?? 0) } }

    // MARK: VS Code family

    func editor(id: String, name: String, support: String, dotFolder: String, symbol: String) -> ToolReport? {
        let apps = ["vscode": "/Applications/Visual Studio Code.app", "cursor": "/Applications/Cursor.app", "windsurf": "/Applications/Windsurf.app"]
        let shipIt = ["vscode": "com.microsoft.VSCode.ShipIt", "cursor": "com.todesktop.230313mzl4w4u92.ShipIt", "windsurf": "com.exafunction.windsurf.ShipIt"]
        let supportFolder = path("Library/Application Support/\(support)")
        let extensionsFolder = path("\(dotFolder)/extensions")
        guard exists(supportFolder) || exists(extensionsFolder) else { return nil }
        var items: [Recommendation?] = []
        var details: [ToolDetail] = []
        var total = size(supportFolder) + size(extensionsFolder)

        // Per-workspace state. workspace.json names the folder it belongs to.
        var leftovers = 0
        var leftoverSize: Int64 = 0
        for folder in children(supportFolder + "/User/workspaceStorage") where isDirectory(folder) {
            guard let info = json(folder + "/workspace.json") as? [String: Any],
                  let uri = (info["folder"] as? String) ?? (info["workspace"] as? String),
                  let url = URL(string: uri), url.isFileURL else { continue }
            guard !exists(url.path) else { continue }
            let bytes = size(folder)
            leftovers += 1
            leftoverSize += bytes
            details.append(ToolDetail(url.lastPathComponent, note: "Workspace state for a folder that no longer exists", size: bytes,
                                      path: folder, badge: "Leftover"))
            if bytes >= 1_000_000 {
                items.append(item(id, "\(name) workspace state · \(url.lastPathComponent)", path: folder, size: bytes, tier: .likelySafe,
                                  category: .applicationData,
                                  explanation: "\(name) kept history, search indexes and chat state for \(url.path), which no longer exists.",
                                  safe: "The folder is gone, so \(name) will never open this workspace again.",
                                  risks: "Chat history for that workspace is lost.", action: "Remove it", badge: "Leftover",
                                  lastActivity: modified(folder), before: "Quit \(name) first."))
            }
        }

        // Extensions: folders are publisher.name-version. Older versions linger until the editor's own cleanup runs.
        let obsolete = (json(extensionsFolder + "/.obsolete") as? [String: Any]).map { Set($0.keys) } ?? []
        var byID: [String: [String]] = [:]
        for folder in children(extensionsFolder) where isDirectory(folder) {
            let folderName = (folder as NSString).lastPathComponent
            guard let dash = folderName.range(of: "-[0-9]", options: [.regularExpression, .backwards]) else { continue }
            byID[String(folderName[..<dash.lowerBound]), default: []].append(folder)
        }
        var extensionCount = 0
        var superseded = 0
        for (extensionID, folders) in byID {
            extensionCount += 1
            let sorted = folders.sorted { Self.isNewer(($0 as NSString).lastPathComponent, than: ($1 as NSString).lastPathComponent) }
            for (index, folder) in sorted.enumerated() {
                let folderName = (folder as NSString).lastPathComponent
                let isOld = index > 0 || obsolete.contains(folderName)
                guard isOld else { continue }
                superseded += 1
                let bytes = size(folder)
                details.append(ToolDetail(folderName, note: "Replaced extension version", size: bytes, path: folder, badge: "Superseded"))
                items.append(item(id, "\(name) extension · \(folderName)", path: folder, size: bytes, tier: .likelySafe, category: .developerTools,
                                  explanation: "An older copy of \(extensionID) left behind after it updated.",
                                  safe: "\(name) loads the newest version; this one is only waiting to be cleaned up.",
                                  risks: "None.", action: "Remove it", badge: "Superseded", before: "Quit \(name) first."))
            }
        }

        // Caches and update downloads.
        for (title, relative) in [("Cache", "Cache"), ("Code cache", "Code Cache"), ("Compiled code cache", "CachedData"),
                                  ("Downloaded extension packages", "CachedExtensionVSIXs"), ("GPU cache", "GPUCache"), ("Logs", "logs")] {
            let folder = supportFolder + "/" + relative
            let bytes = size(folder)
            if bytes > 0 { details.append(ToolDetail("\(name) \(title.lowercased())", size: bytes, path: folder)) }
            items.append(cacheItem(id, "\(name) \(title.lowercased())", folder, minimum: 20_000_000, before: "Quit \(name) first."))
        }
        if let bundle = shipIt[id] {
            let folder = path("Library/Caches/\(bundle)")
            let bytes = size(folder)
            total += bytes
            items.append(cacheItem(id, "\(name) update download", folder, minimum: 20_000_000,
                                   explanation: "\(name) update packages already installed or waiting to install."))
        }
        let backup = supportFolder + "/User/globalStorage/state.vscdb.backup"
        let backupSize = size(backup)
        if backupSize >= 50_000_000 {
            items.append(item(id, "\(name) state backup", path: backup, size: backupSize, tier: .reviewFirst, category: .applicationData,
                              explanation: "A backup copy of \(name)'s global state database.",
                              safe: "\(name) writes a fresh backup when it next saves state.",
                              risks: "If the main state file is damaged before then, there's no copy to recover from.",
                              action: "Remove it", before: "Quit \(name) first."))
        }

        var summary = "\(Self.plural(extensionCount, "extension"))"
        if superseded > 0 { summary += ", \(superseded) older versions left behind" }
        if leftovers > 0 { summary += ". State for \(Self.plural(leftovers, "deleted workspace")) (\(ByteFormat.string(leftoverSize)))" }
        return report(id, name, version: apps[id].flatMap(appVersion), symbol: symbol, total: total, summary: summary + ".",
                      items: items, details: sortedDetails(details))
    }

    // MARK: Claude Code

    func claudeCode() -> ToolReport? {
        let config = path(".claude")
        let versionsFolder = path(".local/share/claude/versions")
        guard exists(config) || exists(versionsFolder) else { return nil }
        var items: [Recommendation?] = []
        var details: [ToolDetail] = []
        var total: Int64 = 0
        let version = installedVersions(tool: "claude-code", name: "Claude Code", folder: versionsFolder, launcher: path(".local/bin/claude"),
                                        items: &items, details: &details, total: &total)

        // Transcripts, one folder per project. Projects whose folder is gone are leftovers.
        var projects = 0
        var gone = 0
        for folder in children(config + "/projects") where isDirectory(folder) {
            projects += 1
            let bytes = size(folder)
            total += bytes
            let newest = children(folder).filter { $0.hasSuffix(".jsonl") }.max { (modified($0) ?? .distantPast) < (modified($1) ?? .distantPast) }
            let cwd = newest.flatMap(transcriptFolder)
            let missing = cwd.map { !exists($0) } ?? false
            let label = cwd.map { ($0 as NSString).lastPathComponent } ?? (folder as NSString).lastPathComponent
            if missing { gone += 1 }
            details.append(ToolDetail(label, note: missing ? "Transcripts for a folder that no longer exists" : "Transcripts",
                                      size: bytes, path: folder, badge: missing ? "Leftover" : (isInactive(modified(folder)) ? "Inactive" : nil)))
            if missing, bytes >= 1_000_000 {
                items.append(item("claude-code", "Claude Code transcripts · \(label)", path: folder, size: bytes, tier: .reviewFirst,
                                  category: .applicationData,
                                  explanation: "Conversation history for \(cwd ?? label), which no longer exists.",
                                  safe: "Claude Code only reads these to resume a session in that folder.",
                                  risks: "You can't resume or look back at those conversations.", action: "Remove them",
                                  badge: "Leftover", lastActivity: modified(folder)))
            }
        }
        for (title, relative) in [("Debug logs", "debug"), ("Shell snapshots", "shell-snapshots"), ("File edit history", "file-history"),
                                  ("Todo lists", "todos")] {
            let folder = config + "/" + relative
            let bytes = size(folder)
            total += bytes
            if bytes > 0 { details.append(ToolDetail(title, note: "Claude Code", size: bytes, path: folder)) }
            items.append(cacheItem("claude-code", "Claude Code \(title.lowercased())", folder, minimum: 20_000_000,
                                   explanation: "\(title) Claude Code keeps for past sessions. Not needed to keep working."))
        }
        var summary = "Transcripts for \(Self.plural(projects, "project"))"
        if gone > 0 { summary += ", \(gone) for folders that no longer exist" }
        return report("claude-code", "Claude Code", version: version, symbol: "terminal", total: total, summary: summary + ".",
                      items: items, details: sortedDetails(details))
    }

    // MARK: Claude desktop app

    func claudeApp() -> ToolReport? {
        let support = path("Library/Application Support/Claude")
        guard exists(support) || exists("/Applications/Claude.app") else { return nil }
        var items: [Recommendation?] = []
        var details: [ToolDetail] = []
        var total: Int64 = 0
        for folder in children(support) {
            let bytes = size(folder)
            total += bytes
            if bytes >= 10_000_000 { details.append(ToolDetail((folder as NSString).lastPathComponent, size: bytes, path: folder)) }
        }
        for relative in ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"] {
            items.append(cacheItem("claude-app", "Claude app \(relative.lowercased())", support + "/" + relative, minimum: 20_000_000,
                                   before: "Quit Claude first."))
        }
        for cache in children(path("Library/Caches")) where (cache as NSString).lastPathComponent.hasPrefix("com.anthropic.claude") {
            let bytes = size(cache)
            total += bytes
            items.append(cacheItem("claude-app", "Claude app cache", cache, minimum: 20_000_000, before: "Quit Claude first."))
        }
        return report("claude-app", "Claude", version: appVersion("/Applications/Claude.app"), symbol: "bubble.left.and.text.bubble.right",
                      total: total, summary: "The desktop app's data and caches.", items: items, details: sortedDetails(details))
    }

    // MARK: Codex

    func codex() -> ToolReport? {
        let config = path(".codex")
        guard exists(config) else { return nil }
        var items: [Recommendation?] = []
        var details: [ToolDetail] = []
        let total = size(config)

        var sessions = 0
        var gone: [String: (size: Int64, files: [String])] = [:]
        for file in FileManager.default.enumerator(atPath: config + "/sessions")?.compactMap({ $0 as? String }) ?? [] where file.hasSuffix(".jsonl") {
            sessions += 1
            let full = config + "/sessions/" + file
            if let cwd = transcriptFolder(full), !exists(cwd) {
                gone[cwd, default: (0, [])].size += size(full)
                gone[cwd, default: (0, [])].files.append(full)
            }
        }
        let sessionsSize = size(config + "/sessions")
        if sessionsSize > 0 { details.append(ToolDetail("Sessions", note: Self.plural(sessions, "session"), size: sessionsSize, path: config + "/sessions")) }
        for (cwd, entry) in gone {
            details.append(ToolDetail((cwd as NSString).lastPathComponent, note: "\(Self.plural(entry.files.count, "session")) for a folder that no longer exists",
                                      size: entry.size, path: entry.files.first, badge: "Leftover"))
        }
        for relative in ["archived_sessions", "log"] {
            let folder = config + "/" + relative
            let bytes = size(folder)
            if bytes > 0 { details.append(ToolDetail(relative == "log" ? "Logs" : "Archived sessions", size: bytes, path: folder)) }
        }
        items.append(cacheItem("codex", "Codex logs", config + "/log", minimum: 20_000_000, explanation: "Logs from past Codex runs."))
        let version = which("codex").map { Shell.run($0, ["--version"]).text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.replacingOccurrences(of: "codex-cli ", with: "") }
        var summary = Self.plural(sessions, "session")
        if !gone.isEmpty { summary += ", \(gone.values.reduce(0) { $0 + $1.files.count }) for folders that no longer exist" }
        return report("codex", "Codex", version: version, symbol: "curlybraces", total: total, summary: summary + ".",
                      items: items, details: sortedDetails(details))
    }

    // MARK: GitHub Copilot

    func copilot() -> ToolReport? {
        var items: [Recommendation?] = []
        var details: [ToolDetail] = []
        var total: Int64 = 0
        for (title, relative) in [("Copilot CLI", ".copilot"), ("Copilot sign-in and settings", ".config/github-copilot")] {
            let folder = path(relative)
            let bytes = size(folder)
            total += bytes
            if bytes > 0 { details.append(ToolDetail(title, size: bytes, path: folder)) }
        }
        items.append(cacheItem("copilot", "Copilot CLI logs", path(".copilot/logs"), minimum: 20_000_000))
        // Copilot Chat keeps its index per editor.
        for support in ["Code", "Cursor", "Windsurf"] {
            let folder = path("Library/Application Support/\(support)/User/globalStorage/github.copilot-chat")
            let bytes = size(folder)
            total += bytes
            if bytes > 0 { details.append(ToolDetail("Copilot Chat in \(support == "Code" ? "VS Code" : support)", size: bytes, path: folder)) }
        }
        return report("copilot", "GitHub Copilot", symbol: "person.2.wave.2", total: total,
                      summary: "Copilot's CLI sessions and per-editor chat data.", items: items, details: sortedDetails(details))
    }

    // MARK: Other agents

    func otherAgents() -> ToolReport? {
        var items: [Recommendation?] = []
        var details: [ToolDetail] = []
        var total: Int64 = 0
        _ = installedVersions(tool: "cursor-agent", name: "Cursor CLI", folder: path(".local/share/cursor-agent/versions"),
                              launcher: path(".local/bin/cursor-agent"), items: &items, details: &details, total: &total)
        for (title, relative) in [("Gemini CLI", ".gemini"), ("opencode", ".local/share/opencode"), ("Aider", ".aider"),
                                  ("Continue", ".continue"), ("Amp", ".local/share/amp"), ("Goose", ".local/share/goose")] {
            let folder = path(relative)
            let bytes = size(folder)
            total += bytes
            if bytes > 0 { details.append(ToolDetail(title, size: bytes, path: folder)) }
        }
        items.append(cacheItem("agents", "Gemini CLI temporary files", path(".gemini/tmp"), minimum: 20_000_000,
                               explanation: "Checkpoints and scratch files from past Gemini CLI sessions."))
        items.append(cacheItem("agents", "Continue index", path(".continue/index"), minimum: 50_000_000))
        return report("agents", "Other AI agents", symbol: "sparkles", total: total,
                      summary: "Gemini CLI, Cursor CLI, opencode, Aider and other coding agents.", items: items, details: sortedDetails(details))
    }
}
