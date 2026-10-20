import Foundation

/// A newer version of an installed app.
public struct AppUpdate: Identifiable, Sendable {
    public enum Source: Sendable {
        /// Updated through the App Store. The URL is the app's store page.
        case appStore(URL?)
        /// The developer's Sparkle feed. The URL is the download for the new version.
        case sparkle(URL)
    }

    public var id: URL { app.url }
    public let app: InstalledApp
    public let latestVersion: String
    public let source: Source
}

public enum VersionCompare {
    /// True when `candidate` is later than `current`. Parts are compared as numbers, so
    /// 1.10 is later than 1.9, and missing parts count as zero, so 1.0 equals 1.0.0.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.trimmingCharacters(in: .whitespaces).split(separator: ".")
        let b = current.trimmingCharacters(in: .whitespaces).split(separator: ".")
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? String(a[index]) : "0"
            let right = index < b.count ? String(b[index]) : "0"
            let order = left.compare(right, options: .numeric)
            if order != .orderedSame { return order == .orderedDescending }
        }
        return false
    }
}

/// Checks apps from the App Store and apps that update through Sparkle, the update system
/// most Mac apps outside the App Store use.
public struct UpdateChecker: Sendable {
    public init() {}

    public func check(_ apps: [InstalledApp]) async -> [AppUpdate] {
        await withTaskGroup(of: AppUpdate?.self) { group in
            for app in apps {
                group.addTask { await self.check(app) }
            }
            var found: [AppUpdate] = []
            for await update in group {
                if let update { found.append(update) }
            }
            return found.sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
        }
    }

    public func check(_ app: InstalledApp) async -> AppUpdate? {
        let receipt = app.url.appendingPathComponent("Contents/_MASReceipt/receipt")
        if FileManager.default.fileExists(atPath: receipt.path) {
            return await checkAppStore(app)
        }
        let info = Bundle(url: app.url)?.infoDictionary ?? [:]
        guard let feedString = info["SUFeedURL"] as? String,
              let feed = URL(string: feedString.trimmingCharacters(in: .whitespaces)),
              feed.scheme == "https" else { return nil }
        return await checkSparkle(app, feed: feed, build: info["CFBundleVersion"] as? String)
    }

    private struct LookupResponse: Decodable {
        struct Result: Decodable {
            let version: String
            let trackViewUrl: String?
        }
        let results: [Result]
    }

    private func checkAppStore(_ app: InstalledApp) async -> AppUpdate? {
        guard let identifier = app.bundleIdentifier, let current = app.version,
              var components = URLComponents(string: "https://itunes.apple.com/lookup") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: identifier),
            URLQueryItem(name: "entity", value: "desktopSoftware"),
        ]
        if let country = Locale.current.region?.identifier {
            components.queryItems?.append(URLQueryItem(name: "country", value: country))
        }
        guard let url = components.url, let data = await fetch(url),
              let response = try? JSONDecoder().decode(LookupResponse.self, from: data),
              let result = response.results.first,
              VersionCompare.isNewer(result.version, than: current) else { return nil }
        return AppUpdate(app: app, latestVersion: result.version,
                         source: .appStore(result.trackViewUrl.flatMap(URL.init(string:))))
    }

    private func checkSparkle(_ app: InstalledApp, feed: URL, build: String?) async -> AppUpdate? {
        guard let data = await fetch(feed) else { return nil }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let candidates = AppcastParser.parse(data).filter { item in
            item.channel == nil && item.downloadURL != nil
                && !(item.minimumSystemVersion.map { VersionCompare.isNewer($0, than: osVersion) } ?? false)
        }
        guard let latest = candidates.max(by: { VersionCompare.isNewer($1.comparableVersion, than: $0.comparableVersion) }),
              let download = latest.downloadURL else { return nil }

        // Sparkle compares the feed's build number with the app's CFBundleVersion.
        let isNewer: Bool
        if let build, let version = latest.version {
            isNewer = VersionCompare.isNewer(version, than: build)
        } else if let short = latest.shortVersion, let current = app.version {
            isNewer = VersionCompare.isNewer(short, than: current)
        } else {
            isNewer = false
        }
        guard isNewer else { return nil }
        return AppUpdate(app: app, latestVersion: latest.shortVersion ?? latest.version ?? "", source: .sparkle(download))
    }

    private func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return result.0
    }
}

/// Reads the release list from a Sparkle appcast feed.
final class AppcastParser: NSObject, XMLParserDelegate {
    struct Item {
        var version: String?
        var shortVersion: String?
        var downloadURL: URL?
        var minimumSystemVersion: String?
        var channel: String?

        var comparableVersion: String { version ?? shortVersion ?? "0" }
    }

    private var items: [Item] = []
    private var current: Item?
    private var text = ""
    /// Delta updates have their own enclosures, which only Sparkle itself can apply.
    private var inDeltas = false

    static func parse(_ data: Data) -> [Item] {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "item":
            current = Item()
        case "sparkle:deltas":
            inDeltas = true
        case "enclosure" where current != nil && !inDeltas:
            if let value = attributeDict["sparkle:version"] { current?.version = value }
            if let value = attributeDict["sparkle:shortVersionString"] { current?.shortVersion = value }
            if let value = attributeDict["sparkle:minimumSystemVersion"] { current?.minimumSystemVersion = value }
            if let value = attributeDict["url"] { current?.downloadURL = URL(string: value) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "item":
            if let current { items.append(current) }
            current = nil
        case "sparkle:deltas":
            inDeltas = false
        case "sparkle:version" where !value.isEmpty && !inDeltas:
            current?.version = value
        case "sparkle:shortVersionString" where !value.isEmpty && !inDeltas:
            current?.shortVersion = value
        case "sparkle:minimumSystemVersion" where !value.isEmpty:
            current?.minimumSystemVersion = value
        case "sparkle:channel" where !value.isEmpty:
            current?.channel = value
        default:
            break
        }
        text = ""
    }
}

/// Downloads a Sparkle update and swaps it in for the installed app.
public enum UpdateInstaller {
    public enum Failure: Error, LocalizedError {
        case unsupportedDownload, downloadFailed, unpackFailed, noApp, signatureMismatch, replaceFailed

        public var errorDescription: String? {
            switch self {
            case .unsupportedDownload: "The download isn't a zip or disk image."
            case .downloadFailed: "The download failed."
            case .unpackFailed: "The download couldn't be opened."
            case .noApp: "The download doesn't contain the app."
            case .signatureMismatch: "The new version isn't signed by the same developer, so it wasn't installed."
            case .replaceFailed: "The old version couldn't be replaced. Update it from inside the app."
            }
        }
    }

    enum ArchiveKind { case zip, diskImage, tarball }

    static func archiveKind(_ url: URL) -> ArchiveKind? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") { return .zip }
        if name.hasSuffix(".dmg") { return .diskImage }
        if [".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tar.xz", ".txz"].contains(where: { name.hasSuffix($0) }) { return .tarball }
        return nil
    }

    /// Whether `install` can handle this download. Anything else opens in the browser.
    public static func canInstall(_ download: URL) -> Bool {
        archiveKind(download) != nil
    }

    public static func install(_ update: AppUpdate) async throws {
        guard case .sparkle(let download) = update.source, let kind = archiveKind(download) else {
            throw Failure.unsupportedDownload
        }
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("Sweep-update-\(UUID().uuidString)")
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        let downloaded: URL
        do {
            let (location, response) = try await URLSession.shared.download(from: download)
            if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                throw Failure.downloadFailed
            }
            downloaded = work.appendingPathComponent(download.lastPathComponent)
            try fileManager.moveItem(at: location, to: downloaded)
        } catch {
            throw Failure.downloadFailed
        }

        let extracted = work.appendingPathComponent("extracted")
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
        try unpack(downloaded, kind: kind, into: extracted, work: work)

        guard let newApp = findApp(in: extracted, bundleIdentifier: update.app.bundleIdentifier, depth: 2) else {
            throw Failure.noApp
        }
        guard let team = CodeSignature.teamIdentifier(of: update.app.url),
              CodeSignature.teamIdentifier(of: newApp) == team,
              CodeSignature.isValid(newApp) else { throw Failure.signatureMismatch }
        try replace(update.app.url, with: newApp)
    }

    private static func unpack(_ archive: URL, kind: ArchiveKind, into folder: URL, work: URL) throws {
        switch kind {
        case .zip:
            guard Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path]).status == 0 else {
                throw Failure.unpackFailed
            }
        case .tarball:
            guard Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", folder.path]).status == 0 else {
                throw Failure.unpackFailed
            }
        case .diskImage:
            let mount = work.appendingPathComponent("mount")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            // "Y" accepts the license agreement some disk images show before they mount.
            let attach = Shell.run("/usr/bin/hdiutil",
                                   ["attach", archive.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path],
                                   input: "Y\n")
            guard attach.status == 0 else { throw Failure.unpackFailed }
            defer { Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            let apps = ((try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "app" }
            for app in apps {
                guard Shell.run("/usr/bin/ditto", [app.path, folder.appendingPathComponent(app.lastPathComponent).path]).status == 0 else {
                    throw Failure.unpackFailed
                }
            }
        }
    }

    /// The app with `bundleIdentifier` in `folder`, or the first app found.
    static func findApp(in folder: URL, bundleIdentifier: String?, depth: Int) -> URL? {
        var apps: [URL] = []
        var folders = [folder]
        for _ in 0..<depth {
            var next: [URL] = []
            for current in folders {
                for child in (try? FileManager.default.contentsOfDirectory(at: current, includingPropertiesForKeys: nil)) ?? [] {
                    if child.pathExtension == "app" { apps.append(child) } else { next.append(child) }
                }
            }
            folders = next
        }
        return apps.first { Bundle(url: $0)?.bundleIdentifier == bundleIdentifier } ?? apps.first
    }

    /// Moves the old version to the Trash and puts the new one in its place, restoring the old
    /// one if the move fails.
    private static func replace(_ old: URL, with new: URL) throws {
        let fileManager = FileManager.default
        var trashed: NSURL?
        do {
            try fileManager.trashItem(at: old, resultingItemURL: &trashed)
        } catch {
            throw Failure.replaceFailed
        }
        do {
            try fileManager.moveItem(at: new, to: old)
        } catch {
            if let trashed = trashed as URL? { try? fileManager.moveItem(at: trashed, to: old) }
            throw Failure.replaceFailed
        }
    }
}
