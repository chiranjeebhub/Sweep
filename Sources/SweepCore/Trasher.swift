import Foundation

/// The outcome of moving files to the Trash.
public struct CleanResult: Sendable {
    public var freedBytes: Int64 = 0
    public var removedCount = 0
    public var failures: [URL] = []

    public init() {}

    public mutating func merge(_ other: CleanResult) {
        freedBytes += other.freedBytes
        removedCount += other.removedCount
        failures += other.failures
    }
}

/// Moves files to the user's Trash instead of deleting them, so every clean can be undone
/// from Finder.
public struct Trasher: Sendable {
    public init() {}

    public func trash(_ urls: [URL]) -> CleanResult {
        let fileManager = FileManager.default
        var result = CleanResult()
        for url in urls where fileManager.fileExists(atPath: url.path) {
            let size = FileSize.allocatedSize(of: url, fileManager: fileManager)
            do {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
                result.freedBytes += size
                result.removedCount += 1
            } catch {
                result.failures.append(url)
            }
        }
        return result
    }
}
