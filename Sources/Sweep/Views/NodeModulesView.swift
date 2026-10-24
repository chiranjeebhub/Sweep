import AppKit
import SwiftUI
import SweepCore

struct NodeModulesView: View {
    @ObservedObject var model: NodeModulesModel
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isScanning && !model.hasScanned {
                StatusMessage(symbol: "", title: "Looking for node_modules folders…", showsProgress: true)
            } else if model.folders.isEmpty {
                StatusMessage(symbol: "checkmark.circle", title: "No node_modules folders found",
                              detail: model.message ?? "Nothing in your home folder outside Library and hidden folders.")
                    .overlay(alignment: .bottom) {
                        Button { Task { await model.scan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                            .buttonStyle(OutlineButtonStyle())
                            .padding(.bottom, 140)
                    }
            } else {
                columns
                if model.visibleFolders.isEmpty {
                    StatusMessage(symbol: "line.3.horizontal.decrease.circle", title: "Nothing matches",
                                  detail: "No projects have gone untouched that long.")
                } else {
                    list
                }
                footer
            }
        }
        .task { if !model.hasScanned && !model.isScanning { await model.scan() } }
        .alert(model.movesToTrash
               ? "Move \(model.selected.count) node_modules folders to the Trash?"
               : "Delete \(model.selected.count) node_modules folders?", isPresented: $confirming) {
            Button(model.movesToTrash ? "Move to Trash" : "Delete", role: .destructive) {
                Task { await model.removeSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let size = ByteFormat.string(model.selectedSize)
            Text(removalList + "\n\nOnly these node_modules folders are removed. Your project files stay. "
                 + (model.movesToTrash
                  ? "This frees \(size) once you empty the Trash."
                  : "This frees \(size) right away and can't be undone. You can change this in Sweep > Settings.")
                 + " Run npm install in a project to bring its node_modules back.")
        }
    }

    /// The folders about to go, as paths ending in node_modules, so it's clear the project itself stays.
    private var removalList: String {
        let paths = model.selectedFolders.map(\.url.abbreviatedPath)
        let shown = paths.prefix(5).joined(separator: "\n")
        return paths.count > 5 ? shown + "\nand \(paths.count - 5) more" : shown
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Node Modules").font(.system(size: 22, weight: .bold))
                    Text(model.hasScanned
                         ? "\(model.folders.count) projects, \(ByteFormat.string(model.totalSize)) of node_modules in total"
                         : "Finding node_modules folders in your home folder")
                        .font(.system(size: 13)).foregroundStyle(Theme.mutedText)
                    Label("Only the node_modules folder is removed. Your project files stay.", systemImage: "info.circle")
                        .font(.system(size: 12)).foregroundStyle(Theme.faintText)
                }
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.faintText)
                    TextField("Search projects", text: $model.search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 12)
                .frame(width: 220, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            }

            HStack(spacing: 8) {
                ForEach(NodeModulesModel.Age.allCases) { age in
                    let isOn = model.age == age
                    Button("\(age.title) · \(model.count(olderThan: age))") { model.age = age }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .foregroundStyle(isOn ? Color.white : Theme.secondaryText)
                        .background(Capsule().fill(isOn ? Theme.selection : Color.clear))
                        .overlay(Capsule().strokeBorder(isOn ? Color(hex: 0x4A5A8A) : Theme.track))
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                }
                Spacer()
                Picker("Sort", selection: $model.sort) {
                    ForEach(NodeModulesSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }

    private var columns: some View {
        HStack(spacing: 0) {
            CheckBox(isOn: Binding(get: { model.allVisibleSelected }, set: { model.setAllVisibleSelected($0) }),
                     label: "Select all")
                .frame(width: 32, alignment: .leading)
            ColumnLabel("Project · node_modules folder")
            Spacer()
            ColumnLabel("Last touched").frame(width: 150, alignment: .leading)
            ColumnLabel("Size").frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.visibleFolders) { folder in
                    let isOn = model.selected.contains(folder.url)
                    HStack(spacing: 0) {
                        CheckBox(isOn: Binding(
                            get: { model.selected.contains(folder.url) },
                            set: { if $0 { model.selected.insert(folder.url) } else { model.selected.remove(folder.url) } }),
                                 label: folder.projectName)
                            .frame(width: 32, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.projectName).lineLimit(1)
                            // The full path of the folder that gets removed, with node_modules picked out.
                            (Text(folder.projectPath + "/").foregroundColor(Theme.faintText)
                             + Text("node_modules").foregroundColor(Theme.accentText))
                                .font(.system(size: 11.5))
                                .lineLimit(1).truncationMode(.head)
                        }
                        Spacer(minLength: 12)
                        Text(RelativeDate.string(folder.lastTouched))
                            .font(.system(size: 12.5))
                            .foregroundStyle(ageColor(folder))
                            .frame(width: 150, alignment: .leading)
                        Text(ByteFormat.string(folder.size)).frame(width: 90, alignment: .trailing)
                    }
                    .font(.system(size: 13.5))
                    .padding(.horizontal, 12)
                    .frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? Theme.selectionSubtle : Color.clear))
                    .contextMenu {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
                        Button("Open Project in Finder") { NSWorkspace.shared.open(folder.project) }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    /// Projects left alone for six months stand out, as the likeliest to clear.
    private func ageColor(_ folder: NodeModulesFolder) -> Color {
        folder.daysSinceTouched() >= NodeModulesModel.Age.halfYear.rawValue ? Theme.protection : Theme.mutedText
    }

    private var footer: some View {
        FooterBar {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selected.isEmpty
                     ? "Select folders to remove"
                     : "\(model.selected.count) folders selected · \(ByteFormat.string(model.selectedSize))")
                    .font(.system(size: 15, weight: .semibold))
                if let message = model.message {
                    Text(message).font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                }
            }
            Spacer()
            Button {
                Task { await model.scan() }
            } label: {
                HStack(spacing: 6) {
                    if model.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Rescan")
                }
            }
            .buttonStyle(OutlineButtonStyle())
            .disabled(model.isScanning || model.isRemoving)
            Button("Reveal in Finder") { model.revealSelected() }
                .buttonStyle(OutlineButtonStyle())
                .disabled(model.selected.isEmpty)
            Button("Remove node_modules") { confirming = true }
                .buttonStyle(PillButtonStyle())
                .disabled(model.selected.isEmpty || model.isRemoving)
        }
    }
}
