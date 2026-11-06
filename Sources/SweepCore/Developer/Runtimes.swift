import Foundation

extension DeveloperAnalyzer {
    // MARK: Node.js

    func node() -> ToolReport? {
        var items: [Recommendation?] = []
        var details: [ToolDetail] = []
        var total: Int64 = 0

        // Projects with node_modules: from the scan if there is one, otherwise a dedicated search.
        let folders: [(path: String, size: Int64)]
        let fromScan = scanned("node.modules")
        if scan != nil {
            folders = fromScan.map { ($0.path, $0.size) }
        } else {
            folders = NodeModulesScanner(roots: [URL(fileURLWithPath: home)]).scan().map { ($0.url.path, $0.size) }
        }
        var inactive = 0
        var inactiveSize: Int64 = 0
        for folder in folders {
            total += folder.size
            let project = (folder.path as NSString).deletingLastPathComponent
            let touched = NodeModulesScanner.lastTouched(project: URL(fileURLWithPath: project))
            let isOld = isInactive(touched)
            if isOld { inactive += 1; inactiveSize += folder.size }
            details.append(ToolDetail((project as NSString).lastPathComponent,
                                      note: "node_modules · last worked on " + RelativeDate.string(touched).lowercased(),
                                      size: folder.size, path: folder.path, badge: isOld ? "Inactive" : nil))
            if isOld, folder.size >= 10_000_000 {
                items.append(item("node", "node_modules · \((project as NSString).lastPathComponent)", path: folder.path, size: folder.size,
                                  tier: .reviewFirst, category: .developerTools,
                                  explanation: "Packages installed for a project nobody has touched in \(Int(Self.inactiveDays))+ days.",
                                  safe: "The project's install command brings them back while its lockfile is intact.",
                                  risks: "The project won't run until you install again.", action: "Remove node_modules",
                                  command: "npm install", badge: "Inactive", lastActivity: touched))
            }
        }

        for (title, relative, command) in [("npm cache", ".npm", "npm cache clean --force"),
                                           ("Yarn cache", "Library/Caches/Yarn", "yarn cache clean"),
                                           ("Yarn cache", ".yarn/berry/cache", "yarn cache clean --mirror"),
                                           ("Bun cache", ".bun/install/cache", "bun pm cache rm")] {
            let cache = path(relative)
            let bytes = size(cache)
            total += bytes
            if bytes > 0 { details.append(ToolDetail(title, size: bytes, path: cache)) }
            items.append(cacheItem("node", title, cache, minimum: 50_000_000, command: command))
        }
        for store in ["Library/pnpm", ".pnpm-store", ".local/share/pnpm/store"] where exists(path(store)) {
            let bytes = size(path(store))
            total += bytes
            details.append(ToolDetail("pnpm store", note: "Prune with: pnpm store prune", size: bytes, path: path(store)))
        }

        // Node versions installed with nvm.
        var version: String?
        let versions = children(path(".nvm/versions/node")).filter { isDirectory($0) }
        if !versions.isEmpty {
            let alias = read(path(".nvm/alias/default"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let names = versions.map { ($0 as NSString).lastPathComponent }
            let defaultVersion = names.filter { matches(alias: alias, version: $0) }.sorted { Self.isNewer($0, than: $1) }.first
                ?? names.sorted { Self.isNewer($0, than: $1) }.first
            version = defaultVersion.map { "nvm default \($0.trimmingCharacters(in: CharacterSet(charactersIn: "v")))" }
            for folder in versions {
                let name = (folder as NSString).lastPathComponent
                let bytes = size(folder)
                total += bytes
                let isDefault = name == defaultVersion
                let older = defaultVersion.map { Self.isNewer($0, than: name) } ?? false
                details.append(ToolDetail("Node \(name)", note: isDefault ? "Default" : nil, size: bytes, path: folder,
                                          badge: !isDefault && older ? "Superseded" : nil))
                if !isDefault {
                    items.append(item("node", "Node.js \(name) (nvm)", path: folder, size: bytes, tier: .reviewFirst, category: .developerTools,
                                      explanation: "A Node.js version installed with nvm that isn't your default.",
                                      safe: "nvm installs it again in a minute if a project needs it.",
                                      risks: "Projects pinned to this version with .nvmrc need it reinstalled.",
                                      action: "Uninstall this version", command: "nvm uninstall \(name)", methods: [.trash],
                                      badge: older ? "Superseded" : nil))
                }
            }
        }
        if version == nil, let output = which("node").flatMap({ Shell.run($0, ["--version"]).text.trimmingCharacters(in: .whitespacesAndNewlines) }),
           output.hasPrefix("v") {
            version = output
        }

        var summary = "\(Self.plural(folders.count, "project")) with node_modules"
        if inactive > 0 { summary += ", \(inactive) inactive for \(Int(Self.inactiveDays))+ days (\(ByteFormat.string(inactiveSize)))" }
        if !versions.isEmpty { summary += ". \(Self.plural(versions.count, "Node version")) with nvm" }
        return report("node", "Node.js", version: version, symbol: "hexagon", total: total, summary: summary + ".",
                      items: items, details: details.sorted { ($0.size ?? 0) > ($1.size ?? 0) })
    }

    /// nvm aliases are a version ("22", "v22.11.0") or a name like "lts/*" or "node".
    func matches(alias: String, version: String) -> Bool {
        let bare = version.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        let wanted = alias.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        guard !wanted.isEmpty, wanted.first?.isNumber == true else { return false }
        return bare == wanted || bare.hasPrefix(wanted + ".")
    }

    func which(_ tool: String) -> String? {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", path(".cargo/bin"), path(".local/bin"), path(".nvm/current/bin")]
        return candidates.map { $0 + "/" + tool }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Xcode

    func xcode() -> ToolReport? {
        let developer = path("Library/Developer")
        guard exists(developer) || exists("/Applications/Xcode.app") else { return nil }
        var items: [Recommendation?] = []
        var details: [ToolDetail] = []
        var total: Int64 = 0
        let version = (NSDictionary(contentsOfFile: "/Applications/Xcode.app/Contents/Info.plist")?["CFBundleShortVersionString"] as? String)

        // DerivedData, per project. The info.plist inside says which workspace it belongs to.
        var deletedProjects = 0
        let derived = children(path("Library/Developer/Xcode/DerivedData")).filter { isDirectory($0) && !$0.hasSuffix("/ModuleCache.noindex") }
        for folder in derived {
            let bytes = size(folder)
            total += bytes
            let workspace = NSDictionary(contentsOfFile: folder + "/info.plist")?["WorkspacePath"] as? String
            let gone = workspace.map { !exists($0) } ?? false
            if gone { deletedProjects += 1 }
            let name = workspace.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
                ?? String((folder as NSString).lastPathComponent.split(separator: "-").first ?? "")
            details.append(ToolDetail(name, note: gone ? "DerivedData for a project that no longer exists" : "DerivedData",
                                      size: bytes, path: folder, badge: gone ? "Leftover" : nil))
            if bytes >= 20_000_000 {
                items.append(item("xcode", "DerivedData · \(name)", path: folder, size: bytes, tier: .likelySafe, category: .buildArtifacts,
                                  explanation: gone ? "Build data for \(workspace ?? name), which no longer exists." : "Build products and indexes for \(name).",
                                  safe: gone ? "The project is gone, so nothing will ever use it." : "Xcode rebuilds it on the next build.",
                                  risks: gone ? "None." : "The next build of this project is slower.", action: "Remove it",
                                  badge: gone ? "Leftover" : nil, lastActivity: modified(folder), before: "Quit Xcode first."))
            }
        }
        let moduleCache = path("Library/Developer/Xcode/DerivedData/ModuleCache.noindex")
        items.append(cacheItem("xcode", "Xcode module cache", moduleCache, minimum: 50_000_000, before: "Quit Xcode first."))
        total += size(moduleCache)

        // Archives are kept: their debug symbols matter for crash reports.
        let archives = path("Library/Developer/Xcode/Archives")
        let archiveSize = size(archives)
        total += archiveSize
        if archiveSize > 0 {
            details.append(ToolDetail("Archives", note: "Kept: needed to read crash reports from shipped builds", size: archiveSize, path: archives))
        }

        // Device support, one folder per OS version.
        for platform in ["iOS", "watchOS", "tvOS", "xrOS"] {
            for folder in children(path("Library/Developer/Xcode/\(platform) DeviceSupport")) where isDirectory(folder) {
                let bytes = size(folder)
                total += bytes
                let name = (folder as NSString).lastPathComponent
                let old = isInactive(modified(folder))
                details.append(ToolDetail("\(platform) \(name)", note: "Device support", size: bytes, path: folder, badge: old ? "Inactive" : nil))
                if bytes >= 100_000_000 {
                    items.append(item("xcode", "\(platform) device support · \(name)", path: folder, size: bytes, tier: .reviewFirst, category: .developerTools,
                                      explanation: "Debug symbols Xcode copied from a device on this version.",
                                      safe: "Xcode copies them again when a device on this version connects.",
                                      risks: "The next debug session on that version starts slowly once.", action: "Remove it",
                                      badge: old ? "Inactive" : nil, lastActivity: modified(folder)))
                }
            }
        }

        // Simulators, through Xcode's own tool. Unavailable ones are removed with its command.
        var unavailable = 0
        var simulatorSize: Int64 = 0
        let devices = path("Library/Developer/CoreSimulator/Devices")
        if exists(devices) {
            simulatorSize = size(path("Library/Developer/CoreSimulator"))
            total += simulatorSize
            if exists("/Applications/Xcode.app"),
               let data = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"]).text.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let runtimes = parsed["devices"] as? [String: [[String: Any]]] {
                var unavailableSize: Int64 = 0
                for (_, list) in runtimes {
                    for device in list where (device["isAvailable"] as? Bool) == false {
                        unavailable += 1
                        if let dataPath = device["dataPath"] as? String {
                            unavailableSize += size((dataPath as NSString).deletingLastPathComponent)
                        }
                    }
                }
                if unavailable > 0 {
                    items.append(item("xcode", "Unavailable simulators", path: devices, size: unavailableSize, tier: .likelySafe,
                                      category: .developerTools,
                                      explanation: "\(Self.plural(unavailable, "simulator")) for runtimes that are no longer installed.",
                                      safe: "They can't run any more without their runtime.", risks: "Their app data is lost.",
                                      action: "Delete unavailable simulators", command: "xcrun simctl delete unavailable", methods: [],
                                      badge: "Leftover"))
                }
            }
            details.append(ToolDetail("Simulators", note: unavailable > 0 ? "\(unavailable) unavailable" : nil, size: simulatorSize, path: devices))
        }
        items.append(cacheItem("xcode", "Xcode cache", path("Library/Caches/com.apple.dt.Xcode"), minimum: 50_000_000, before: "Quit Xcode first."))
        total += size(path("Library/Caches/com.apple.dt.Xcode"))

        var summary = "DerivedData for \(Self.plural(derived.count, "project"))"
        if deletedProjects > 0 { summary += ", \(deletedProjects) for projects that no longer exist" }
        if unavailable > 0 { summary += ". \(Self.plural(unavailable, "unavailable simulator"))" }
        return report("xcode", "Xcode", version: version, symbol: "hammer", total: total, summary: summary + ".",
                      items: items, details: details.sorted { ($0.size ?? 0) > ($1.size ?? 0) })
    }

    // MARK: Rust

    func rust() -> ToolReport? {
        guard exists(path(".rustup")) || exists(path(".cargo")) || !scanned("rust.target").isEmpty else { return nil }
        var items: [Recommendation?] = []
        var details: [ToolDetail] = []
        var total: Int64 = 0

        let settings = read(path(".rustup/settings.toml")) ?? ""
        let defaultToolchain = settings.split(separator: "\n")
            .first { $0.hasPrefix("default_toolchain") }
            .flatMap { $0.split(separator: "\"").dropFirst().first.map(String.init) }
        let toolchains = children(path(".rustup/toolchains")).filter { isDirectory($0) }
        for folder in toolchains {
            let name = (folder as NSString).lastPathComponent
            let bytes = size(folder)
            total += bytes
            let isDefault = defaultToolchain.map { name == $0 || name.hasPrefix($0 + "-") } ?? false
            details.append(ToolDetail(name, note: isDefault ? "Default toolchain" : "Toolchain", size: bytes, path: folder))
            if !isDefault, bytes >= 100_000_000 {
                items.append(item("rust", "Rust toolchain · \(name)", path: folder, size: bytes, tier: .reviewFirst, category: .developerTools,
                                  explanation: "A Rust toolchain that isn't your default.",
                                  safe: "rustup installs it again if a project asks for it.",
                                  risks: "Projects pinned to it with rust-toolchain.toml need it reinstalled.",
                                  action: "Uninstall it", command: "rustup toolchain uninstall \(name)", methods: [], badge: "Superseded"))
            }
        }

        var inactive = 0
        let targets = scanned("rust.target")
        for node in targets {
            total += node.size
            let project = node.url.deletingLastPathComponent()
            let touched = NodeModulesScanner.lastTouched(project: project)
            let old = isInactive(touched)
            if old { inactive += 1 }
            details.append(ToolDetail(project.lastPathComponent, note: "target · last worked on " + RelativeDate.string(touched).lowercased(),
                                      size: node.size, path: node.path, badge: old ? "Inactive" : nil))
            if node.size >= 50_000_000 {
                items.append(item("rust", "Rust build output · \(project.lastPathComponent)", path: node.path, size: node.size, tier: .likelySafe,
                                  category: .buildArtifacts, explanation: "Everything Cargo compiled for \(project.lastPathComponent).",
                                  safe: "Cargo rebuilds everything in target/ on the next build.", risks: "The next build takes longer.",
                                  action: "Remove target", command: "cargo clean", badge: old ? "Inactive" : nil, lastActivity: touched))
            }
        }
        for (title, relative) in [("Cargo registry cache", ".cargo/registry"), ("Cargo git checkouts", ".cargo/git")] {
            let bytes = size(path(relative))
            total += bytes
            if bytes > 0 { details.append(ToolDetail(title, size: bytes, path: path(relative))) }
            items.append(cacheItem("rust", title, path(relative), minimum: 50_000_000))
        }

        var summary = "\(Self.plural(toolchains.count, "toolchain")), \(Self.plural(targets.count, "project build folder"))"
        if inactive > 0 { summary += ", \(inactive) inactive" }
        return report("rust", "Rust", version: defaultToolchain, symbol: "gearshape.2", total: total, summary: summary + ".",
                      items: items, details: details.sorted { ($0.size ?? 0) > ($1.size ?? 0) })
    }

    // MARK: Python

    func python() -> ToolReport? {
        var items: [Recommendation?] = []
        var details: [ToolDetail] = []
        var total: Int64 = 0

        let venvs = scanned("python.venv")
        for node in venvs {
            total += node.size
            let project = node.url.deletingLastPathComponent()
            let touched = NodeModulesScanner.lastTouched(project: project)
            let old = isInactive(touched)
            details.append(ToolDetail(project.lastPathComponent, note: "\(node.name) · last worked on " + RelativeDate.string(touched).lowercased(),
                                      size: node.size, path: node.path, badge: old ? "Inactive" : nil))
            if old, node.size >= 50_000_000 {
                items.append(item("python", "Virtual environment · \(project.lastPathComponent)", path: node.path, size: node.size,
                                  tier: .reviewFirst, category: .developerTools,
                                  explanation: "Packages installed for a project nobody has touched in \(Int(Self.inactiveDays))+ days.",
                                  safe: "It can be recreated from the project's dependency files.",
                                  risks: "Packages installed by hand and not listed there are lost.", action: "Remove it",
                                  badge: "Inactive", lastActivity: touched))
            }
        }
        for (title, relative, command) in [("pip cache", "Library/Caches/pip", "pip cache purge"),
                                           ("uv cache", ".cache/uv", "uv cache clean"),
                                           ("Poetry cache", "Library/Caches/pypoetry", "poetry cache clear --all ."),
                                           ("Conda packages", "miniconda3/pkgs", "conda clean --all"),
                                           ("Conda packages", "anaconda3/pkgs", "conda clean --all")] {
            let bytes = size(path(relative))
            total += bytes
            if bytes > 0 { details.append(ToolDetail(title, size: bytes, path: path(relative))) }
            items.append(cacheItem("python", title, path(relative), minimum: 50_000_000, command: command))
        }
        for folder in children(path(".pyenv/versions")) where isDirectory(folder) {
            let bytes = size(folder)
            total += bytes
            details.append(ToolDetail("Python \((folder as NSString).lastPathComponent)", note: "pyenv", size: bytes, path: folder))
        }

        // Hugging Face models: listed so they can be reviewed; big to download again.
        var models = 0
        for folder in children(path(".cache/huggingface/hub")) where (folder as NSString).lastPathComponent.hasPrefix("models--") {
            models += 1
            let bytes = size(folder)
            total += bytes
            let name = (folder as NSString).lastPathComponent.replacingOccurrences(of: "models--", with: "").replacingOccurrences(of: "--", with: "/")
            let old = isInactive(modified(folder))
            details.append(ToolDetail(name, note: "Hugging Face model", size: bytes, path: folder, badge: old ? "Inactive" : nil))
            if bytes >= 200_000_000 {
                items.append(item("python", "Hugging Face model · \(name)", path: folder, size: bytes, tier: .reviewFirst, category: .binaryData,
                                  explanation: "A model downloaded from Hugging Face.", safe: "It downloads again when code asks for it.",
                                  risks: "Large models take a long time to download again.", action: "Remove it",
                                  badge: old ? "Inactive" : nil, lastActivity: modified(folder)))
            }
        }
        guard total > 0 else { return nil }
        let version = which("python3").map { Shell.run($0, ["--version"]).text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var summary = "\(Self.plural(venvs.count, "virtual environment"))"
        if models > 0 { summary += ", \(Self.plural(models, "Hugging Face model"))" }
        return report("python", "Python", version: version?.replacingOccurrences(of: "Python ", with: ""), symbol: "chevron.left.slash.chevron.right",
                      total: total, summary: summary + ".", items: items, details: details.sorted { ($0.size ?? 0) > ($1.size ?? 0) })
    }
}
