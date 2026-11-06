import Darwin
import Foundation

/// One folder in a scan, with the space used by everything inside it.
///
/// Only folders are kept in memory. Files are counted into their folder, and the largest ones are
/// remembered separately in `ScanResult.largestFiles`.
public final class DirNode: @unchecked Sendable, Identifiable {
    /// The folder's name, or the full path for the scan's root.
    public let name: String
    public private(set) weak var parent: DirNode?
    public internal(set) var children: [DirNode] = []
    /// Space allocated on disk for everything inside, in bytes.
    public internal(set) var size: Int64 = 0
    /// Space allocated for the files directly inside this folder.
    public internal(set) var ownSize: Int64 = 0
    /// Files inside, at any depth.
    public internal(set) var fileCount: Int = 0
    public internal(set) var modified: Date?
    /// macOS did not let Sweep read this folder.
    public internal(set) var unreadable = false

    /// The rule that matched this folder itself, if any (set by the classifier).
    public internal(set) var ownRule: Rule?
    /// What the folder is: its own rule's classification or the one inherited from a parent.
    public internal(set) var classification: Classification?

    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(name: String, parent: DirNode?) {
        self.name = name
        self.parent = parent
    }

    public var path: String {
        guard let parent else { return name }
        let parentPath = parent.path
        return parentPath.hasSuffix("/") ? parentPath + name : parentPath + "/" + name
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    public var depth: Int {
        var depth = 0
        var node = parent
        while let current = node { depth += 1; node = current.parent }
        return depth
    }

    public func child(named name: String) -> DirNode? { children.first { $0.name == name } }

    /// The node for `path`, if it is this folder or inside it.
    public func node(at path: String) -> DirNode? {
        let root = self.path
        if path == root { return self }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var node: DirNode? = self
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            node = node?.child(named: String(component))
            if node == nil { return nil }
        }
        return node
    }

    /// Calls `body` for this folder and every folder inside it, parents first.
    public func walk(_ body: (DirNode) -> Void) {
        var stack: [DirNode] = [self]
        while let node = stack.popLast() {
            body(node)
            stack.append(contentsOf: node.children)
        }
    }

    func addChild(_ child: DirNode) { children.append(child) }

    /// Adds up sizes and file counts from the children.
    func rollUp() {
        size = ownSize + children.reduce(0) { $0 + $1.size }
        fileCount = ownFileCount + children.reduce(0) { $0 + $1.fileCount }
    }

    var ownFileCount = 0
}

/// A file large enough to appear in Largest items.
public struct FileEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let size: Int64
    public let modified: Date?

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { (path as NSString).lastPathComponent }
}

/// Everything one scan found.
public final class ScanResult: @unchecked Sendable {
    public let root: DirNode
    public let date: Date
    public let duration: TimeInterval
    public let largestFiles: [FileEntry]
    /// Folders macOS did not let Sweep read.
    public let unreadable: [String]

    init(root: DirNode, date: Date, duration: TimeInterval, largestFiles: [FileEntry], unreadable: [String]) {
        self.root = root
        self.date = date
        self.duration = duration
        self.largestFiles = largestFiles
        self.unreadable = unreadable
    }

    public var totalSize: Int64 { root.size }
    public var fileCount: Int { root.fileCount }
    public var rootURL: URL { root.url }
}

/// Live counters a scan updates as it goes. Safe to read from any thread.
public final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _files = 0
    private var _bytes: Int64 = 0
    private var _cancelled = false

    public init() {}

    public var files: Int { lock.sync { _files } }
    public var bytes: Int64 { lock.sync { _bytes } }
    public var isCancelled: Bool { lock.sync { _cancelled } }

    public func cancel() { lock.sync { _cancelled = true } }

    func add(files: Int, bytes: Int64) {
        lock.sync {
            _files += files
            _bytes += bytes
        }
    }
}

/// Measures every folder under a root, in parallel, by the space actually allocated on disk.
///
/// Symbolic links are never followed, other volumes are skipped, and a file with several hard links
/// is counted once. Nothing is changed.
public struct DiskScanner: Sendable {
    public let root: URL
    /// How many files Largest items keeps.
    public static let largestFileLimit = 500
    /// Folders this deep are measured as separate jobs, so the work spreads over all cores.
    static let splitDepth = 2

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.root = root.standardizedFileURL
    }

    public func scan(progress: ScanProgress = ScanProgress()) -> ScanResult {
        let started = Date()
        let rootNode = DirNode(name: root.path, parent: nil)
        var rootStat = stat()
        let device = lstat(root.path, &rootStat) == 0 ? rootStat.st_dev : 0
        rootNode.modified = Date(timeIntervalSince1970: TimeInterval(rootStat.st_mtimespec.tv_sec))

        let shared = SharedState()
        var jobs: [DirNode] = []
        var prepared: [DirNode] = []
        prepare(rootNode, depth: 0, device: device, shared: shared, progress: progress, jobs: &jobs, prepared: &prepared)

        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            Self.walk(jobs[index], device: device, shared: shared, progress: progress)
        }

        // The prepared levels were listed by hand; add up their sizes from the bottom.
        for node in prepared.reversed() { node.rollUp() }

        return ScanResult(
            root: rootNode,
            date: started,
            duration: Date().timeIntervalSince(started),
            largestFiles: shared.largestFiles(),
            unreadable: shared.unreadablePaths())
    }

    /// Lists the top levels directly: files are counted, folders deeper than `splitDepth` become jobs.
    private func prepare(_ node: DirNode, depth: Int, device: dev_t, shared: SharedState, progress: ScanProgress,
                         jobs: inout [DirNode], prepared: inout [DirNode]) {
        prepared.append(node)
        let path = node.path
        guard let directory = opendir(path) else {
            node.unreadable = true
            shared.noteUnreadable(path)
            return
        }
        defer { closedir(directory) }
        var files = 0
        var bytes: Int64 = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            let childPath = path.hasSuffix("/") ? path + name : path + "/" + name
            var info = stat()
            guard lstat(childPath, &info) == 0 else { continue }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                guard info.st_dev == device else { continue }
                let child = DirNode(name: name, parent: node)
                child.modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                node.addChild(child)
                if depth + 1 < Self.splitDepth {
                    prepare(child, depth: depth + 1, device: device, shared: shared, progress: progress, jobs: &jobs, prepared: &prepared)
                } else {
                    jobs.append(child)
                }
            } else {
                let size = shared.countedSize(info)
                node.ownSize += size
                node.ownFileCount += 1
                files += 1
                bytes += size
                shared.offer(path: childPath, size: size, info: info)
            }
        }
        progress.add(files: files, bytes: bytes)
    }

    /// Walks one folder with fts(3) and fills in its tree.
    private static func walk(_ top: DirNode, device: dev_t, shared: SharedState, progress: ScanProgress) {
        guard let rootPath = strdup(top.path) else { return }
        defer { free(rootPath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [rootPath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return }
        defer { fts_close(fts) }

        var stack: [DirNode] = []
        var pendingFiles = 0
        var pendingBytes: Int64 = 0
        let flushEvery = 2_000

        while let entry = fts_read(fts) {
            if progress.isCancelled { break }
            let info = Int32(entry.pointee.fts_info)
            let level = Int(entry.pointee.fts_level)
            switch info {
            case FTS_D:
                if level == 0 {
                    stack.append(top)
                } else {
                    let node = DirNode(name: entryName(entry), parent: stack.last)
                    if let stat = entry.pointee.fts_statp?.pointee {
                        node.modified = Date(timeIntervalSince1970: TimeInterval(stat.st_mtimespec.tv_sec))
                    }
                    stack.last?.addChild(node)
                    stack.append(node)
                }
            case FTS_DP:
                if let node = stack.popLast() { node.rollUp() }
            case FTS_DNR:
                let node = level == 0 ? top : DirNode(name: entryName(entry), parent: stack.last)
                node.unreadable = true
                if level > 0 { stack.last?.addChild(node) }
                shared.noteUnreadable(String(cString: entry.pointee.fts_path))
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let stat = entry.pointee.fts_statp?.pointee, let parent = stack.last else { continue }
                let size = shared.countedSize(stat)
                parent.ownSize += size
                parent.ownFileCount += 1
                pendingFiles += 1
                pendingBytes += size
                if size >= shared.largestThreshold {
                    shared.offer(path: String(cString: entry.pointee.fts_path), size: size, info: stat)
                }
                if pendingFiles >= flushEvery {
                    progress.add(files: pendingFiles, bytes: pendingBytes)
                    pendingFiles = 0
                    pendingBytes = 0
                }
            default:
                // FTS_DC (cycle), FTS_NS (no stat), FTS_ERR: nothing to measure.
                break
            }
        }
        progress.add(files: pendingFiles, bytes: pendingBytes)
        // A cancelled walk leaves folders open on the stack; give them their partial sizes.
        while let node = stack.popLast() { node.rollUp() }
    }

    private static func entryName(_ entry: UnsafeMutablePointer<FTSENT>) -> String {
        let length = Int(entry.pointee.fts_namelen)
        return withUnsafePointer(to: &entry.pointee.fts_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: length + 1) { String(cString: $0) }
        }
    }

    /// State shared by all scan jobs.
    final class SharedState: @unchecked Sendable {
        private struct Inode: Hashable { let device: Int32; let inode: UInt64 }
        private let lock = NSLock()
        private var seenLinks = Set<Inode>()
        private var largest: [FileEntry] = []
        private var unreadable: [String] = []
        /// The smallest size that can still make Largest items. Read without the lock; a stale value only costs a lookup.
        private(set) var largestThreshold: Int64 = 1_000_000

        /// The file's allocated size, or 0 when another hard link to it was already counted.
        func countedSize(_ info: stat) -> Int64 {
            let size = Int64(info.st_blocks) * 512
            guard info.st_nlink > 1, (info.st_mode & S_IFMT) == S_IFREG else { return size }
            let key = Inode(device: info.st_dev, inode: info.st_ino)
            return lock.sync { seenLinks.insert(key).inserted } ? size : 0
        }

        func offer(path: String, size: Int64, info: stat) {
            guard size >= largestThreshold else { return }
            let entry = FileEntry(path: path, size: size,
                                  modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)))
            lock.sync {
                largest.append(entry)
                if largest.count >= DiskScanner.largestFileLimit * 2 {
                    largest.sort { $0.size > $1.size }
                    largest.removeLast(largest.count - DiskScanner.largestFileLimit)
                    largestThreshold = largest.last?.size ?? largestThreshold
                }
            }
        }

        func noteUnreadable(_ path: String) {
            lock.sync { if unreadable.count < 500 { unreadable.append(path) } }
        }

        func largestFiles() -> [FileEntry] {
            lock.sync { Array(largest.sorted { $0.size > $1.size }.prefix(DiskScanner.largestFileLimit)) }
        }

        func unreadablePaths() -> [String] { lock.sync { unreadable.sorted() } }
    }
}

/// Space on the volume that holds a folder.
public struct VolumeInfo: Codable, Sendable, Equatable {
    public let name: String
    public let total: Int64
    public let available: Int64
    public var used: Int64 { max(0, total - available) }

    /// The startup disk by default. Purgeable space is not counted as available.
    public static func current(for url: URL = URL(fileURLWithPath: "/")) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeLocalizedNameKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacity else { return nil }
        return VolumeInfo(name: values.volumeLocalizedName ?? "Macintosh HD", total: Int64(total), available: Int64(available))
    }
}

extension NSLock {
    /// Runs `body` while holding the lock. (`withLock` needs macOS 14.)
    @discardableResult
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
