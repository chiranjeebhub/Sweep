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
            // The sidebar always runs under the title bar on its own, so its top doesn't
            // shift with whether the selected screen happens to fill the safe area.
            SidebarView(optimization: app.optimization)
                .frame(width: 240)
                .frame(maxHeight: .infinity)
                .ignoresSafeArea()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.window)
        .foregroundStyle(Theme.text)
        .ignoresSafeArea()
        .background(WindowChrome())
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
        case .malware: MalwareView(model: app.malware)
        case .maintenance: MaintenanceView(model: app.maintenance)
        case .updater: UpdaterView(model: app.updater)
        }
    }
}

/// Lets the content run up under the title bar, so the sidebar fills the window's full height
/// with the traffic-light buttons sitting on top of it.
private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
        }
    }
}
