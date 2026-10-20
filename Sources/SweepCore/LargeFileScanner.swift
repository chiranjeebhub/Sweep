import Foundation
import UniformTypeIdentifiers

/// A big file in the user's folders.
public struct LargeFile: Identifiable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case video = "Videos"
        case archive = "Archives"
        case diskImage = "Disk images"
        case other = "Other"
    }

    public var id: URL { url }
    public let url: URL
    public let size: Int64
    public let kind: Kind
    public let lastOpened: Date?

    public var name: String { url.lastPathComponent }
    public var location: String { url.deletingLastPathComponent().abbreviatedPath }

    public init(url: URL, size: Int64, kind: Kind, lastOpened: Date?) {
        self.url = url
        self.size = size
        self.kind = kind
        self.lastOpened = lastOpened
    }

    public static func kind(for url: URL) -> Kind {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .other }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .diskImage) || ["dmg", "iso", "img", "sparseimage"].contains(url.pathExtension.lowercased()) {
            return .diskImage
        }
        if type.conforms(to: .archive) || ["zip", "tar", "gz", "tgz", "rar", "7z", "xip", "pkg"].contains(url.pathExtension.lowercased()) {
            return .archive
        }
        return .other
    }
}

/// Finds files above a size threshold in the user's personal folders.
/// App bundles, photo libraries and other packages are skipped as a whole.
public struct LargeFileScanner: Sendable {
    public static let defaultThreshold: Int64 = 100 * 1024 * 1024

    let roots: [URL]
    let threshold: Int64

    public init(roots: [URL]? = nil, threshold: Int64 = LargeFileScanner.defaultThreshold) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.roots = roots ?? ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]
            .map { home.appendingPathComponent($0) }
        self.threshold = threshold
    }

    public func scan() -> [LargeFile] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentAccessDateKey,
        ]
        var found: [LargeFile] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else { continue }
                let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                guard size >= threshold else { continue }
                found.append(LargeFile(
                    url: url, size: size, kind: LargeFile.kind(for: url), lastOpened: values.contentAccessDate))
            }
        }
        return found.sorted { $0.size > $1.size }
    }
}
