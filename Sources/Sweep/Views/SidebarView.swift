import SwiftUI
import SweepCore

struct SidebarView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var storage: StorageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window's traffic-light buttons, measured from the window's top edge.
            Spacer().frame(height: 44)

            HStack(spacing: 9) {
                // The app icon from Resources/AppIcon.icns; its artwork has a transparent margin, hence the larger frame.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .padding(-2)
                    .accessibilityHidden(true)
                Text("Sweep").font(.system(size: 17, weight: .bold)).tracking(-0.3)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(NavGroup.main) { group in
                    row(group)
                }
            }
            .padding(.horizontal, 8)

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

    private func row(_ group: NavGroup) -> some View {
        let isActive = group.modules.contains(app.selection)
        return Button {
            if !isActive { app.open(group) }
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(group.tint.opacity(isActive ? 0.24 : 0.14))
                    .frame(width: 24, height: 24)
                    .overlay(
                        Image(systemName: group.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(group.tint)
                    )
                Text(group.title)
                    .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? Theme.text : Theme.secondaryText)
                Spacer()
                if let count = count(for: group), count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isActive ? Theme.text : Theme.mutedText)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Capsule().fill(Theme.track))
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isActive ? Theme.rowSelected : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func count(for group: NavGroup) -> Int? {
        group.id == "cleanup" ? storage.actionableCount : nil
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if storage.isScanning {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Scanning…").font(.system(size: 11)).foregroundStyle(Theme.mutedText)
                        ProgressView().progressViewStyle(.linear).tint(Theme.accent).controlSize(.small)
                    }
                } else if let result = storage.result {
                    Text("Scanned \(RelativeDate.string(result.date).lowercased())")
                        .font(.system(size: 11)).foregroundStyle(Theme.faintText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            row(NavGroup.group("assistant"))
            SettingsButton {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 24, height: 24)
                        .overlay(Image(systemName: "gearshape").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mutedText))
                    Text("Settings").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText)
                    Spacer()
                }
                .padding(.horizontal, 7)
                .frame(height: 34)
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
