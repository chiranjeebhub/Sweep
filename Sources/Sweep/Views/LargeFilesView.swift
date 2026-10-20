import AppKit
import SwiftUI
import SweepCore

struct LargeFilesView: View {
    @ObservedObject var model: LargeFilesModel
    @State private var confirming = false

    private let kindColors: [LargeFile.Kind: Color] = [
        .video: Theme.accent, .archive: Theme.protection, .diskImage: Theme.speed, .other: Theme.lavender,
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isScanning && !model.hasScanned {
                StatusMessage(symbol: "", title: "Looking for large files…", showsProgress: true)
            } else if model.files.isEmpty {
                StatusMessage(symbol: "checkmark.circle", title: "No large files found",
                              detail: "Nothing over 100 MB in Desktop, Documents, Downloads, Movies, Music or Pictures.")
            } else {
                columns
                list
                footer
            }
        }
        .task { if !model.hasScanned { await model.scan() } }
        .alert("Move \(model.selected.count) files to the Trash?", isPresented: $confirming) {
            Button("Remove", role: .destructive) { Task { await model.removeSelected() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This frees \(ByteFormat.string(model.selectedSize)) once you empty the Trash.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Large & Old Files").font(.system(size: 22, weight: .bold))
                    Text(model.hasScanned
                         ? "\(model.files.count) files over 100 MB, \(ByteFormat.string(model.totalSize)) in total"
                         : "Finding files over 100 MB")
                        .font(.system(size: 13)).foregroundStyle(Theme.mutedText)
                }
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.faintText)
                    TextField("Search files", text: $model.search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 12)
                .frame(width: 220, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            }

            if model.totalSize > 0 {
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        ForEach(LargeFile.Kind.allCases, id: \.self) { kind in
                            let size = model.size(of: kind)
                            if size > 0 {
                                Rectangle()
                                    .fill(kindColors[kind] ?? Theme.accent)
                                    .frame(width: max(2, proxy.size.width * Double(size) / Double(model.totalSize) - 2))
                            }
                        }
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())
                .accessibilityHidden(true)

                HStack(spacing: 20) {
                    ForEach(LargeFile.Kind.allCases, id: \.self) { kind in
                        HStack(spacing: 6) {
                            Circle().fill(kindColors[kind] ?? Theme.accent).frame(width: 8, height: 8)
                            Text("\(kind.rawValue) \(ByteFormat.string(model.size(of: kind)))")
                        }
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.mutedText)
            }

            HStack(spacing: 8) {
                ForEach(LargeFilesModel.Filter.allCases) { filter in
                    let isOn = model.filter == filter
                    Button(filter.rawValue) { model.filter = filter }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .foregroundStyle(isOn ? Color.white : Theme.secondaryText)
                        .background(Capsule().fill(isOn ? Theme.selection : Color.clear))
                        .overlay(Capsule().strokeBorder(isOn ? Color(hex: 0x4A5A8A) : Theme.track))
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }

    private var columns: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 32)
            ColumnLabel("Name")
            Spacer()
            ColumnLabel("Kind").frame(width: 110, alignment: .leading)
            ColumnLabel("Location").frame(width: 170, alignment: .leading)
            ColumnLabel("Last opened").frame(width: 120, alignment: .leading)
            ColumnLabel("Size").frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.visibleFiles) { file in
                    let isOn = model.selected.contains(file.url)
                    HStack(spacing: 0) {
                        CheckBox(isOn: Binding(
                            get: { model.selected.contains(file.url) },
                            set: { if $0 { model.selected.insert(file.url) } else { model.selected.remove(file.url) } }),
                                 label: file.name)
                            .frame(width: 32, alignment: .leading)
                        Text(file.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 12)
                        Group {
                            Text(file.kind.rawValue).frame(width: 110, alignment: .leading)
                            Text(file.location).lineLimit(1).truncationMode(.head).frame(width: 170, alignment: .leading)
                            Text(RelativeDate.string(file.lastOpened)).frame(width: 120, alignment: .leading)
                        }
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.mutedText)
                        Text(ByteFormat.string(file.size)).frame(width: 80, alignment: .trailing)
                    }
                    .font(.system(size: 13.5))
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? Theme.selectionSubtle : Color.clear))
                    .contextMenu {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var footer: some View {
        FooterBar {
            Text(model.selected.isEmpty
                 ? "Select files to remove"
                 : "\(model.selected.count) files selected · \(ByteFormat.string(model.selectedSize))")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button("Reveal in Finder") { model.revealSelected() }
                .buttonStyle(OutlineButtonStyle())
                .disabled(model.selected.isEmpty)
            Button("Remove") { confirming = true }
                .buttonStyle(PillButtonStyle())
                .disabled(model.selected.isEmpty)
        }
    }
}
