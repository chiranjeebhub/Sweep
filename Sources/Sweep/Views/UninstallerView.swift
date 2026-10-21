import AppKit
import SwiftUI
import SweepCore

struct UninstallerView: View {
    @ObservedObject var model: UninstallerModel
    @State private var confirmingUninstall = false

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Uninstaller", subtitle: "Remove apps completely, including the files they leave behind.") {
                filterPicker
            }
            Rectangle().fill(Theme.divider).frame(height: 1)

            if model.isScanning && !model.hasScanned {
                StatusMessage(symbol: "", title: "Finding your apps…", showsProgress: true)
            } else if model.filter == .leftovers {
                leftovers
            } else {
                HStack(spacing: 0) {
                    appList
                    Rectangle().fill(Theme.divider).frame(width: 1)
                    detail
                }
            }
        }
        .task { if !model.hasScanned { await model.scan() } }
        .alert("Uninstall \(model.focusedApp?.name ?? "app")?", isPresented: $confirmingUninstall) {
            Button("Uninstall", role: .destructive) { Task { await model.uninstallFocused() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.movesToTrash
                 ? "The app and the selected files move to the Trash."
                 : "The app and the selected files are deleted permanently. You can change this in Sweep > Settings.")
        }
    }

    private var filterPicker: some View {
        HStack(spacing: 0) {
            segment(.all, count: model.apps.count)
            segment(.unused, count: model.unusedCount)
            segment(.leftovers, count: model.leftovers.count)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
    }

    private func segment(_ filter: UninstallerModel.Filter, count: Int) -> some View {
        let isOn = model.filter == filter
        return Button {
            model.filter = filter
            if filter != .leftovers, !model.visibleApps.contains(where: { $0.url == model.focusedAppURL }) {
                model.focusedAppURL = model.visibleApps.first?.url
            }
        } label: {
            Text("\(filter.rawValue) · \(count)")
                .font(.system(size: 12.5, weight: isOn ? .semibold : .medium))
                .foregroundStyle(isOn ? Color.white : Theme.secondaryText)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(isOn ? Theme.selection : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var appList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.visibleApps) { app in
                    let isFocused = model.focusedAppURL == app.url
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                            .resizable().frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                            Text(app.lastUsed == nil ? "Never opened" : RelativeDate.string(app.lastUsed))
                                .font(.system(size: 11.5)).foregroundStyle(Theme.faintText)
                        }
                        Spacer()
                        Text(ByteFormat.string(app.size)).font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 8).fill(isFocused ? Theme.selection : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { model.focusedAppURL = app.url }
                    .accessibilityAddTraits(.isButton)
                }
            }
            .padding(12)
        }
        .frame(width: 380)
    }

    @ViewBuilder private var detail: some View {
        if let app = model.focusedApp {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name).font(.system(size: 20, weight: .bold))
                        Text([app.version.map { "Version \($0)" }, app.lastUsed.map { "Last opened " + RelativeDate.string($0) }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 13)).foregroundStyle(Theme.mutedText)
                    }
                }

                VStack(spacing: 0) {
                    partRow(title: "Application", detail: "1 item", size: app.size, isOn: .constant(true), locked: true)
                    if let remnants = model.remnants {
                        ForEach(remnants.groups) { group in
                            partRow(title: group.title,
                                    detail: group.urls.count == 1 ? "1 item" : "\(group.urls.count) items",
                                    size: group.size,
                                    isOn: Binding(get: { !model.excludedGroups.contains(group.title) },
                                                  set: { on in
                                                      if on { model.excludedGroups.remove(group.title) }
                                                      else { model.excludedGroups.insert(group.title) }
                                                  }),
                                    locked: false)
                        }
                    } else {
                        ProgressView().controlSize(.small).padding(12)
                    }
                }
                .padding(.vertical, 6)
                .card()

                if let message = model.message {
                    Text(message).font(.system(size: 13)).foregroundStyle(Theme.protection)
                    if model.needsFullDiskAccess {
                        Button("Open Full Disk Access settings") { model.openFullDiskAccessSettings() }
                            .buttonStyle(OutlineButtonStyle())
                    }
                }

                Spacer(minLength: 0)

                HStack {
                    Text("\(ByteFormat.string(model.removalSize)) will be removed").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Reset app") { Task { await model.resetFocused() } }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(model.selectedRemnantURLs.isEmpty)
                        .help("Removes the app's settings and support files but keeps the app")
                    Button("Uninstall") { confirmingUninstall = true }
                        .buttonStyle(PillButtonStyle(fill: Theme.danger, foreground: Color(hex: 0x1A0E08)))
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            StatusMessage(symbol: "square.grid.2x2", title: "Select an app")
        }
    }

    private func partRow(title: String, detail: String, size: Int64, isOn: Binding<Bool>, locked: Bool) -> some View {
        HStack(spacing: 12) {
            CheckBox(isOn: isOn, label: title).disabled(locked)
            Text(title).font(.system(size: 13.5))
            Spacer()
            Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.faintText)
            Text(ByteFormat.string(size)).font(.system(size: 13.5)).foregroundStyle(Theme.secondaryText)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    @ViewBuilder private var leftovers: some View {
        if model.leftovers.isEmpty {
            StatusMessage(symbol: "checkmark.circle", title: "No leftovers found",
                          detail: "Support folders from apps you've already deleted show up here.")
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.leftovers) { leftover in
                        HStack(spacing: 12) {
                            CheckBox(isOn: Binding(
                                get: { model.selectedLeftovers.contains(leftover.url) },
                                set: { if $0 { model.selectedLeftovers.insert(leftover.url) } else { model.selectedLeftovers.remove(leftover.url) } }),
                                     label: leftover.bundleIdentifier)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(leftover.bundleIdentifier).font(.system(size: 13.5, weight: .medium))
                                Text(leftover.url.deletingLastPathComponent().abbreviatedPath)
                                    .font(.system(size: 11.5)).foregroundStyle(Theme.faintText)
                            }
                            Spacer()
                            Text(ByteFormat.string(leftover.size)).font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 48)
                        .contextMenu {
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([leftover.url]) }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            if let message = model.message {
                HStack {
                    Text(message).font(.system(size: 13)).foregroundStyle(Theme.protection)
                    Spacer()
                    if model.needsFullDiskAccess {
                        Button("Open Full Disk Access settings") { model.openFullDiskAccessSettings() }
                            .buttonStyle(OutlineButtonStyle())
                    }
                }
                .padding(.horizontal, 20)
            }
            FooterBar {
                Text(model.selectedLeftovers.isEmpty
                     ? "Check each folder before removing it"
                     : "\(model.selectedLeftovers.count) folders · \(ByteFormat.string(model.selectedLeftoverSize))")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Remove") { Task { await model.removeSelectedLeftovers() } }
                    .buttonStyle(PillButtonStyle(fill: Theme.danger, foreground: Color(hex: 0x1A0E08)))
                    .disabled(model.selectedLeftovers.isEmpty)
            }
        }
    }
}
