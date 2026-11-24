import SwiftUI

/// The screens listed in the sidebar.
enum Module: String, CaseIterable, Identifiable {
    case overview, assistant, storage, developer, docker, duplicates, nodeModules, uninstaller
    case cleanup, trashBins, history
    case smartScan, privacy, malware, optimization, maintenance, updater

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .assistant: "Ask Sweep"
        case .storage: "Storage"
        case .developer: "Developer"
        case .docker: "Docker"
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
        case .assistant: "bubble.left.and.text.bubble.right"
        case .storage: "folder"
        case .developer: "hammer"
        case .docker: "shippingbox.circle"
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

    /// The sidebar entry this screen lives under.
    var group: NavGroup { NavGroup.all.first { $0.modules.contains(self) } ?? NavGroup.all[0] }

    /// Name on the tab strip when a sidebar entry holds several screens.
    var tabTitle: String {
        switch self {
        case .storage: "Explorer"
        case .developer: "Tools"
        case .updater: "Updates"
        case .uninstaller: "Uninstaller"
        default: title
        }
    }
}

/// One sidebar entry. Entries holding several related screens show them as tabs.
struct NavGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let modules: [Module]

    /// Colour of the entry's icon tile, from the approved palette.
    var tint: Color {
        switch id {
        case "overview": Color(hex: 0x8C9BFF)
        case "cleanup": Theme.accent
        case "storage": Color(hex: 0x4FC3E8)
        case "developer": Theme.lavender
        case "apps": Theme.protection
        case "health": Theme.speed
        default: Color(hex: 0xFF7EB6)
        }
    }

    static let all: [NavGroup] = [
        NavGroup(id: "overview", title: "Overview", symbol: Module.overview.symbol, modules: [.overview]),
        NavGroup(id: "cleanup", title: "Cleanup", symbol: Module.cleanup.symbol, modules: [.cleanup, .trashBins, .history]),
        NavGroup(id: "storage", title: "Storage", symbol: Module.storage.symbol, modules: [.storage, .duplicates]),
        NavGroup(id: "developer", title: "Developer", symbol: Module.developer.symbol, modules: [.developer, .nodeModules, .docker]),
        NavGroup(id: "apps", title: "Applications", symbol: Module.uninstaller.symbol, modules: [.uninstaller, .updater]),
        NavGroup(id: "health", title: "Mac Health", symbol: "heart.text.square", modules: [.smartScan, .privacy, .malware, .optimization, .maintenance]),
        NavGroup(id: "assistant", title: "Ask Sweep", symbol: Module.assistant.symbol, modules: [.assistant]),
    ]

    static func group(_ id: String) -> NavGroup { all.first { $0.id == id }! }

    /// The main sidebar list: one flat list with no section headings. Ask Sweep sits in the footer.
    static let main: [NavGroup] = all.filter { $0.id != "assistant" }
}
