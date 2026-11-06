import Foundation

extension DeveloperAnalyzer {
    // MARK: Local models

    func localModels() -> ToolReport? {
        var items: [Recommendation?] = []
        var details: [ToolDetail] = []
        var total: Int64 = 0
        var summaryParts: [String] = []

        // Ollama: manifests name the blobs each model uses. Blobs nothing names are leftovers from removed or updated models.
        let ollama = path(".ollama/models")
        if exists(ollama) {
            total += size(ollama)
            var used: Set<String> = []
            var modelCount = 0
            let manifests = ollama + "/manifests"
            for relative in FileManager.default.enumerator(atPath: manifests)?.compactMap({ $0 as? String }) ?? [] {
                let file = manifests + "/" + relative
                guard !isDirectory(file), let manifest = json(file) as? [String: Any] else { continue }
                var layers = (manifest["layers"] as? [[String: Any]]) ?? []
                if let config = manifest["config"] as? [String: Any] { layers.append(config) }
                var bytes: Int64 = 0
                for layer in layers {
                    if let digest = layer["digest"] as? String { used.insert(digest.replacingOccurrences(of: ":", with: "-")) }
                    bytes += (layer["size"] as? NSNumber)?.int64Value ?? 0
                }
                modelCount += 1
                // registry.ollama.ai/library/llama3/8b -> llama3:8b
                let parts = relative.split(separator: "/")
                let name = parts.count >= 2 ? "\(parts[parts.count - 2]):\(parts[parts.count - 1])" : relative
                let old = isInactive(modified(file))
                details.append(ToolDetail(name, note: "Ollama model", size: bytes, path: file, badge: old ? "Inactive" : nil))
                if bytes >= 500_000_000 {
                    items.append(item("models", "Ollama model · \(name)", path: file, size: bytes, tier: .reviewFirst, category: .binaryData,
                                      explanation: "A model downloaded with Ollama.", safe: "ollama pull downloads it again.",
                                      risks: "Large models take a long time to download again.", action: "Remove it",
                                      command: "ollama rm \(name)", methods: [], badge: old ? "Inactive" : nil, lastActivity: modified(file)))
                }
            }
            var unused = 0
            for blob in children(ollama + "/blobs") {
                let blobName = (blob as NSString).lastPathComponent
                let partial = blobName.contains("-partial")
                guard partial || !used.contains(blobName) else { continue }
                unused += 1
                let bytes = size(blob)
                details.append(ToolDetail(blobName, note: partial ? "Unfinished Ollama download" : "Ollama data no model uses",
                                          size: bytes, path: blob, badge: "Leftover"))
                if bytes >= 1_000_000 {
                    items.append(item("models", partial ? "Unfinished Ollama download" : "Unused Ollama model data", path: blob, size: bytes,
                                      tier: .likelySafe, category: .binaryData,
                                      explanation: partial ? "Part of a download that never finished." : "Model data that no installed model refers to.",
                                      safe: "No installed model uses it.", risks: "None.", action: "Remove it", badge: "Leftover",
                                      before: "Quit Ollama first."))
                }
            }
            summaryParts.append("\(Self.plural(modelCount, "Ollama model"))" + (unused > 0 ? " (\(unused) unused files)" : ""))
        }

        // LM Studio keeps models as publisher/model folders.
        var lmCount = 0
        for root in [path(".lmstudio/models"), path(".cache/lm-studio/models")] {
            for publisher in children(root) where isDirectory(publisher) {
                for model in children(publisher) where isDirectory(model) {
                    lmCount += 1
                    let bytes = size(model)
                    total += bytes
                    let name = (publisher as NSString).lastPathComponent + "/" + (model as NSString).lastPathComponent
                    let old = isInactive(modified(model))
                    details.append(ToolDetail(name, note: "LM Studio model", size: bytes, path: model, badge: old ? "Inactive" : nil))
                    if bytes >= 500_000_000 {
                        items.append(item("models", "LM Studio model · \(name)", path: model, size: bytes, tier: .reviewFirst, category: .binaryData,
                                          explanation: "A model downloaded in LM Studio.", safe: "LM Studio can download it again.",
                                          risks: "Large models take a long time to download again.", action: "Remove it",
                                          badge: old ? "Inactive" : nil, lastActivity: modified(model), before: "Quit LM Studio first."))
                    }
                }
            }
        }
        if lmCount > 0 { summaryParts.append(Self.plural(lmCount, "LM Studio model")) }
        guard !summaryParts.isEmpty else { return nil }
        return report("models", "Local AI models", symbol: "cpu", total: total, summary: summaryParts.joined(separator: ", ") + ".",
                      items: items, details: sortedDetails(details))
    }

    // MARK: Homebrew

    func homebrew() -> ToolReport? {
        guard let prefix = ["/opt/homebrew", "/usr/local"].first(where: { exists($0 + "/Cellar") }) else { return nil }
        var items: [Recommendation?] = []
        var details: [ToolDetail] = []
        var total: Int64 = 0
        var formulas = 0
        var outdated = 0
        var outdatedSize: Int64 = 0
        for formula in children(prefix + "/Cellar") where isDirectory(formula) {
            formulas += 1
            let versions = children(formula).filter { isDirectory($0) }
            let bytes = versions.reduce(Int64(0)) { $0 + size($1) }
            total += bytes
            guard versions.count > 1 else { continue }
            // The version opt/ links to is the one in use.
            let name = (formula as NSString).lastPathComponent
            let current = linkTarget(prefix + "/opt/" + name).map { ($0 as NSString).lastPathComponent }
            for version in versions where (version as NSString).lastPathComponent != current {
                outdated += 1
                let versionSize = size(version)
                outdatedSize += versionSize
                details.append(ToolDetail("\(name) \((version as NSString).lastPathComponent)", note: "Older Homebrew version",
                                          size: versionSize, path: version, badge: "Superseded"))
            }
        }
        if outdated > 0 {
            items.append(item("homebrew", "Older Homebrew versions", path: prefix + "/Cellar", size: outdatedSize, tier: .likelySafe,
                              category: .developerTools, explanation: "\(Self.plural(outdated, "older version")) kept after upgrades.",
                              safe: "Homebrew only removes versions nothing links to.", risks: "You can't switch back to those versions without reinstalling.",
                              action: "Run Homebrew's cleanup", command: "brew cleanup", methods: [], badge: "Superseded"))
        }
        let cache = path("Library/Caches/Homebrew")
        total += size(cache)
        items.append(cacheItem("homebrew", "Homebrew downloads", cache, minimum: 50_000_000, command: "brew cleanup --prune=all",
                               explanation: "Bottles and source archives Homebrew downloaded. Fetched again when needed."))
        let version = Shell.run(prefix + "/bin/brew", ["--version"]).text.split(separator: "\n").first
            .map { $0.replacingOccurrences(of: "Homebrew ", with: "") }
        var summary = Self.plural(formulas, "formula")
        if outdated > 0 { summary += ", \(Self.plural(outdated, "older version")) kept (\(ByteFormat.string(outdatedSize)))" }
        return report("homebrew", "Homebrew", version: version, symbol: "mug", total: total, summary: summary + ".",
                      items: items, details: sortedDetails(details))
    }

    // MARK: JetBrains

    func jetBrains() -> ToolReport? {
        let roots = [("Caches", path("Library/Caches/JetBrains")), ("Settings", path("Library/Application Support/JetBrains")),
                     ("Logs", path("Library/Logs/JetBrains"))]
        guard roots.contains(where: { exists($0.1) }) else { return nil }
        var items: [Recommendation?] = []
        var details: [ToolDetail] = []
        var total: Int64 = 0
        // Folders are named product + version, like IntelliJIdea2024.3. Only the newest version of each product is in use.
        func split(_ name: String) -> (String, String)? {
            guard let range = name.range(of: "[0-9]{4}\\.[0-9]+$", options: .regularExpression) else { return nil }
            return (String(name[..<range.lowerBound]), String(name[range]))
        }
        var newest: [String: String] = [:]
        for (_, root) in roots {
            for folder in children(root) {
                guard let parts = split((folder as NSString).lastPathComponent) else { continue }
                let (product, version) = parts
                if newest[product].map({ Self.isNewer(version, than: $0) }) ?? true { newest[product] = version }
            }
        }
        var older = 0
        for (kind, root) in roots {
            for folder in children(root) where isDirectory(folder) {
                let name = (folder as NSString).lastPathComponent
                let bytes = size(folder)
                total += bytes
                guard let parts = split(name) else { continue }
                let (product, version) = parts
                let isOld = newest[product] != version
                details.append(ToolDetail("\(product) \(version)", note: kind, size: bytes, path: folder, badge: isOld ? "Superseded" : nil))
                if isOld {
                    older += 1
                    items.append(item("jetbrains", "\(product) \(version) \(kind.lowercased())", path: folder, size: bytes,
                                      tier: kind == "Settings" ? .reviewFirst : .likelySafe, category: kind == "Caches" ? .cache : .applicationData,
                                      explanation: "\(kind) for \(product) \(version). You now use \(newest[product] ?? "a newer version"), which copied what it needed.",
                                      safe: "The newer version doesn't read this folder.",
                                      risks: kind == "Settings" ? "You can't go back to \(version) with your old settings." : "None.",
                                      action: "Remove it", badge: "Superseded", lastActivity: modified(folder)))
                } else if kind == "Caches" {
                    items.append(cacheItem("jetbrains", "\(product) caches", folder, minimum: 500_000_000, before: "Quit the IDE first.",
                                           explanation: "Indexes and caches for \(product). Rebuilt when you open a project, which takes a while."))
                }
            }
        }
        let products = newest.keys.sorted().joined(separator: ", ")
        var summary = products.isEmpty ? "JetBrains data" : products
        if older > 0 { summary += ". \(Self.plural(older, "folder")) from older versions" }
        return report("jetbrains", "JetBrains IDEs", symbol: "square.stack.3d.up", total: total, summary: summary + ".",
                      items: items, details: sortedDetails(details))
    }

    // MARK: Android

    func android() -> ToolReport? {
        let sdk = path("Library/Android/sdk")
        let avd = path(".android/avd")
        guard exists(sdk) || exists(avd) else { return nil }
        var items: [Recommendation?] = []
        var details: [ToolDetail] = []
        var total = size(sdk) + size(path(".android"))

        var emulators = 0
        for device in children(avd) where device.hasSuffix(".avd") {
            emulators += 1
            let bytes = size(device)
            let name = ((device as NSString).lastPathComponent as NSString).deletingPathExtension
            let old = isInactive(modified(device))
            details.append(ToolDetail(name, note: "Emulator", size: bytes, path: device, badge: old ? "Inactive" : nil))
            if bytes >= 500_000_000 {
                items.append(item("android", "Android emulator · \(name)", path: device, size: bytes, tier: .reviewFirst, category: .developerTools,
                                  explanation: "An Android virtual device with its own disk image.",
                                  safe: "You can create it again in Android Studio's Device Manager.",
                                  risks: "Apps and data installed on it are lost.", action: "Remove it",
                                  badge: old ? "Inactive" : nil, lastActivity: modified(device), before: "Close the emulator first."))
            }
        }
        // Build tools: only the newest is normally needed.
        let buildTools = children(sdk + "/build-tools").filter { isDirectory($0) }
            .sorted { Self.isNewer(($0 as NSString).lastPathComponent, than: ($1 as NSString).lastPathComponent) }
        for folder in buildTools.dropFirst() {
            let version = (folder as NSString).lastPathComponent
            let bytes = size(folder)
            details.append(ToolDetail("Build tools \(version)", note: "Older version", size: bytes, path: folder, badge: "Superseded"))
            items.append(item("android", "Android build tools \(version)", path: folder, size: bytes, tier: .reviewFirst, category: .developerTools,
                              explanation: "An older version of the Android build tools.",
                              safe: "Gradle downloads it again if a project asks for it.", risks: "Projects pinned to it need it again.",
                              action: "Remove it", badge: "Superseded"))
        }
        for image in [sdk + "/system-images"] {
            let bytes = size(image)
            if bytes > 0 { details.append(ToolDetail("System images", note: "Used by emulators", size: bytes, path: image)) }
        }
        items.append(cacheItem("android", "Android cache", path(".android/cache"), minimum: 20_000_000))
        return report("android", "Android", symbol: "iphone.gen2", total: total,
                      summary: "\(Self.plural(emulators, "emulator")), \(Self.plural(buildTools.count, "build tools version")).",
                      items: items, details: sortedDetails(details))
    }

    // MARK: Gradle and Java

    func gradleAndJava() -> ToolReport? {
        var items: [Recommendation?] = []
        var details: [ToolDetail] = []
        var total: Int64 = 0

        let caches = path(".gradle/caches")
        total += size(caches)
        items.append(cacheItem("gradle", "Gradle caches", caches, minimum: 200_000_000, command: "gradle --stop",
                               before: "Stop Gradle daemons first (gradle --stop).",
                               explanation: "Downloaded dependencies and build caches. Gradle downloads what it needs again."))
        // Wrapper distributions, one per Gradle version a project asked for.
        let dists = children(path(".gradle/wrapper/dists")).filter { isDirectory($0) }
            .sorted { Self.isNewer(($0 as NSString).lastPathComponent, than: ($1 as NSString).lastPathComponent) }
        for (index, dist) in dists.enumerated() {
            let name = (dist as NSString).lastPathComponent
            let bytes = size(dist)
            total += bytes
            let old = isInactive(modified(dist))
            details.append(ToolDetail(name, note: "Gradle wrapper", size: bytes, path: dist, badge: index > 0 && old ? "Superseded" : nil))
            if index > 0 && old {
                items.append(item("gradle", "Gradle \(name)", path: dist, size: bytes, tier: .likelySafe, category: .developerTools,
                                  explanation: "A Gradle version downloaded by a project's wrapper and not used in \(Int(Self.inactiveDays))+ days.",
                                  safe: "The wrapper downloads it again if a project still asks for it.", risks: "A short download next time.",
                                  action: "Remove it", badge: "Superseded", lastActivity: modified(dist)))
            }
        }
        for (title, relative) in [("Gradle daemon logs", ".gradle/daemon"), ("Maven repository", ".m2/repository")] {
            let folder = path(relative)
            let bytes = size(folder)
            total += bytes
            if bytes > 0 { details.append(ToolDetail(title, size: bytes, path: folder)) }
        }
        items.append(cacheItem("gradle", "Gradle daemon logs", path(".gradle/daemon"), minimum: 20_000_000))
        let maven = path(".m2/repository")
        if size(maven) >= 500_000_000 {
            items.append(item("gradle", "Maven repository", path: maven, size: size(maven), tier: .reviewFirst, category: .cache,
                              explanation: "Every library Maven downloaded.", safe: "Maven downloads what builds need again.",
                              risks: "Libraries you installed locally with mvn install are lost.", action: "Remove it"))
        }
        // JDKs installed per user.
        for root in [path("Library/Java/JavaVirtualMachines"), path(".sdkman/candidates/java")] {
            for jdk in children(root) where isDirectory(jdk) && (jdk as NSString).lastPathComponent != "current" {
                let bytes = size(jdk)
                total += bytes
                details.append(ToolDetail((jdk as NSString).lastPathComponent, note: "JDK", size: bytes, path: jdk))
            }
        }
        return report("gradle", "Gradle and Java", symbol: "cup.and.saucer", total: total,
                      summary: "\(Self.plural(dists.count, "Gradle version")) from project wrappers.", items: items, details: sortedDetails(details))
    }

    // MARK: Go and others

    func goAndOthers() -> ToolReport? {
        var items: [Recommendation?] = []
        var details: [ToolDetail] = []
        var total: Int64 = 0
        // Go's module cache is read-only on disk, so it is removed with Go's own command.
        let modules = path("go/pkg/mod")
        let moduleSize = size(modules)
        total += moduleSize
        if moduleSize >= 100_000_000 {
            items.append(item("other", "Go module cache", path: modules, size: moduleSize, tier: .likelySafe, category: .cache,
                              explanation: "Source for every Go module downloaded.", safe: "Go downloads modules again when building.",
                              risks: "The next build needs the network.", action: "Clean the module cache", command: "go clean -modcache", methods: []))
        }
        let caches: [(String, String, String?)] = [
            ("Go build cache", "Library/Caches/go-build", "go clean -cache"),
            ("CocoaPods cache", "Library/Caches/CocoaPods", "pod cache clean --all"),
            ("Carthage cache", "Library/Caches/org.carthage.CarthageKit", nil),
            ("Swift Package Manager cache", "Library/Caches/org.swift.swiftpm", nil),
            ("Deno cache", "Library/Caches/deno", nil),
            ("Dart and Flutter packages", ".pub-cache", "dart pub cache clean"),
            ("Composer cache", "Library/Caches/composer", "composer clear-cache"),
            ("Ruby gems cache", ".gem", nil),
            ("Bundler cache", ".bundle/cache", nil),
            ("Terraform plugins", ".terraform.d/plugin-cache", nil),
        ]
        for (title, relative, command) in caches {
            let folder = path(relative)
            let bytes = size(folder)
            total += bytes
            if bytes > 0 { details.append(ToolDetail(title, note: command.map { "Clean with: \($0)" }, size: bytes, path: folder)) }
            items.append(cacheItem("other", title, folder, minimum: 50_000_000, command: command))
        }
        if moduleSize > 0 { details.append(ToolDetail("Go module cache", note: "Clean with: go clean -modcache", size: moduleSize, path: modules)) }
        return report("other", "Go, CocoaPods and others", symbol: "shippingbox", total: total,
                      summary: "Package caches for Go, CocoaPods, Swift PM, Flutter, Ruby and more.", items: items, details: sortedDetails(details))
    }
}
