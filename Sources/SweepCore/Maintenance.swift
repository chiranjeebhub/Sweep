import Foundation

/// A housekeeping job from the Maintenance screen.
public struct MaintenanceTask: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let symbol: String
    /// The tool the command runs. Tasks whose tool is missing on this macOS aren't offered.
    let tool: String
    let command: String
    public let needsAdmin: Bool
    public let selectedByDefault: Bool
    /// Shown when the task fails, when a plain "Failed" wouldn't help.
    public let failureHint: String?

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    static let all: [MaintenanceTask] = [
        MaintenanceTask(
            id: "scripts", title: "Run maintenance scripts",
            detail: "Rotates system logs and clears temporary files macOS normally tidies overnight",
            symbol: "scroll", tool: "/usr/sbin/periodic", command: "/usr/sbin/periodic daily weekly monthly",
            needsAdmin: true, selectedByDefault: true, failureHint: nil),
        MaintenanceTask(
            id: "launchservices", title: "Rebuild Launch Services",
            detail: "Fixes duplicate apps in \"Open With\" and files opening in the wrong app",
            symbol: "arrow.up.forward.app", tool: lsregister,
            command: "\(lsregister) -r -domain local -domain system -domain user",
            needsAdmin: false, selectedByDefault: true, failureHint: nil),
        MaintenanceTask(
            id: "quicklook", title: "Clear Quick Look cache",
            detail: "Fixes missing or out-of-date file previews and thumbnails",
            symbol: "eye", tool: "/usr/bin/qlmanage", command: "/usr/bin/qlmanage -r cache",
            needsAdmin: false, selectedByDefault: true, failureHint: nil),
        MaintenanceTask(
            id: "spotlight", title: "Reindex Spotlight",
            detail: "Rebuilds the search index. Search results stay incomplete until it finishes",
            symbol: "magnifyingglass", tool: "/usr/bin/mdutil", command: "/usr/bin/mdutil -E /",
            needsAdmin: true, selectedByDefault: false, failureHint: nil),
        MaintenanceTask(
            id: "snapshots", title: "Thin Time Machine snapshots",
            detail: "Frees space held by local snapshots. Backups on your backup disk aren't touched",
            symbol: "clock.arrow.circlepath", tool: "/usr/bin/tmutil",
            command: "/usr/bin/tmutil thinlocalsnapshots / 999999999999 4",
            needsAdmin: true, selectedByDefault: false, failureHint: nil),
        MaintenanceTask(
            id: "fonts", title: "Clear font caches",
            detail: "Fixes garbled or missing fonts. Takes effect after you log out",
            symbol: "textformat", tool: "/usr/bin/atsutil", command: "/usr/bin/atsutil databases -removeUser",
            needsAdmin: false, selectedByDefault: false, failureHint: nil),
        MaintenanceTask(
            id: "verifydisk", title: "Verify startup disk",
            detail: "Checks the disk for errors. This can take a few minutes",
            symbol: "internaldrive", tool: "/usr/sbin/diskutil", command: "/usr/sbin/diskutil verifyVolume /",
            needsAdmin: true, selectedByDefault: false,
            failureHint: "Problems found. Run First Aid in Disk Utility from macOS Recovery."),
    ]

    /// The tasks this Mac can run.
    public static var available: [MaintenanceTask] {
        all.filter { FileManager.default.isExecutableFile(atPath: $0.tool) }
    }
}

public enum MaintenanceResult: Sendable, Equatable {
    case done, failed, cancelled
}

public enum MaintenanceRunner {
    static let marker = "sweep-result"

    /// Runs `tasks`. Tasks that need an administrator password run together after one prompt.
    public static func run(_ tasks: [MaintenanceTask]) -> [String: MaintenanceResult] {
        var results: [String: MaintenanceResult] = [:]
        for task in tasks where !task.needsAdmin {
            results[task.id] = Shell.run("/bin/sh", ["-c", task.command]).status == 0 ? .done : .failed
        }

        let adminTasks = tasks.filter(\.needsAdmin)
        guard !adminTasks.isEmpty else { return results }
        let script = adminTasks
            .map { "(\($0.command)) >/dev/null 2>&1; echo \(marker):\($0.id):$?" }
            .joined(separator: "; ")
        switch Shell.runAsAdmin(script) {
        case .success(let output):
            results.merge(parse(output, tasks: adminTasks)) { $1 }
        case .failure(.cancelled):
            adminTasks.forEach { results[$0.id] = .cancelled }
        case .failure(.failed):
            adminTasks.forEach { results[$0.id] = .failed }
        }
        return results
    }

    /// Reads the exit status each task echoed. `do shell script` ends lines with \r.
    static func parse(_ output: String, tasks: [MaintenanceTask]) -> [String: MaintenanceResult] {
        let lines = output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        var results: [String: MaintenanceResult] = [:]
        for task in tasks {
            let line = lines.first { $0.hasPrefix("\(marker):\(task.id):") }
            results[task.id] = line == "\(marker):\(task.id):0" ? .done : .failed
        }
        return results
    }
}
