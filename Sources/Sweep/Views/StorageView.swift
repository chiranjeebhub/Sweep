import SwiftUI
import SweepCore

/// Browse the scan: folders by size with what each one is, and the largest files.
struct StorageView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: ExplorerModel
    @ObservedObject var storage: StorageModel

    init(model: ExplorerModel) {
        _model = ObservedObject(wrappedValue: model)
        _storage = ObservedObject(wrappedValue: model.storage)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Storage", subtitle: "Folders by size, what each one is, and how much inside can be cleaned up.") {
                Picker("", selection: $model.tab) {
                    ForEach(ExplorerModel.Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                RescanButton(storage: storage)
            }
            if storage.result == nil {
                ScanFirstState(storage: storage, title: "Scan to browse your storage",
                               detail: "Sweep measures every folder by the space it really takes on disk and recognizes what it is.")
            } else if model.tab == .folders {
                folders
            } else {
                LargestItemsView(model: model)
            }
        }
        .task {
            await storage.loadSavedIfNeeded()
            await model.loadFiles()
        }
        .onChange(of: storage.result?.date) { _ in
            model.currentPath = nil
            Task { await model.loadFiles() }
        }
    }

    // MARK: Folders

    private var folders: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                header
                Rectangle().fill(Theme.divider).frame(height: 1)
                list
            }
            Rectangle().fill(Theme.divider).frame(width: 1)
            DetailsPanel(model: model).frame(width: 300)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { if let parent = model.current?.parent { model.open(parent.path) } } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(OutlineButtonStyle(height: 26))
            .disabled(model.current?.parent == nil)
            .help("Enclosing folder")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(model.breadcrumbs.enumerated()), id: \.element.id) { index, node in
                        if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.faintText) }
                        Button(index == 0 ? URL(fileURLWithPath: node.path).abbreviatedPath : node.name) { model.open(node.path) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: index == model.breadcrumbs.count - 1 ? .semibold : .regular))
                            .foregroundStyle(index == model.breadcrumbs.count - 1 ? Theme.text : Theme.mutedText)
                    }
                }
            }
            Spacer()
            Picker("", selection: $model.categoryFilter) {
                Text("All categories").tag(SweepCore.Category?.none)
                ForEach(SweepCore.Category.allCases) { Text($0.title).tag(SweepCore.Category?.some($0)) }
            }
            .labelsHidden()
            .frame(width: 150)
            TextField("Filter by name", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            sortHeader("Name", .name).frame(maxWidth: .infinity, alignment: .leading)
            ColumnLabel("Category").frame(width: 150, alignment: .leading)
            ColumnLabel("Cleanup").frame(width: 130, alignment: .leading)
            sortHeader("Size", .size).frame(width: 150, alignment: .trailing)
            sortHeader("Files", .files).frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 26)
    }

    private func sortHeader(_ title: String, _ sort: ExplorerModel.Sort) -> some View {
        Button { model.sort = sort } label: {
            HStack(spacing: 3) {
                ColumnLabel(title)
                if model.sort == sort { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.faintText) }
            }
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        let rows = model.rows
        let largest = max(rows.map(\.size).max() ?? 1, 1)
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    ExplorerRowView(model: model, row: row, largest: largest)
                }
                if model.fileOverflow > 0 {
                    Text("\(model.fileOverflow) smaller files not listed.").font(.system(size: 12)).foregroundStyle(Theme.faintText).padding(10)
                }
                if rows.isEmpty {
                    Text(model.search.isEmpty && model.categoryFilter == nil ? "This folder is empty." : "Nothing matches the filter.")
                        .font(.system(size: 13)).foregroundStyle(Theme.mutedText).padding(.vertical, 40)
                }
            }
        }
    }
}

/// One folder or file in the explorer.
struct ExplorerRowView: View {
    @ObservedObject var model: ExplorerModel
    let row: ExplorerRow
    let largest: Int64

    var body: some View {
        let isSelected = model.selectedPath == row.path
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: row.isFolder ? (row.unreadable ? "lock.fill" : "folder.fill") : "doc")
                    .font(.system(size: 12))
                    .foregroundStyle(row.isFolder ? Theme.accent.opacity(0.8) : Theme.faintText)
                    .frame(width: 16)
                Text(row.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CategoryLabel(category: row.category).frame(width: 150, alignment: .leading)
            cleanupCell.frame(width: 130, alignment: .leading)
            HStack(spacing: 8) {
                Meter(fraction: Double(row.size) / Double(largest), tint: row.category.color.opacity(0.85)).frame(width: 60)
                SizeText(bytes: row.size).frame(width: 74, alignment: .trailing)
            }
            .frame(width: 150, alignment: .trailing)
            Text(row.fileCount.map { $0.formatted() } ?? "")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.mutedText)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(isSelected ? Theme.rowSelected : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if row.isFolder { model.open(row.path) } }
        .simultaneousGesture(TapGesture().onEnded { model.selectedPath = row.path })
        .contextMenu {
            Button("Show in Finder") { StorageModel.reveal(row.path) }
            if row.isFolder { Button("Open") { model.open(row.path) } }
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.path, forType: .string)
            }
        }
    }

    @ViewBuilder private var cleanupCell: some View {
        if let item = model.recommendation(for: row.path) {
            TierTag(tier: item.tier)
        } else if row.isFolder, model.cleanable(inside: row.path) > 0 {
            Text("\(ByteFormat.string(model.cleanable(inside: row.path))) inside")
                .font(.system(size: 12)).foregroundStyle(Theme.safe.opacity(0.9))
        } else {
            Text("").frame(width: 1)
        }
    }
}

/// What the selected folder is, why, and what can be done with it.
struct DetailsPanel: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: ExplorerModel
    @State private var live: (modified: Date?, created: Date?)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let path = model.selectedPath ?? model.current?.path {
                    content(path)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.sidebar)
        .task(id: model.selectedPath ?? model.current?.path) { await loadLive() }
    }

    @ViewBuilder private func content(_ path: String) -> some View {
        let node = model.root?.node(at: path)
        let row = model.selectedRow
        let classification = node?.classification
        let name = node.map { $0.parent == nil ? URL(fileURLWithPath: $0.path).abbreviatedPath : $0.name } ?? row?.name ?? ""

        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
            PathText(path: path)
        }
        HStack(spacing: 18) {
            fact("Size", ByteFormat.string(node?.size ?? row?.size ?? 0))
            if let count = node?.fileCount { fact("Files", count.formatted()) }
        }
        if let live {
            if let modified = live.modified { fact("Modified", modified.formatted(date: .abbreviated, time: .shortened)) }
            if let created = live.created { fact("Created", created.formatted(date: .abbreviated, time: .omitted)) }
        }
        if node?.unreadable == true {
            Text("macOS didn't let Sweep read this folder. Give Sweep Full Disk Access to measure it.")
                .font(.system(size: 12)).foregroundStyle(Theme.caution)
        }

        Rectangle().fill(Theme.divider).frame(height: 1)

        if let classification {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(classification.rule.label).font(.system(size: 13, weight: .semibold))
                    CategoryLabel(category: classification.rule.category)
                }
                Text(classification.rule.explanation).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                fact("Confidence", classification.rule.confidence.title)
                fact("Rule", classification.rule.id)
                if classification.originPath != path {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Inherited from").font(.system(size: 11)).foregroundStyle(Theme.faintText)
                        PathText(path: classification.originPath)
                    }
                }
            }
        } else if let row, !row.isFolder {
            VStack(alignment: .leading, spacing: 6) {
                Text(row.label).font(.system(size: 13, weight: .semibold))
                CategoryLabel(category: row.category)
            }
        } else {
            Text("Sweep doesn't recognize this folder, so it never suggests removing it.")
                .font(.system(size: 12)).foregroundStyle(Theme.mutedText)
        }

        if let item = model.recommendation(for: path) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                TierTag(tier: item.tier)
                Text(item.tier == .keep ? item.risks : item.safeBecause).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if item.isActionable {
                    Button("Review in Cleanup") {
                        app.cleanup.selected.insert(item.id)
                        app.cleanup.expanded.insert(item.id)
                        app.selection = .cleanup
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
            }
        } else if model.cleanable(inside: path) > 0 {
            Text("\(ByteFormat.string(model.cleanable(inside: path))) inside can be cleaned up.")
                .font(.system(size: 12)).foregroundStyle(Theme.safe)
        }

        Button("Show in Finder") { StorageModel.reveal(path) }.buttonStyle(OutlineButtonStyle())
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.faintText)
            Text(value).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
    }

    private func loadLive() async {
        guard let path = model.selectedPath ?? model.current?.path else { live = nil; return }
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        live = (values?.contentModificationDate, values?.creationDate)
    }
}

/// The 500 largest files, and the folders where data piles up.
struct LargestItemsView: View {
    @ObservedObject var model: ExplorerModel

    var body: some View {
        let rows = model.largest
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $model.largestFilter) {
                    ForEach(ExplorerModel.LargestFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 210)
                TextField("Filter by name", text: $model.largestSearch).textFieldStyle(.roundedBorder).frame(width: 200)
                Spacer()
                Text("Size alone is never a reason to delete something.").font(.system(size: 12)).foregroundStyle(Theme.faintText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if let message = model.message {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.safe).padding(.horizontal, 16).padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let largest = max(rows.first?.size ?? 1, 1)
                    ForEach(rows) { row in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { model.largestSelected.contains(row.path) },
                                set: { on in if on { model.largestSelected.insert(row.path) } else { model.largestSelected.remove(row.path) } }))
                                .toggleStyle(.checkbox).labelsHidden()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                                PathText(path: (row.path as NSString).deletingLastPathComponent)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.label).font(.system(size: 12)).foregroundStyle(Theme.mutedText).frame(width: 150, alignment: .leading)
                            Text(row.modified.map { RelativeDate.string($0) } ?? "").font(.system(size: 12)).foregroundStyle(Theme.faintText)
                                .frame(width: 110, alignment: .leading)
                            Meter(fraction: Double(row.size) / Double(largest), tint: row.category.color.opacity(0.85)).frame(width: 60)
                            SizeText(bytes: row.size).frame(width: 74, alignment: .trailing)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .contentShape(Rectangle())
                        .contextMenu { Button("Show in Finder") { StorageModel.reveal(row.path) } }
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                    if !model.accumulating.isEmpty && model.largestFilter == .all && model.largestSearch.isEmpty {
                        SectionTitle(title: "Where files pile up", subtitle: "Folders holding the most data directly, not in subfolders.")
                            .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 8)
                        ForEach(model.accumulating) { node in
                            HStack(spacing: 10) {
                                Image(systemName: "folder").foregroundStyle(Theme.faintText)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(node.name).font(.system(size: 13)).lineLimit(1)
                                    PathText(path: node.path)
                                }
                                Spacer()
                                Text("\(node.ownSize == node.size ? "" : "\(ByteFormat.string(node.ownSize)) of ")\(ByteFormat.string(node.size))")
                                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.mutedText)
                                Button("Open") {
                                    model.tab = .folders
                                    model.open(node.path)
                                }
                                .buttonStyle(OutlineButtonStyle(height: 24))
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                        }
                    }
                }
            }
            FooterBar {
                Text(model.largestSelected.isEmpty ? "\(rows.count) files" : "\(model.largestSelected.count) selected · \(ByteFormat.string(model.largestSelectedSize))")
                    .foregroundStyle(Theme.mutedText)
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(model.largestSelected.map { URL(fileURLWithPath: $0) })
                }
                .buttonStyle(OutlineButtonStyle(height: 32))
                .disabled(model.largestSelected.isEmpty)
                Button("Review removal") { Task { await model.reviewLargestSelection() } }
                    .buttonStyle(PillButtonStyle())
                    .disabled(model.largestSelected.isEmpty)
            }
        }
        .sheet(isPresented: Binding(get: { model.plan != nil }, set: { if !$0 { model.plan = nil } })) {
            if let plan = model.plan {
                ConfirmPlanSheet(title: "Move to the Trash?", plan: plan,
                                 onCancel: { model.plan = nil },
                                 onConfirm: { permanently in Task { await model.runPlan(permanently: permanently) } })
            }
        }
    }
}

/// A plan of paths to confirm, used by Largest items and Duplicates.
struct ConfirmPlanSheet: View {
    let title: String
    let plan: CleanupPlan
    var note: String? = nil
    let onCancel: () -> Void
    let onConfirm: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 16, weight: .semibold))
            Text("\(plan.validItems.count) item\(plan.validItems.count == 1 ? "" : "s"), \(ByteFormat.string(plan.totalSize)). They go to the Trash, so you can put them back until you empty it.")
                .font(.system(size: 13)).foregroundStyle(Theme.mutedText)
            if let note { Text(note).font(.system(size: 12)).foregroundStyle(Theme.secondaryText) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(plan.items) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.problem == nil ? "checkmark.circle" : "exclamationmark.triangle")
                                .foregroundStyle(item.problem == nil ? Theme.safe : Theme.caution)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                PathText(path: item.path)
                                if let problem = item.problem {
                                    Text("Skipped: \(problem)").font(.system(size: 11)).foregroundStyle(Theme.caution)
                                }
                            }
                            Spacer()
                            SizeText(bytes: item.size)
                        }
                        .padding(.vertical, 6)
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                }
            }
            .frame(minHeight: 140, maxHeight: 320)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(OutlineButtonStyle(height: 32)).keyboardShortcut(.cancelAction)
                Button("Move \(ByteFormat.string(plan.totalSize)) to Trash") { onConfirm(false) }
                    .buttonStyle(PillButtonStyle())
                    .disabled(plan.validItems.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 620)
        .background(Theme.window)
        .preferredColorScheme(.dark)
    }
}
