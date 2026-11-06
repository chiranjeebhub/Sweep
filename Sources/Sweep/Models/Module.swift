import SwiftUI

/// The screens listed in the sidebar.
enum Module: String, CaseIterable, Identifiable {
    case overview, storage, duplicates, nodeModules, uninstaller
    case cleanup, trashBins, history
    case smartScan, privacy, malware, optimization, maintenance, updater

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .storage: "Storage"
        case .duplicates: "Duplicates"
        case .nodeModules: "Node Modules"
        case .uninstaller: "Applications"
        case .cleanup: "Cleanup"
        case .trashBins: "Trash"
        case .history: "History"
        case .smartScan: "Smart Scan"
        case .privacy: "Privacy"
        case .malware: "Malware"
        case .optimization: "Optimization"
        case .maintenance: "Maintenance"
        case .updater: "Updater"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .storage: "folder"
        case .duplicates: "doc.on.doc"
        case .nodeModules: "shippingbox"
        case .uninstaller: "square.grid.2x2"
        case .cleanup: "sparkles"
        case .trashBins: "trash"
        case .history: "clock.arrow.circlepath"
        case .smartScan: "scope"
        case .privacy: "hand.raised"
        case .malware: "shield"
        case .optimization: "bolt"
        case .maintenance: "wrench.and.screwdriver"
        case .updater: "arrow.triangle.2.circlepath"
        }
    }

    /// Sidebar sections, in order. The first section has no heading.
    static let sections: [(title: String?, modules: [Module])] = [
        (nil, [.overview]),
        ("Analyze", [.storage, .duplicates, .nodeModules, .uninstaller]),
        ("Clean up", [.cleanup, .trashBins, .history]),
        ("Protect & speed up", [.smartScan, .privacy, .malware, .optimization, .maintenance, .updater]),
    ]
}
