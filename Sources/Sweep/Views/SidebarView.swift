import SwiftUI
import SweepCore

struct SidebarView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var storage: StorageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window's traffic-light buttons, measured from the window's top edge.
            Spacer().frame(height: 40)

            HStack(spacing: 8) {
                // The app icon from Resources/AppIcon.icns; its artwork has a transparent margin, hence the larger frame.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .padding(-2)
                    .accessibilityHidden(true)
                Text("Sweep").font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Module.sections.indices, id: \.self) { index in
                        let section = Module.sections[index]
                        VStack(alignment: .leading, spacing: 1) {
                            if let title = section.title {
                                Text(title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.faintText)
                                    .padding(.horizontal, 8)
                                    .padding(.bottom, 4)
                            }
                            ForEach(section.modules) { module in
                                row(module)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 8)
            footer
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // Panel and divider both run up under the title bar to the window's top edge.
        .background {
            HStack(spacing: 0) {
                Theme.sidebar
                Theme.divider.frame(width: 1)
            }
            .ignoresSafeArea()
        }
    }

    private func row(_ module: Module) -> some View {
        let isActive = app.selection == module
        return Button {
            app.selection = module
        } label: {
            HStack(spacing: 9) {
                Image(systemName: module.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? Theme.accent : Theme.faintText)
                    .frame(width: 18)
                Text(module.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? Theme.text : Theme.secondaryText)
                Spacer()
                if let count = count(for: module), count > 0 {
                    Text("\(count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.faintText)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(isActive ? Theme.rowSelected : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func count(for module: Module) -> Int? {
        switch module {
        case .cleanup: return storage.actionableCount
        default: return nil
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, -8)
            Group {
                if storage.isScanning {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Scanning…").font(.system(size: 12, weight: .medium))
                        ProgressView().progressViewStyle(.linear).tint(Theme.accent).controlSize(.small)
                    }
                } else if let result = storage.result {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Scanned \(RelativeDate.string(result.date).lowercased())").font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                        Text(result.rootURL.abbreviatedPath).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.faintText)
                    }
                } else {
                    Text("Not scanned yet").font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                }
            }
            .padding(.horizontal, 8)
            SettingsButton {
                HStack(spacing: 9) {
                    Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(Theme.faintText).frame(width: 18)
                    Text("Settings").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }
}

/// A button that opens Sweep > Settings…, using SettingsLink where macOS has it.
struct SettingsButton<Content: View>: View {
    @ViewBuilder var label: Content

    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink { label }.buttonStyle(.plain)
        } else {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            } label: { label }
            .buttonStyle(.plain)
        }
    }
}
