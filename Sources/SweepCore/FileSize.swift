import Foundation

/// Helpers for measuring how much disk space files and folders use.
public enum FileSize {
    private static let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    /// The allocated size of a file, or the total allocated size of everything inside a folder.
    /// Unreadable entries are skipped rather than failing the whole measurement.
    public static func allocatedSize(of url: URL, fileManager: FileManager = .default) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let childValues = try? child.resourceValues(forKeys: keys),
                  childValues.isRegularFile == true else { continue }
            total += Int64(childValues.totalFileAllocatedSize ?? childValues.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Sum of `allocatedSize(of:)` for several URLs that may not exist.
    public static func allocatedSize(of urls: [URL], fileManager: FileManager = .default) -> Int64 {
        urls.filter { fileManager.fileExists(atPath: $0.path) }
            .reduce(0) { $0 + allocatedSize(of: $1, fileManager: fileManager) }
    }
}

/// Human-readable byte counts that match Finder ("1.2 GB").
public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Short relative dates for "last used" columns ("3 days ago").
public enum RelativeDate {
    public static func string(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Never" }
        if now.timeIntervalSince(date) < 60 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

extension URL {
    /// The path with the home folder shortened to `~`, for display.
    public var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
