import CoreServices
import Foundation
import Security

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
    let systemLibrary: URL

    public init(
        applicationFolders: [URL]? = nil,
        library: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library"),
        systemLibrary: URL = URL(fileURLWithPath: "/Library")
    ) {
        self.applicationFolders = applicationFolders ?? [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        self.library = library
        self.systemLibrary = systemLibrary
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

    /// Support files, caches, preferences, launch agents and helpers that belong to `app`, in
    /// the user's Library and in `/Library`.
    public func remnants(of app: InstalledApp) -> AppRemnants {
        let info = AppSigningInfo(appURL: app.url)
        let bundleID = app.bundleIdentifier ?? app.name
        // Folders are named after the bundle id, the display name (with or without spaces) or the
        // executable name, in any letter case. "Bucket Browser" keeps its caches in "BucketBrowser".
        let names = Set([app.bundleIdentifier, app.name, app.name.replacingOccurrences(of: " ", with: ""), info.executableName]
            .compactMap { $0?.lowercased() })
        let id = bundleID.lowercased()

        func matches(_ folder: URL, _ keep: (String) -> Bool) -> [URL] {
            let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return children.filter { keep($0.lastPathComponent.lowercased()) }
        }
        func named(_ root: URL, _ folder: String) -> [URL] {
            matches(root.appendingPathComponent(folder)) { names.contains($0) }
        }
        func identified(_ root: URL, _ folder: String, suffix: String = "") -> [URL] {
            matches(root.appendingPathComponent(folder)) { $0 == id + suffix }
        }
        let groupIDs = Set(info.applicationGroups.map { $0.lowercased() })
        let user = library

        let candidates: [(String, [URL])] = [
            ("Supporting files", named(user, "Application Support")
                + identified(user, "HTTPStorages") + identified(user, "HTTPStorages", suffix: ".binarycookies")
                + identified(user, "WebKit") + identified(user, "Cookies", suffix: ".binarycookies")
                + identified(user, "Application Scripts")),
            ("Caches", named(user, "Caches")),
            ("Containers", identified(user, "Containers")
                + matches(user.appendingPathComponent("Group Containers")) { groupIDs.contains($0) }),
            ("Preferences", identified(user, "Preferences", suffix: ".plist")
                + matches(user.appendingPathComponent("Preferences")) { name in groupIDs.contains { name == $0 + ".plist" } }
                + byHostPreferences(for: bundleID)),
            ("Logs", named(user, "Logs") + crashReports(in: user.appendingPathComponent("Logs/DiagnosticReports"), names: names)),
            ("Saved state", identified(user, "Saved Application State", suffix: ".savedstate")),
            ("Launch agents", launchJobs(in: user.appendingPathComponent("LaunchAgents"), bundleID: bundleID, app: app)),
            ("System files", named(systemLibrary, "Application Support") + named(systemLibrary, "Caches")
                + named(systemLibrary, "Logs") + identified(systemLibrary, "Preferences", suffix: ".plist")
                + launchJobs(in: systemLibrary.appendingPathComponent("LaunchAgents"), bundleID: bundleID, app: app)
                + launchJobs(in: systemLibrary.appendingPathComponent("LaunchDaemons"), bundleID: bundleID, app: app,
                             labels: info.privilegedHelpers)
                + matches(systemLibrary.appendingPathComponent("PrivilegedHelperTools")) { name in
                    name.hasPrefix(id) || info.privilegedHelpers.contains { $0.lowercased() == name }
                }),
        ]

        let groups = candidates.compactMap { entry -> AppRemnants.Group? in
            let (title, urls) = entry
            let unique = Array(Set(urls.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
            guard !unique.isEmpty else { return nil }
            return AppRemnants.Group(title: title, urls: unique, size: FileSize.allocatedSize(of: unique))
        }
        return AppRemnants(groups: groups)
    }

    private func byHostPreferences(for bundleID: String) -> [URL] {
        let folder = library.appendingPathComponent("Preferences/ByHost")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.lowercased().hasPrefix(bundleID.lowercased() + ".") }
    }

    /// Launch agent or daemon plists that belong to the app: named after its bundle id or one of
    /// its helper labels, or pointing at a program inside the app bundle.
    private func launchJobs(in folder: URL, bundleID: String, app: InstalledApp, labels: [String] = []) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let appPath = app.url.path + "/"
        return files.filter { file in
            let name = file.lastPathComponent.lowercased()
            if name.hasPrefix(bundleID.lowercased()) { return true }
            if labels.contains(where: { name == $0.lowercased() + ".plist" }) { return true }
            guard let plist = NSDictionary(contentsOf: file) else { return false }
            let programs = [plist["Program"] as? String, (plist["ProgramArguments"] as? [String])?.first].compactMap { $0 }
            let associated = (plist["AssociatedBundleIdentifiers"] as? [String])
                ?? [plist["AssociatedBundleIdentifiers"] as? String].compactMap { $0 }
            return programs.contains { $0.hasPrefix(appPath) } || associated.contains(bundleID)
        }
    }

    /// Crash and hang reports such as `BucketBrowser-2026-10-21-080101.ips`.
    private func crashReports(in folder: URL, names: Set<String>) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { file in
            let name = file.lastPathComponent.lowercased()
            return ["ips", "crash", "diag", "spin", "hang"].contains(file.pathExtension.lowercased())
                && names.contains { name.hasPrefix($0 + "-") || name.hasPrefix($0 + "_") }
        }
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

/// What the app's code signature and Info.plist say about the files it creates elsewhere.
struct AppSigningInfo {
    var executableName: String?
    /// App group ids from the entitlements; each one owns a folder in `~/Library/Group Containers`.
    var applicationGroups: [String] = []
    /// Labels of privileged helpers installed with SMJobBless.
    var privilegedHelpers: [String] = []

    init(appURL: URL) {
        let info = Bundle(url: appURL)?.infoDictionary ?? [:]
        executableName = info["CFBundleExecutable"] as? String
        privilegedHelpers = Array(((info["SMPrivilegedExecutables"] as? [String: Any]) ?? [:]).keys)

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &code) == errSecSuccess, let code else { return }
        var signing: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess,
              let dict = signing as? [String: Any],
              let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return }
        applicationGroups = (entitlements["com.apple.security.application-groups"] as? [String]) ?? []
    }
}
