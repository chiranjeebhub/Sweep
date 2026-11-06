import Foundation

/// Saves the last scan so the Overview and Storage screens have something to show after a restart.
///
/// Folders under a size threshold below the top levels are left out of the saved copy. Their space
/// stays counted in their parent, so totals don't change.
public enum ScanStore {
    struct Snapshot: Codable {
        var version = 1
        var date: Date
        var duration: TimeInterval
        var names: [String]
        var parents: [Int32]
        var sizes: [Int64]
        var ownSizes: [Int64]
        var fileCounts: [Int32]
        var modified: [Double]
        var unreadableNodes: [Int32]
        var largestFiles: [FileEntry]
        var unreadable: [String]
    }

    static let minimumSavedSize: Int64 = 256 * 1024
    static var url: URL { SweepFolders.support.appendingPathComponent("last-scan.json") }

    public static func save(_ result: ScanResult) {
        var snapshot = Snapshot(date: result.date, duration: result.duration, names: [], parents: [], sizes: [], ownSizes: [],
                                fileCounts: [], modified: [], unreadableNodes: [], largestFiles: result.largestFiles,
                                unreadable: result.unreadable)
        var queue: [(DirNode, Int32, Int)] = [(result.root, -1, 0)]
        var index = 0
        while index < queue.count {
            let (node, parent, depth) = queue[index]
            index += 1
            let kept = node.children.filter { depth < 2 || $0.size >= minimumSavedSize }
            let position = Int32(snapshot.names.count)
            snapshot.names.append(node.name)
            snapshot.parents.append(parent)
            snapshot.sizes.append(node.size)
            snapshot.ownSizes.append(node.size - kept.reduce(0) { $0 + $1.size })
            snapshot.fileCounts.append(Int32(clamping: node.fileCount))
            snapshot.modified.append(node.modified?.timeIntervalSince1970 ?? -1)
            if node.unreadable { snapshot.unreadableNodes.append(position) }
            for child in kept { queue.append((child, position, depth + 1)) }
        }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: SweepFolders.support, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public static func load() -> ScanResult? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == 1, !snapshot.names.isEmpty else { return nil }
        var nodes: [DirNode] = []
        nodes.reserveCapacity(snapshot.names.count)
        let unreadable = Set(snapshot.unreadableNodes)
        for index in snapshot.names.indices {
            let parentIndex = Int(snapshot.parents[index])
            let parent = parentIndex >= 0 && parentIndex < nodes.count ? nodes[parentIndex] : nil
            let node = DirNode(name: snapshot.names[index], parent: parent)
            node.size = snapshot.sizes[index]
            node.ownSize = snapshot.ownSizes[index]
            node.fileCount = Int(snapshot.fileCounts[index])
            node.modified = snapshot.modified[index] >= 0 ? Date(timeIntervalSince1970: snapshot.modified[index]) : nil
            node.unreadable = unreadable.contains(Int32(index))
            parent?.addChild(node)
            nodes.append(node)
        }
        return ScanResult(root: nodes[0], date: snapshot.date, duration: snapshot.duration,
                          largestFiles: snapshot.largestFiles, unreadable: snapshot.unreadable)
    }

    public static func clear() { try? FileManager.default.removeItem(at: url) }
}
