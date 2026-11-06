import Darwin
import Foundation

/// One item in a Trash: on the startup disk or on another disk.
public struct TrashItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let size: Int64
    public let isFolder: Bool
    /// When it was put in the Trash, as far as the file system can tell.
    public let trashedDate: Date?
    /// The disk it is on, for items in another disk's Trash.
    public let volume: String?

    public var name: String { (path as NSString).lastPathComponent }
    public var url: URL { URL(fileURLWithPath: path) }
}

/// Reads the Trash and empties it item by item.
public enum TrashBins {
    public enum ReadError: Error, Sendable {
        /// macOS needs Full Disk Access before an app can look inside the Trash.
        case notPermitted
    }

    /// The Trash folders Sweep knows about: the home folder's and each mounted disk's.
    public static func folders() -> [(url: URL, volume: String?)] {
        var folders: [(URL, String?)] = [(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"), nil)]
        let uid = getuid()
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        for name in volumes {
            let trash = URL(fileURLWithPath: "/Volumes/\(name)/.Trashes/\(uid)")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: trash.path, isDirectory: &isDirectory), isDirectory.boolValue {
                folders.append((trash, name))
            }
        }
        return folders
    }

    public static func items() -> Result<[TrashItem], ReadError> {
        var items: [TrashItem] = []
        var readHome = false
        for (folder, volume) in folders() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            if volume == nil { readHome = true }
            for name in names where name != ".DS_Store" {
                let url = folder.appendingPathComponent(name)
                var info = stat()
                guard lstat(url.path, &info) == 0 else { continue }
                let isFolder = (info.st_mode & S_IFMT) == S_IFDIR
                items.append(TrashItem(path: url.path, size: FileSize.allocatedSize(of: url), isFolder: isFolder,
                                       trashedDate: Date(timeIntervalSince1970: TimeInterval(info.st_ctimespec.tv_sec)),
                                       volume: volume))
            }
        }
        if !readHome { return .failure(.notPermitted) }
        return .success(items.sorted { $0.size > $1.size })
    }

    /// Deletes one item that is directly inside a known Trash folder.
    public static func delete(_ item: TrashItem) -> CleanupItemResult {
        let parent = (item.path as NSString).deletingLastPathComponent
        guard folders().contains(where: { $0.url.path == parent }) else {
            return CleanupItemResult(path: item.path, bytes: 0, error: "It is not in the Trash any more.")
        }
        var info = stat()
        guard lstat(item.path, &info) == 0 else {
            return CleanupItemResult(path: item.path, bytes: 0, error: "It is not in the Trash any more.")
        }
        do {
            try FileManager.default.removeItem(atPath: item.path)
            return CleanupItemResult(path: item.path, bytes: item.size, error: nil)
        } catch {
            return CleanupItemResult(path: item.path, bytes: 0, error: error.localizedDescription)
        }
    }
}
