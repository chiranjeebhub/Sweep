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
/// from Finder. With `permanently`, files are deleted outright instead.
public struct Trasher: Sendable {
    let permanently: Bool

    public init(permanently: Bool = false) {
        self.permanently = permanently
    }

    public func trash(_ urls: [URL]) -> CleanResult {
        let fileManager = FileManager.default
        var result = CleanResult()
        for url in urls where fileManager.fileExists(atPath: url.path) {
            let size = FileSize.allocatedSize(of: url, fileManager: fileManager)
            do {
                if permanently {
                    try fileManager.removeItem(at: url)
                } else {
                    try fileManager.trashItem(at: url, resultingItemURL: nil)
                }
                result.freedBytes += size
                result.removedCount += 1
            } catch {
                result.failures.append(url)
            }
        }
        return result
    }

    /// Like `trash(_:)`, but files macOS won't let the user move (root-owned launch daemons,
    /// privileged helpers, folders in `/Library`) are moved to the Trash (or deleted) with
    /// administrator rights, after one password prompt. Launch jobs are unloaded first so they stop running.
    public func trashAskingForAdmin(_ urls: [URL]) -> CleanResult {
        var result = trash(urls)
        // Only files outside the home folder need admin rights; anything else failed for another reason.
        let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
        let protected = result.failures.filter { !$0.path.hasPrefix(home) }
        guard !protected.isEmpty else { return result }
        let sizes = protected.map { FileSize.allocatedSize(of: $0) }

        let trashFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let stamp = Int(Date().timeIntervalSince1970)
        let commands = protected.map { url -> String in
            let destination = trashFolder.appendingPathComponent("\(url.lastPathComponent) \(stamp)")
            var command = permanently
                ? "/bin/rm -rf \(Self.shellQuoted(url.path))"
                : "/bin/mv -f \(Self.shellQuoted(url.path)) \(Self.shellQuoted(destination.path))"
            if url.pathExtension == "plist", url.deletingLastPathComponent().lastPathComponent.hasPrefix("Launch") {
                command = "/bin/launchctl unload \(Self.shellQuoted(url.path)) 2>/dev/null; " + command
            }
            return command
        }
        let script = "do shell script \"\(Self.appleScriptEscaped(commands.joined(separator: "; ")))\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return result }
        process.waitUntilExit()

        result.failures.removeAll { protected.contains($0) }
        for (url, size) in zip(protected, sizes) {
            if FileManager.default.fileExists(atPath: url.path) {
                result.failures.append(url)
            } else {
                result.freedBytes += size
                result.removedCount += 1
            }
        }
        return result
    }

    static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptEscaped(_ string: String) -> String {
        string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
