import SwiftUI

/// The screens listed in the sidebar.
enum Module: String, CaseIterable, Identifiable {
    case smartScan, systemJunk, largeFiles, trashBins, privacy, malware, optimization, maintenance, uninstaller, updater

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartScan: "Smart Scan"
        case .systemJunk: "System Junk"
        case .largeFiles: "Large & Old Files"
        case .trashBins: "Trash Bins"
        case .privacy: "Privacy"
        case .malware: "Malware Removal"
        case .optimization: "Optimization"
        case .maintenance: "Maintenance"
        case .uninstaller: "Uninstaller"
        case .updater: "Updater"
        }
    }

    var symbol: String {
        switch self {
        case .smartScan: "scope"
        case .systemJunk: "trash"
        case .largeFiles: "folder"
        case .trashBins: "trash.square"
        case .privacy: "shield"
        case .malware: "ladybug"
        case .optimization: "bolt"
        case .maintenance: "wrench.and.screwdriver"
        case .uninstaller: "square.grid.2x2"
        case .updater: "arrow.clockwise"
        }
    }

    /// Sidebar sections, in order. The first section has no heading.
    static let sections: [(title: String?, modules: [Module])] = [
        (nil, [.smartScan]),
        ("Cleanup", [.systemJunk, .largeFiles, .trashBins]),
        ("Protection", [.privacy, .malware]),
        ("Speed", [.optimization, .maintenance]),
        ("Applications", [.uninstaller, .updater]),
    ]
}
