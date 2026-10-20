import Foundation

/// One kind of trace inside a source, such as Chrome's browsing history.
public struct PrivacyItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let urls: [URL]
    public let size: Int64
    /// Whether the item starts out selected. Things that sign you out are opt-in.
    public let selectedByDefault: Bool
}

/// A browser or a macOS activity list that leaves traces behind.
public struct PrivacySource: Identifiable, Sendable {
    public let id: String
    public let name: String
    /// The app that must be quit before cleaning, if any.
    public let bundleIdentifier: String?
    /// True when macOS blocks access until the app has Full Disk Access.
    public let needsFullDiskAccess: Bool
    public let items: [PrivacyItem]

    public var size: Int64 { items.reduce(0) { $0 + $1.size } }
}

/// Finds browsing traces and recent-item lists. Saved passwords and bookmarks are never touched.
public struct PrivacyScanner: Sendable {
    let library: URL

    public init(library: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")) {
        self.library = library
    }

    public func scan() -> [PrivacySource] {
        let chromium: [(String, String, String, String)] = [
            ("chrome", "Google Chrome", "com.google.Chrome", "Google/Chrome"),
            ("edge", "Microsoft Edge", "com.microsoft.edgemac", "Microsoft Edge"),
            ("brave", "Brave", "com.brave.Browser", "BraveSoftware/Brave-Browser"),
        ]
        var sources = chromium.compactMap { chromiumSource(id: $0.0, name: $0.1, bundleID: $0.2, folder: $0.3) }
        if let firefox = firefoxSource() { sources.append(firefox) }
        sources.append(safariSource())
        sources.append(recentItemsSource())
        return sources.filter { $0.needsFullDiskAccess || !$0.items.isEmpty }
    }

    // MARK: Browsers

    private func chromiumSource(id: String, name: String, bundleID: String, folder: String) -> PrivacySource? {
        let base = library.appendingPathComponent("Application Support/\(folder)")
        guard FileManager.default.fileExists(atPath: base.path) else { return nil }
        let profiles = ((try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }

        func files(_ names: [String]) -> [URL] {
            profiles.flatMap { profile in names.map { profile.appendingPathComponent($0) } }
        }

        let items = [
            item("\(id).history", "Browsing and download history", "Sites you visited and files you downloaded",
                 files(["History", "History-journal", "Visited Links"]), selected: true),
            item("\(id).cache", "Cached images and files", "Pages may load a little slower the first time",
                 [library.appendingPathComponent("Caches/\(folder)")], selected: true),
            item("\(id).sessions", "Tabs from last session", "Tabs the browser reopens at launch",
                 files(["Sessions", "Current Session", "Current Tabs", "Last Session", "Last Tabs"]), selected: true),
            item("\(id).cookies", "Cookies", "You will be signed out of websites",
                 files(["Cookies", "Cookies-journal"]), selected: false),
            item("\(id).autofill", "Autofill form values", "Names, addresses and search entries",
                 files(["Web Data", "Web Data-journal"]), selected: false),
        ].compactMap { $0 }

        return PrivacySource(id: id, name: name, bundleIdentifier: bundleID, needsFullDiskAccess: false, items: items)
    }

    private func firefoxSource() -> PrivacySource? {
        let profilesFolder = library.appendingPathComponent("Application Support/Firefox/Profiles")
        guard let profiles = try? FileManager.default.contentsOfDirectory(at: profilesFolder, includingPropertiesForKeys: nil),
              !profiles.isEmpty else { return nil }

        func files(_ names: [String]) -> [URL] {
            profiles.flatMap { profile in names.map { profile.appendingPathComponent($0) } }
        }

        // Firefox keeps history and bookmarks in one database, so history is left alone.
        let items = [
            item("firefox.cache", "Cached images and files", "Pages may load a little slower the first time",
                 [library.appendingPathComponent("Caches/Firefox/Profiles")], selected: true),
            item("firefox.sessions", "Tabs from last session", "Tabs Firefox reopens at launch",
                 files(["sessionstore.jsonlz4", "sessionstore-backups"]), selected: true),
            item("firefox.forms", "Form history", "Search and form entries",
                 files(["formhistory.sqlite"]), selected: false),
            item("firefox.cookies", "Cookies", "You will be signed out of websites",
                 files(["cookies.sqlite", "cookies.sqlite-wal"]), selected: false),
        ].compactMap { $0 }
        return PrivacySource(id: "firefox", name: "Firefox", bundleIdentifier: "org.mozilla.firefox",
                             needsFullDiskAccess: false, items: items)
    }

    private func safariSource() -> PrivacySource {
        let safari = library.appendingPathComponent("Safari")
        let history = safari.appendingPathComponent("History.db")
        // Safari's folder is protected. Listing it fails until the app has Full Disk Access.
        let locked = (try? FileManager.default.contentsOfDirectory(atPath: safari.path)) == nil
        guard !locked else {
            return PrivacySource(id: "safari", name: "Safari", bundleIdentifier: "com.apple.Safari",
                                 needsFullDiskAccess: true, items: [])
        }
        let items = [
            item("safari.history", "Browsing history", "Sites you visited and when",
                 [history, safari.appendingPathComponent("History.db-wal"), safari.appendingPathComponent("History.db-shm")],
                 selected: true),
            item("safari.downloads", "Download history", "The list of downloads, not the files",
                 [safari.appendingPathComponent("Downloads.plist")], selected: true),
            item("safari.cache", "Cached images and files", "Pages may load a little slower the first time",
                 [library.appendingPathComponent("Caches/com.apple.Safari")], selected: true),
            item("safari.cookies", "Cookies", "You will be signed out of websites",
                 [library.appendingPathComponent("Cookies/Cookies.binarycookies")], selected: false),
        ].compactMap { $0 }
        return PrivacySource(id: "safari", name: "Safari", bundleIdentifier: "com.apple.Safari",
                             needsFullDiskAccess: false, items: items)
    }

    // MARK: macOS

    private func recentItemsSource() -> PrivacySource {
        let folder = library.appendingPathComponent("Application Support/com.apple.sharedfilelist")
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        var lists: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension.hasPrefix("sfl") { lists.append(url) }
        }
        let items = [
            item("recents.lists", "Recent documents, apps and servers", "The lists in the Apple menu and in apps' Open Recent menus",
                 lists, selected: true),
        ].compactMap { $0 }
        return PrivacySource(id: "recents", name: "Recent items", bundleIdentifier: nil, needsFullDiskAccess: false, items: items)
    }

    // MARK: Helpers

    private func item(_ id: String, _ title: String, _ detail: String, _ urls: [URL], selected: Bool) -> PrivacyItem? {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return nil }
        return PrivacyItem(id: id, title: title, detail: detail, urls: existing,
                           size: FileSize.allocatedSize(of: existing), selectedByDefault: selected)
    }
}
