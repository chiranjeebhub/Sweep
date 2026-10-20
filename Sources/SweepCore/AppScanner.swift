import CoreServices
import Foundation

/// An installed application.
public struct InstalledApp: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let bundleIdentifier: String?
    public let version: String?
    public let size: Int64
    public let lastUsed: Date?

    /// Apps nobody has opened in this long count as unused.
    public static let unusedInterval: TimeInterval = 90 * 24 * 60 * 60

    public func isUnused(now: Date = Date()) -> Bool {
        guard let lastUsed else { return true }
        return now.timeIntervalSince(lastUsed) > Self.unusedInterval
    }
}

/// Files an app keeps outside its bundle, grouped the way the Uninstaller shows them.
public struct AppRemnants: Sendable {
    public struct Group: Identifiable, Sendable {
        public var id: String { title }
        public let title: String
        public let urls: [URL]
        public let size: Int64
    }

    public let groups: [Group]
    public var size: Int64 { groups.reduce(0) { $0 + $1.size } }
    public var urls: [URL] { groups.flatMap(\.urls) }
}

/// A support folder left behind by an app that is no longer installed.
public struct Leftover: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let bundleIdentifier: String
    public let size: Int64
}

/// Lists installed apps and the files each one leaves around the user's Library.
public struct AppScanner: Sendable {
    let applicationFolders: [URL]
    let library: URL

    public init(
        applicationFolders: [URL]? = nil,
        library: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
    ) {
        self.applicationFolders = applicationFolders ?? [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        self.library = library
    }

    // MARK: Installed apps

    public func installedApps() -> [InstalledApp] {
        var seen = Set<String>()
        return applicationFolders
            .flatMap { appBundles(in: $0, depth: 2) }
            .compactMap { makeApp(at: $0) }
            .filter { app in
                // Apps that ship with macOS are protected by the system and can't be removed.
                if let id = app.bundleIdentifier, id == "com.apple.Safari" { return false }
                return seen.insert(app.url.path).inserted
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func appBundles(in folder: URL, depth: Int) -> [URL] {
        guard depth > 0, let children = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return children.flatMap { child -> [URL] in
            if child.pathExtension == "app" { return [child] }
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return isDirectory ? appBundles(in: child, depth: depth - 1) : []
        }
    }

    private func makeApp(at url: URL) -> InstalledApp? {
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApp(
            url: url,
            name: name,
            bundleIdentifier: bundle?.bundleIdentifier,
            version: info["CFBundleShortVersionString"] as? String,
            size: FileSize.allocatedSize(of: url),
            lastUsed: Self.lastUsedDate(of: url))
    }

    /// Spotlight's "last opened" date. Nil when the app has never been opened.
    static func lastUsedDate(of url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    // MARK: Remnants

    /// Support files, caches, preferences and so on that belong to `app`.
    public func remnants(of app: InstalledApp) -> AppRemnants {
        let names = Set([app.bundleIdentifier, app.name].compactMap { $0 })
        let bundleID = app.bundleIdentifier ?? app.name

        func existing(_ paths: [String]) -> [URL] {
            paths.map { library.appendingPathComponent($0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        func named(_ folder: String) -> [URL] { existing(names.map { "\(folder)/\($0)" }) }

        let candidates: [(String, [URL])] = [
            ("Supporting files", named("Application Support") + existing(["HTTPStorages/\(bundleID)", "WebKit/\(bundleID)"])),
            ("Caches", named("Caches")),
            ("Containers", existing(["Containers/\(bundleID)"])),
            ("Preferences", existing(["Preferences/\(bundleID).plist"]) + byHostPreferences(for: bundleID)),
            ("Logs", named("Logs")),
            ("Saved state", existing(["Saved Application State/\(bundleID).savedState"])),
            ("Launch agents", launchAgents(for: bundleID)),
        ]

        let groups = candidates.compactMap { entry -> AppRemnants.Group? in
            let (title, urls) = entry
            let unique = Array(Set(urls)).sorted { $0.path < $1.path }
            guard !unique.isEmpty else { return nil }
            return AppRemnants.Group(title: title, urls: unique, size: FileSize.allocatedSize(of: unique))
        }
        return AppRemnants(groups: groups)
    }

    private func byHostPreferences(for bundleID: String) -> [URL] {
        let folder = library.appendingPathComponent("Preferences/ByHost")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix(bundleID + ".") }
    }

    private func launchAgents(for bundleID: String) -> [URL] {
        let folder = library.appendingPathComponent("LaunchAgents")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix(bundleID) }
    }

    // MARK: Leftovers

    /// Support folders named after a bundle identifier whose app is no longer installed.
    /// `isInstalled` lets the caller ask Launch Services, which knows about every app on disk.
    public func leftovers(isInstalled: (String) -> Bool) -> [Leftover] {
        let folders = ["Application Support", "Caches", "Containers", "Saved Application State", "HTTPStorages", "WebKit"]
        var results: [Leftover] = []
        for folder in folders {
            let parent = library.appendingPathComponent(folder)
            let children = (try? FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for child in children {
                var identifier = child.lastPathComponent
                if identifier.hasSuffix(".savedState") { identifier = String(identifier.dropLast(".savedState".count)) }
                guard Self.looksLikeBundleIdentifier(identifier),
                      !identifier.hasPrefix("com.apple."),
                      !isInstalled(identifier) else { continue }
                let size = FileSize.allocatedSize(of: child)
                guard size > 0 else { continue }
                results.append(Leftover(url: child, bundleIdentifier: identifier, size: size))
            }
        }
        return results.sorted { $0.size > $1.size }
    }

    /// Reverse-DNS names such as `com.example.App`.
    static func looksLikeBundleIdentifier(_ name: String) -> Bool {
        let parts = name.split(separator: ".")
        guard parts.count >= 3, let first = parts.first else { return false }
        return ["com", "org", "net", "io", "app", "co", "de", "us", "dev"].contains(first.lowercased())
            && !name.contains(" ")
    }
}
