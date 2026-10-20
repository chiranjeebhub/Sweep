import AppKit
import SwiftUI
import SweepCore

struct PrivacyView: View {
    @ObservedObject var model: PrivacyModel
    @State private var resultMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Privacy").font(.system(size: 22, weight: .bold))
                    Text("Clear browsing traces and activity history. Saved passwords and bookmarks are never touched.")
                        .font(.system(size: 13)).foregroundStyle(Theme.mutedText)
                }
                if model.needsFullDiskAccess {
                    banner(icon: "exclamationmark.triangle",
                           text: "Safari data needs Full Disk Access for this app.",
                           action: "Open System Settings") { model.openFullDiskAccessSettings() }
                }
                if !model.runningSelectedApps.isEmpty {
                    banner(icon: "xmark.octagon",
                           text: "Quit \(model.runningSelectedApps.compactMap(\.localizedName).joined(separator: ", ")) before cleaning it.",
                           action: "Quit now") { model.quitRunningApps() }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 16)

            Rectangle().fill(Theme.divider).frame(height: 1)

            if model.isScanning && !model.hasScanned {
                StatusMessage(symbol: "", title: "Checking privacy traces…", showsProgress: true)
            } else {
                HStack(spacing: 0) {
                    sourceList
                    Rectangle().fill(Theme.divider).frame(width: 1)
                    itemList
                }
                FooterBar {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model.selectedCount) kinds of traces selected").font(.system(size: 15, weight: .semibold))
                        Text(resultMessage ?? "Cleaned items go to the Trash").font(.system(size: 12)).foregroundStyle(Theme.faintText)
                    }
                    Spacer()
                    Button("Remove") {
                        Task {
                            let result = await model.clean()
                            resultMessage = "Removed \(ByteFormat.string(result.freedBytes)) of traces."
                                + (model.skippedBrowsers.isEmpty ? "" : " Skipped \(model.skippedBrowsers.joined(separator: ", ")) because it was open.")
                        }
                    }
                    .buttonStyle(PillButtonStyle(fill: Theme.protection, foreground: Color(hex: 0x1A0E04)))
                    .disabled(model.selectedCount == 0)
                }
            }
        }
        .task { if !model.hasScanned { await model.scan() } }
    }

    private func banner(icon: String, text: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
            Text(text)
            Spacer()
            Button(action, action: perform).buttonStyle(LinkButtonStyle(color: Color(hex: 0xFFC48A)))
        }
        .font(.system(size: 13))
        .foregroundStyle(Color(hex: 0xFFD9B3))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x2A2116)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: 0x4A3820)))
    }

    private var sourceList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(model.sources) { source in
                    let isFocused = model.focusedSourceID == source.id
                    HStack(spacing: 10) {
                        CheckBox(isOn: Binding(get: { model.isSelected(source) }, set: { model.setSelected(source, $0) }),
                                 tint: Theme.protection, label: source.name)
                            .disabled(source.needsFullDiskAccess)
                        sourceIcon(source)
                        Text(source.name).font(.system(size: 13.5))
                        Spacer()
                        Text(source.needsFullDiskAccess ? "Locked" : ByteFormat.string(source.size))
                            .font(.system(size: 12.5))
                            .foregroundStyle(source.needsFullDiskAccess ? Theme.protection : Theme.mutedText)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .background(RoundedRectangle(cornerRadius: 8).fill(isFocused ? Color(hex: 0x3A2E20) : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { model.focusedSourceID = source.id }
                    .accessibilityAddTraits(.isButton)
                }
            }
            .padding(12)
        }
        .frame(width: 300)
    }

    @ViewBuilder private func sourceIcon(_ source: PrivacySource) -> some View {
        if let id = source.bundleIdentifier, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 26, height: 26)
        } else {
            IconTile(symbol: "clock.arrow.circlepath", tint: Theme.faintText, size: 26)
        }
    }

    @ViewBuilder private var itemList: some View {
        if let source = model.focused {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.name).font(.system(size: 16, weight: .semibold)).padding(.bottom, 8)
                    if source.needsFullDiskAccess {
                        Text("macOS protects \(source.name)'s data. Allow Full Disk Access for Sweep, then reopen this screen.")
                            .font(.system(size: 13)).foregroundStyle(Theme.mutedText)
                    } else if source.items.isEmpty {
                        Text("Nothing to clean.").font(.system(size: 13)).foregroundStyle(Theme.mutedText)
                    }
                    ForEach(source.items) { item in
                        HStack(spacing: 12) {
                            CheckBox(isOn: Binding(get: { model.isSelected(item) }, set: { model.setSelected(item, $0) }),
                                     tint: Theme.protection, label: item.title)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.system(size: 13.5, weight: .medium))
                                Text(item.detail).font(.system(size: 12)).foregroundStyle(Theme.faintText)
                            }
                            Spacer()
                            Text(ByteFormat.string(item.size)).font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .frame(maxWidth: .infinity)
        } else {
            StatusMessage(symbol: "checkmark.shield", title: "No privacy traces found")
        }
    }
}
