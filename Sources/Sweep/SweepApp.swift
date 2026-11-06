import AppKit
import SwiftUI
import SweepCore

@main
struct SweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @AppStorage(MenuBarSettings.key) private var showsInMenuBar = true

    var body: some Scene {
        WindowGroup(id: "main") {
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

        Settings {
            SettingsView().preferredColorScheme(.dark)
        }

        MenuBarExtra(isInserted: $showsInMenuBar) {
            MenuBarView(storage: model.storage).environmentObject(model)
        } label: {
            Image(systemName: "internaldrive")
        }
        .menuBarExtraStyle(.window)
    }
}

enum MenuBarSettings {
    static let key = "menuBar.enabled"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// Sweep > Settings… (⌘,).
struct SettingsView: View {
    @AppStorage(UninstallerModel.moveToTrashKey) private var moveToTrash = true
    @AppStorage(StorageModel.scanRootKey) private var scanRoot = ""
    @AppStorage(MenuBarSettings.key) private var showsInMenuBar = true
    @State private var hasKey = APIKeyStore.load() != nil

    var body: some View {
        Form {
            Section("Scanning") {
                LabeledContent("Folder to scan") {
                    HStack {
                        Text(scanRoot.isEmpty ? "Home folder" : URL(fileURLWithPath: scanRoot).abbreviatedPath)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                        if !scanRoot.isEmpty { Button("Use Home") { scanRoot = "" } }
                    }
                }
                Text("Overview, Cleanup and Storage measure this folder. Sweep only ever cleans up inside your home folder.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Toggle("Show Sweep in the menu bar", isOn: $showsInMenuBar)
                Text("Free space, the Trash and shortcuts from the menu bar. Closing the window keeps Sweep running there.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Section("Ask Sweep") {
                LabeledContent("Claude API key") {
                    HStack {
                        Text(hasKey ? "Saved in your keychain" : "Not set").foregroundStyle(.secondary)
                        if hasKey { Button("Remove") { APIKeyStore.delete(); hasKey = false } }
                    }
                }
                Text("Optional. Used only when you ask a question on the Ask Sweep screen.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Section("Removing") {
                Toggle("Move removed items to the Trash", isOn: $moveToTrash)
                Text(moveToTrash
                     ? "Uninstalled apps, their files and node_modules folders go to the Trash, so you can put them back until you empty it."
                     : "Uninstalled apps, their files and node_modules folders are deleted right away. This can't be undone.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { scanRoot = url.path }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run`, where there is no app bundle to say this is a regular app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !MenuBarSettings.isEnabled }
}

/// Sidebar plus the selected screen.
struct RootView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 0) {
            // The sidebar always runs under the title bar on its own, so its top doesn't
            // shift with whether the selected screen happens to fill the safe area.
            SidebarView(storage: app.storage)
                .frame(width: 220)
                .frame(maxHeight: .infinity)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                if app.selection.group.modules.count > 1 { TabStrip(group: app.selection.group) }
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
        case .overview: OverviewView(storage: app.storage)
        case .cleanup: CleanupView(model: app.cleanup)
        case .history: HistoryView(model: app.history)
        case .smartScan: SmartScanView(model: app.smartScan)
        case .storage: StorageView(model: app.explorer)
        case .developer: DeveloperView(model: app.developer, storage: app.storage)
        case .docker: DockerView(model: app.docker)
        case .assistant: AssistantView(model: app.assistant)
        case .duplicates: DuplicatesView(model: app.duplicates)
        case .nodeModules: NodeModulesView(model: app.nodeModules)
        case .trashBins: TrashView(model: app.trash)
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

/// Tabs for the screens that share one sidebar entry.
struct TabStrip: View {
    @EnvironmentObject private var app: AppModel
    let group: NavGroup

    var body: some View {
        HStack(spacing: 4) {
            ForEach(group.modules) { module in
                let isActive = app.selection == module
                Button { app.selection = module } label: {
                    Text(module.tabTitle)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? Theme.text : Theme.mutedText)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(isActive ? Theme.rowSelected : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}
