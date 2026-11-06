import CryptoKit
import Darwin
import Foundation

/// One copy in a set of identical files.
public struct DuplicateFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let modified: Date?
    /// The copy shares its storage with another file (an APFS clone), so removing it frees little or nothing.
    public let isClone: Bool

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { (path as NSString).lastPathComponent }
}

/// Files with identical contents.
public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    public let id: String
    /// The size of one copy.
    public let size: Int64
    public let files: [DuplicateFile]

    /// Space freed by keeping one copy, leaving out copies that are clones.
    public var reclaimable: Int64 {
        let removable = files.dropFirst().filter { !$0.isClone }.count
        return size * Int64(removable)
    }
}

/// Progress for the duplicate finder. Safe to read from any thread.
public final class DuplicateProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _phase = "Listing files"
    private var _done = 0
    private var _total = 0
    private var _cancelled = false

    public init() {}

    public var phase: String { lock.sync { _phase } }
    public var done: Int { lock.sync { _done } }
    public var total: Int { lock.sync { _total } }
    public var isCancelled: Bool { lock.sync { _cancelled } }
    public func cancel() { lock.sync { _cancelled = true } }

    func set(phase: String, total: Int) { lock.sync { _phase = phase; _total = total; _done = 0 } }
    func step(_ count: Int = 1) { lock.sync { _done += count } }
}

/// Finds files with identical contents: same size first, then the same first block, then the same SHA-256.
///
/// Hidden folders, `~/Library`, app and document bundles, dependency folders and package caches are skipped.
/// Hard links to one file count once. Nothing is changed.
public struct DuplicateFinder: Sendable {
    public let roots: [URL]
    public let minimumSize: Int64
    static let skippedNames: Set<String> = ["node_modules", "Pods", "DerivedData", "target", "venv", "__pycache__", "vendor", "bower_components"]

    public init(roots: [URL] = [FileManager.default.homeDirectoryForCurrentUser], minimumSize: Int64 = 1_000_000) {
        self.roots = roots
        self.minimumSize = minimumSize
    }

    public func find(progress: DuplicateProgress = DuplicateProgress()) -> [DuplicateGroup] {
        // 1. List candidate files by size.
        progress.set(phase: "Listing files", total: 0)
        var bySize: [Int64: [Candidate]] = [:]
        var seenInodes = Set<String>()
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in enumerator {
                if progress.isCancelled { return [] }
                let name = url.lastPathComponent
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]) else { continue }
                if values.isDirectory == true {
                    if values.isPackage == true || Self.skippedNames.contains(name) || url.path == library || name.hasSuffix(".app") {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                var info = stat()
                guard lstat(url.path, &info) == 0, Int64(info.st_size) >= minimumSize else { continue }
                let inode = "\(info.st_dev):\(info.st_ino)"
                guard seenInodes.insert(inode).inserted else { continue }
                bySize[Int64(info.st_size), default: []].append(
                    Candidate(path: url.path, size: Int64(info.st_size),
                              modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))))
                progress.step()
            }
        }
        let sameSize = bySize.values.filter { $0.count > 1 }

        // 2. Same first 64 KB.
        progress.set(phase: "Comparing the start of each file", total: sameSize.reduce(0) { $0 + $1.count })
        var groups: [[Candidate]] = []
        for candidates in sameSize {
            if progress.isCancelled { return [] }
            var byHead: [Data: [Candidate]] = [:]
            for candidate in candidates {
                if let head = Self.digest(of: candidate.path, limit: 65_536) { byHead[head, default: []].append(candidate) }
                progress.step()
            }
            groups += byHead.values.filter { $0.count > 1 }
        }

        // 3. Same full SHA-256.
        progress.set(phase: "Comparing full contents", total: groups.reduce(0) { $0 + $1.count })
        var results: [DuplicateGroup] = []
        for candidates in groups {
            if progress.isCancelled { return [] }
            var byHash: [Data: [Candidate]] = [:]
            for candidate in candidates {
                if candidate.size <= 65_536 {
                    // The head digest already covered the whole file.
                    if let digest = Self.digest(of: candidate.path, limit: 65_536) { byHash[digest, default: []].append(candidate) }
                } else if let digest = Self.digest(of: candidate.path, limit: nil) {
                    byHash[digest, default: []].append(candidate)
                }
                progress.step()
            }
            for (digest, matches) in byHash where matches.count > 1 {
                let sorted = matches.sorted { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }
                let files = sorted.map { DuplicateFile(path: $0.path, modified: $0.modified, isClone: Self.sharesStorage($0.path, size: $0.size)) }
                results.append(DuplicateGroup(id: digest.map { String(format: "%02x", $0) }.joined(), size: sorted[0].size, files: files))
            }
        }
        return results.sorted { $0.reclaimable > $1.reclaimable }
    }

    struct Candidate: Sendable {
        let path: String
        let size: Int64
        let modified: Date?
    }

    /// SHA-256 of the first `limit` bytes, or of the whole file.
    static func digest(of path: String, limit: Int?) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            let chunk = handle.readData(ofLength: min(1 << 20, remaining))
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return Data(hasher.finalize())
    }

    /// True when most of the file's blocks are shared with another file, as with an APFS clone.
    static func sharesStorage(_ path: String, size: Int64) -> Bool {
        guard size > 0, let privateSize = privateSize(of: path) else { return false }
        return privateSize < size / 2
    }

    /// Bytes of the file not shared with clones or snapshots, from getattrlist(2) ATTR_CMNEXT_PRIVATESIZE.
    static func privateSize(of path: String) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.forkattr = attrgroup_t(0x0000_0008) // ATTR_CMNEXT_PRIVATESIZE
        var buffer = [UInt8](repeating: 0, count: 64)
        let options = UInt32(0x0000_0020) // FSOPT_ATTR_CMN_EXTENDED
        let status = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &request, raw.baseAddress, raw.count, options)
        }
        guard status == 0 else { return nil }
        // Layout: UInt32 length, then the off_t value.
        return buffer.withUnsafeBytes { raw in
            guard raw.load(as: UInt32.self) >= 12 else { return nil }
            return raw.loadUnaligned(fromByteOffset: 4, as: Int64.self)
        }
    }

    /// Removes one copy after checking, byte for byte, that it still matches the copy being kept.
    public static func removeCopy(_ path: String, keeping keeper: String, method: CleanupMethod = .trash) -> CleanupItemResult {
        guard FileManager.default.fileExists(atPath: keeper) else {
            return CleanupItemResult(path: path, bytes: 0, error: "The copy you kept is gone, so this one was left alone.")
        }
        guard FileManager.default.contentsEqual(atPath: path, andPath: keeper) else {
            return CleanupItemResult(path: path, bytes: 0, error: "It no longer matches the copy you kept.")
        }
        return CleanupExecutor(method: method).remove(path: path)
    }
}
