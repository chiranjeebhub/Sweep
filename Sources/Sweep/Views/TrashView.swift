import SwiftUI
import SweepCore

/// What is in the Trash, emptied item by item with live progress and a Stop button.
struct TrashView: View {
    @ObservedObject var model: TrashBinModel

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Trash", subtitle: "Items in the Trash still use disk space. Emptying deletes them for good.") {
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(model.isEmptying)
            }
            switch model.state {
            case .loading:
                StatusMessage(symbol: "", title: "Looking in the Trash", showsProgress: true)
            case .notPermitted:
                notPermitted
            case .loaded:
                if model.items.isEmpty && model.message == nil {
                    StatusMessage(symbol: "trash", title: "The Trash is empty")
                } else {
                    list
                }
            }
        }
        .task { await model.refresh() }
        .confirmationDialog("Delete \(model.items.count) items permanently?", isPresented: $model.confirmEmpty) {
            Button("Empty Trash (\(ByteFormat.string(model.totalSize)))", role: .destructive) { Task { await model.empty() } }
        } message: {
            Text("This can't be undone.")
        }
    }

    private var notPermitted: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.faintText)
            Text("Sweep needs Full Disk Access to list the Trash").font(.system(size: 15, weight: .semibold))
            Text("macOS keeps the Trash private. Turn on Sweep in System Settings > Privacy & Security > Full Disk Access, then come back. You can also let Finder empty it without listing what is inside.")
                .font(.system(size: 13)).foregroundStyle(Theme.mutedText).multilineTextAlignment(.center).frame(maxWidth: 480)
            HStack(spacing: 10) {
                Button("Open Full Disk Access") { StorageModel.openFullDiskAccessSettings() }.buttonStyle(PillButtonStyle())
                Button("Empty with Finder") { Task { await model.emptyWithFinder() } }.buttonStyle(OutlineButtonStyle(height: 32))
            }
            if let message = model.message { Text(message).font(.system(size: 12)).foregroundStyle(Theme.mutedText) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var list: some View {
        VStack(spacing: 0) {
            if let message = model.message {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.safe)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 12)
            }
            if model.isEmptying {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(model.doneCount), total: Double(max(model.items.count, 1))).progressViewStyle(.linear)
                    Text("Deleting \(model.doneCount + 1) of \(model.items.count)…").font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                }
                .padding(.horizontal, 24).padding(.top, 12)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.items) { item in
                        HStack(spacing: 10) {
                            statusIcon(item).frame(width: 16)
                            Image(systemName: item.isFolder ? "folder" : "doc").foregroundStyle(Theme.faintText)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                                if let error = model.results[item.path]?.error {
                                    Text(error).font(.system(size: 11)).foregroundStyle(Theme.caution)
                                } else if let volume = item.volume {
                                    Text("On \(volume)").font(.system(size: 11)).foregroundStyle(Theme.faintText)
                                }
                            }
                            Spacer()
                            if let date = item.trashedDate {
                                Text(RelativeDate.string(date)).font(.system(size: 12)).foregroundStyle(Theme.faintText)
                            }
                            SizeText(bytes: item.size).frame(width: 80, alignment: .trailing)
                        }
                        .padding(.horizontal, 24)
                        .frame(height: 38)
                        .contextMenu { Button("Show in Finder") { StorageModel.reveal(item.path) } }
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                }
            }
            FooterBar {
                Text("\(model.items.count) items · \(ByteFormat.string(model.totalSize))").foregroundStyle(Theme.mutedText)
                Spacer()
                if model.isEmptying {
                    Button("Stop") { model.stop() }.buttonStyle(OutlineButtonStyle(height: 32))
                } else {
                    Button("Empty Trash") { model.confirmEmpty = true }
                        .buttonStyle(PillButtonStyle(fill: Theme.critical))
                        .disabled(model.items.isEmpty)
                }
            }
        }
    }

    @ViewBuilder private func statusIcon(_ item: TrashItem) -> some View {
        if let result = model.results[item.path] {
            Image(systemName: result.succeeded ? "checkmark" : "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(result.succeeded ? Theme.safe : Theme.critical)
        } else if model.current == item.path {
            ProgressView().controlSize(.mini)
        } else {
            Color.clear
        }
    }
}
