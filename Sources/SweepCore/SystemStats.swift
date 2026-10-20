import Darwin
import Foundation

/// A snapshot of memory, CPU and startup-disk usage.
public struct SystemSnapshot: Sendable {
    public var memoryUsed: Int64
    public var memoryTotal: Int64
    /// 0...1, averaged across all cores since the previous sample.
    public var cpuLoad: Double
    public var cpuCores: Int
    public var diskFree: Int64
    public var diskTotal: Int64

    public var memoryFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }
    public var diskUsedFraction: Double { diskTotal > 0 ? Double(diskTotal - diskFree) / Double(diskTotal) : 0 }
}

/// Reads live system figures from the kernel. Keep one instance around: CPU load is measured
/// as the difference between two consecutive samples.
public final class SystemStats {
    private var previousTicks: (used: UInt64, total: UInt64)?

    public init() {}

    public func sample() -> SystemSnapshot {
        let disk = Self.disk()
        return SystemSnapshot(
            memoryUsed: Self.memoryUsed(),
            memoryTotal: Int64(ProcessInfo.processInfo.physicalMemory),
            cpuLoad: cpuLoad(),
            cpuCores: ProcessInfo.processInfo.activeProcessorCount,
            diskFree: disk.free,
            diskTotal: disk.total)
    }

    /// Active, wired and compressed memory, which is roughly what Activity Monitor calls "Memory Used".
    static func memoryUsed() -> Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = Int64(vm_kernel_page_size)
        let pages = Int64(stats.active_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        return pages * pageSize
    }

    private func cpuLoad() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let used = user + system + nice
        let total = used + idle
        defer { previousTicks = (used, total) }
        guard let previous = previousTicks, total > previous.total else {
            return total > 0 ? Double(used) / Double(total) : 0
        }
        return Double(used - previous.used) / Double(total - previous.total)
    }

    static func disk() -> (free: Int64, total: Int64) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return (0, 0) }
        return (values.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values.volumeTotalCapacity ?? 0))
    }

    /// Physical memory footprint of a process, as shown in Activity Monitor's Memory column.
    public static func memoryFootprint(of pid: pid_t) -> Int64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? Int64(info.ri_phys_footprint) : 0
    }
}

/// Runs shell commands that need an administrator password, using the standard macOS prompt.
public enum PrivilegedRunner {
    public enum Failure: Error {
        case cancelled
        case failed(String)
    }

    /// Runs `command` as root after macOS asks the user for their password.
    public static func run(_ command: String) -> Result<Void, Failure> {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failure(.failed("Could not build script")) }
        _ = script.executeAndReturnError(&error)
        guard let error else { return .success(()) }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .failure(.cancelled) }
        return .failure(.failed(error[NSAppleScript.errorMessage] as? String ?? "Unknown error"))
    }

    public static let freeMemoryCommand = "/usr/sbin/purge"
    public static let flushDNSCommand = "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"
}

/// Background helpers that start at login, read from the LaunchAgents folders.
public enum BackgroundItems {
    public static func launchAgents() -> [URL] {
        let folders = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchAgents"),
        ]
        return folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "plist" }
        }
    }
}
