import AppKit
import SwiftUI

/// Sweep's menu bar item: an AppKit status item with a popover holding MenuBarView.
@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private var item: NSStatusItem?
    private let popover = NSPopover()

    /// Adds or removes the item to match the setting.
    func update() {
        if MenuBarSettings.isEnabled {
            guard item == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "Sweep")
            item.button?.target = self
            item.button?.action = #selector(toggle)
            self.item = item
        } else if let item {
            close()
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    @objc private func toggle() {
        if popover.isShown { close(); return }
        guard let button = item?.button else { return }
        let app = AppModel.shared
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView: MenuBarView(storage: app.storage).environmentObject(app))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func close() {
        if popover.isShown { popover.performClose(nil) }
        popover.contentViewController = nil
    }
}
