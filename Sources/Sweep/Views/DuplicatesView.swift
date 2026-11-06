import SwiftUI
import SweepCore

/// Sets of identical files. One copy of every set always stays, and you choose which.
struct DuplicatesView: View {
    @ObservedObject var model: DuplicatesModel

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Duplicates", subtitle: "Files with identical contents. One copy of every set always stays, and you choose which.") {
                if model.hasScanned && !model.isScanning {
                    Button { Task { await model.scan() } } label: { Label("Scan again", systemImage: "arrow.clockwise") }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
            if model.isScanning {
                scanning
            } else if !model.hasScanned {
                intro
            } else if model.groups.isEmpty {
                StatusMessage(symbol: "checkmark.circle", title: "No duplicates found",
                              detail: "No two files of \(Int(model.minimumSizeMB)) MB or more have the same contents.")
            } else {
                results
            }
        }
        .sheet(isPresented: Binding(get: { model.plan != nil }, set: { if !$0 { model.plan = nil } })) {
            if let plan = model.plan {
                ConfirmPlanSheet(title: "Remove duplicate copies?", plan: plan,
                                 note: "Each copy is compared byte for byte with the one you keep right before it is moved.",
                                 onCancel: { model.plan = nil },
                                 onConfirm: { _ in Task { await model.run() } })
            }
        }
    }

    private var intro: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.on.doc").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.faintText)
            Text("Find files with identical contents").font(.system(size: 15, weight: .semibold))
            Text("Sweep compares sizes, then the first 64 KB, then a SHA-256 of the whole file. Hidden folders, your Library, app bundles and dependency folders are skipped, hard links count once, and APFS clones are flagged because removing one frees little or nothing.")
                .font(.system(size: 13)).foregroundStyle(Theme.mutedText).multilineTextAlignment(.center).frame(maxWidth: 520)
            HStack(spacing: 8) {
                Text("Ignore files smaller than").font(.system(size: 13)).foregroundStyle(Theme.mutedText)
                Picker("", selection: $model.minimumSizeMB) {
                    Text("100 KB").tag(0.1)
                    Text("1 MB").tag(1.0)
                    Text("10 MB").tag(10.0)
                    Text("100 MB").tag(100.0)
                }
                .labelsHidden()
                .frame(width: 100)
            }
            Button("Find duplicates") { Task { await model.scan() } }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var scanning: some View {
        VStack(spacing: 12) {
            ProgressView(value: model.total > 0 ? Double(model.done) / Double(model.total) : nil)
                .progressViewStyle(.linear)
                .frame(width: 360)
            Text(model.phase).font(.system(size: 13, weight: .medium))
            Text(model.total > 0 ? "\(model.done.formatted()) of \(model.total.formatted())" : "\(model.done.formatted()) files")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.mutedText)
            Button("Stop") { model.cancel() }.buttonStyle(OutlineButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sets").font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                    Text("\(model.groups.count)").font(.system(size: 22, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reclaimable").font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                    Text(ByteFormat.string(model.totalReclaimable)).font(.system(size: 22, weight: .semibold).monospacedDigit())
                }
                Spacer()
                TextField("Filter by name", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 200)
                Button("Select all") { model.selectAll() }.buttonStyle(OutlineButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            if let message = model.message {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.safe)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 8)
            }
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.visibleGroups) { group in
                        groupRow(group)
                        Rectangle().fill(Theme.divider).frame(height: 1)
                    }
                }
            }
            FooterBar {
                Text(model.included.isEmpty ? "Choose sets to clean up." : "\(model.copiesToRemove.count) copies · \(ByteFormat.string(model.selectedReclaimable))")
                    .foregroundStyle(Theme.mutedText)
                Spacer()
                Button("Review removal") { Task { await model.review() } }
                    .buttonStyle(PillButtonStyle())
                    .disabled(model.included.isEmpty)
            }
        }
    }

    private func groupRow(_ group: DuplicateGroup) -> some View {
        let isExpanded = model.expanded.contains(group.id)
        let keeper = model.keeper(of: group)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(
                    get: { model.included.contains(group.id) },
                    set: { on in if on { model.included.insert(group.id) } else { model.included.remove(group.id) } }))
                    .toggleStyle(.checkbox).labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.files[0].name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text("\(group.files.count) copies of \(ByteFormat.string(group.size))"
                         + (group.files.contains(where: \.isClone) ? " · some are APFS clones" : ""))
                        .font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                }
                Spacer()
                SizeText(bytes: group.reclaimable)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faintText)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                if isExpanded { model.expanded.remove(group.id) } else { model.expanded.insert(group.id) }
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(group.files) { file in
                        HStack(spacing: 10) {
                            Button {
                                model.keepers[group.id] = file.path
                            } label: {
                                Image(systemName: file.path == keeper ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(file.path == keeper ? Theme.accent : Theme.faintText)
                            }
                            .buttonStyle(.plain)
                            .help("Keep this copy")
                            VStack(alignment: .leading, spacing: 1) {
                                PathText(path: file.path)
                                Text((file.modified.map { "Modified " + RelativeDate.string($0).lowercased() } ?? "")
                                     + (file.isClone ? " · APFS clone: removing it frees little or nothing" : ""))
                                    .font(.system(size: 11)).foregroundStyle(file.isClone ? Theme.caution : Theme.faintText)
                            }
                            Spacer()
                            Text(file.path == keeper ? "Keep" : "Remove").font(.system(size: 11, weight: .medium))
                                .foregroundStyle(file.path == keeper ? Theme.safe : Theme.mutedText)
                            Button { StorageModel.reveal(file.path) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.plain).foregroundStyle(Theme.mutedText).help("Show in Finder")
                        }
                    }
                }
                .padding(.leading, 56)
                .padding(.trailing, 24)
                .padding(.bottom, 12)
            }
        }
    }
}
