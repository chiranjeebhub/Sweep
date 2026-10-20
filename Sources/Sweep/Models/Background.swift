import Foundation

/// Runs slow file-system work off the main thread.
func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .userInitiated) { work() }.value
}

/// Remembers when each area was last cleaned, for the Smart Scan home screen.
enum LastRun {
    enum Area: String { case cleanup, protection, speed }

    static func date(_ area: Area) -> Date? {
        UserDefaults.standard.object(forKey: "lastRun.\(area.rawValue)") as? Date
    }

    static func mark(_ area: Area) {
        UserDefaults.standard.set(Date(), forKey: "lastRun.\(area.rawValue)")
    }

    static func summary(_ area: Area) -> String {
        guard let date = date(area) else { return "Never run" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last run " + formatter.localizedString(for: date, relativeTo: Date())
    }
}
