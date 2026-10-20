import AppKit
import SwiftUI

@main
struct SweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run`, where there is no app bundle to say this is a regular app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Sidebar plus the selected screen.
struct RootView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(optimization: app.optimization)
                .frame(width: 240)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.window)
        .foregroundStyle(Theme.text)
        .ignoresSafeArea()
        .onAppear { app.optimization.start() }
    }

    @ViewBuilder private var content: some View {
        switch app.selection {
        case .smartScan: SmartScanView(model: app.smartScan)
        case .systemJunk: SystemJunkView(model: app.junk)
        case .largeFiles: LargeFilesView(model: app.largeFiles)
        case .trashBins: TrashBinsView(model: app.trash)
        case .privacy: PrivacyView(model: app.privacy)
        case .optimization: OptimizationView(model: app.optimization)
        case .uninstaller: UninstallerView(model: app.uninstaller)
        case .malware:
            ComingSoonView(module: .malware, detail: "Malware scanning needs an up-to-date signature database. It's planned for a later version.")
        case .maintenance:
            ComingSoonView(module: .maintenance, detail: "Maintenance scripts such as reindexing Spotlight and repairing disk permissions are planned for a later version.")
        case .updater:
            ComingSoonView(module: .updater, detail: "Checking your apps for updates is planned for a later version.")
        }
    }
}

struct ComingSoonView: View {
    let module: Module
    let detail: String

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: module.title, subtitle: "Coming soon")
            Rectangle().fill(Theme.divider).frame(height: 1)
            StatusMessage(symbol: module.symbol, title: "\(module.title) isn't available yet", detail: detail)
        }
    }
}
