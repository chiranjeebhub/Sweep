import SwiftUI
import SweepCore

/// Explained suggestions grouped by tier. Nothing is removed until the user reviews and confirms a plan.
struct CleanupView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: CleanupModel
    @ObservedObject var storage: StorageModel

    init(model: CleanupModel) {
        _model = ObservedObject(wrappedValue: model)
        _storage = ObservedObject(wrappedValue: model.storage)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Cleanup", subtitle: "Explained suggestions. Nothing is removed until you review and confirm it.") {
                if let trash = storage.trashSize, trash > 0 {
                    Button { app.selection = .trashBins } label: {
                        Label("Empty Trash · \(ByteFormat.string(trash))", systemImage: "trash")
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
                RescanButton(storage: storage)
            }
            if storage.result == nil && storage.extraRecommendations.isEmpty {
                ScanFirstState(storage: storage, title: "Scan to get suggestions",
                               detail: "Sweep measures your home folder, recognizes caches, build output and app data, and explains what is safe to remove.")
            } else {
                content
                footer
            }
        }
        .task { await storage.loadSavedIfNeeded() }
        .sheet(isPresented: Binding(get: { model.plan != nil }, set: { if !$0 { model.plan = nil } })) {
            if let plan = model.plan { PlanSheet(model: model, plan: plan) }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                filters
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield").foregroundStyle(Theme.safe)
                    Text("Trash first. Every path is checked again by the safety gate right before anything happens.")
                        .font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                    Spacer()
                    Button { model.selectAllLikelySafe() } label: {
                        Label("Select all likely safe", systemImage: "checklist")
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
                if let message = model.message {
                    NoticeBar(symbol: "checkmark.circle", title: message, detail: "Every action is recorded in History.", tint: Theme.safe) {
                        Button("History") { app.selection = .history }.buttonStyle(OutlineButtonStyle())
                    }
                }
                if storage.isScanning { ScanProgressLine(storage: storage) }
                ForEach(Tier.allCases) { tier in
                    let items = model.visible.filter { $0.tier == tier }
                    if !items.isEmpty { tierSection(tier, items) }
                }
                if model.visible.isEmpty {
                    Text("Nothing here. Try another filter or rescan.").font(.system(size: 13)).foregroundStyle(Theme.mutedText)
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                filterButton(.all) {
                    Text("All").font(.system(size: 13, weight: .medium))
                    Text("\(storage.allRecommendations.count)").font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                }
                ForEach(Tier.allCases) { tier in
                    filterButton(.tier(tier)) {
                        Circle().fill(tier.color).frame(width: 7, height: 7)
                        Text(tier.title).font(.system(size: 13, weight: .medium))
                        Text(ByteFormat.string(model.size(of: tier))).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.mutedText)
                    }
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.divider))
            let badges = ["Superseded", "Leftover", "Inactive"].filter { model.count(badge: $0) > 0 }
            if !badges.isEmpty {
                HStack(spacing: 6) {
                    Text("No longer needed:").font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                    ForEach(badges, id: \.self) { badge in
                        Button {
                            model.filter = model.filter == .badge(badge) ? .all : .badge(badge)
                        } label: {
                            Text("\(badge) \(model.count(badge: badge))").font(.system(size: 12))
                        }
                        .buttonStyle(OutlineButtonStyle(height: 24))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(model.filter == .badge(badge) ? Theme.accent : .clear))
                    }
                }
            }
        }
    }

    private func filterButton<Content: View>(_ filter: CleanupModel.Filter, @ViewBuilder label: () -> Content) -> some View {
        let active = model.filter == filter
        return Button { model.filter = filter } label: {
            HStack(spacing: 6) { label() }
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(active ? Theme.rowSelected : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tierSection(_ tier: Tier, _ items: [Recommendation]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: tier.symbol).foregroundStyle(tier.color)
                Text(tier.title).font(.system(size: 13, weight: .semibold))
                Text(tier.blurb).font(.system(size: 12)).foregroundStyle(Theme.mutedText)
            }
            .padding(.top, 6)
            VStack(spacing: 0) {
                let largest = max(items.first?.size ?? 1, 1)
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    RecommendationRow(model: model, item: item, largest: largest)
                    if index < items.count - 1 { Rectangle().fill(Theme.divider).frame(height: 1) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.divider))
        }
    }

    private var footer: some View {
        FooterBar {
            if model.isRunning {
                ProgressView().controlSize(.small)
                Text("Cleaning up…").foregroundStyle(Theme.mutedText)
            } else {
                Text(model.selected.isEmpty ? "Select items to review." : "\(model.selectedItems.count) selected")
                    .foregroundStyle(Theme.mutedText)
                if !model.selectedItems.isEmpty {
                    Text(ByteFormat.string(model.selectedSize)).font(.system(size: 13, weight: .semibold).monospacedDigit())
                    Button("Clear") { model.selected = [] }.buttonStyle(LinkButtonStyle())
                }
            }
            Spacer()
            Button {
                Task { await model.review() }
            } label: {
                if model.isPlanning { ProgressView().controlSize(.small) } else { Text("Review cleanup") }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(model.selectedItems.isEmpty || model.isRunning || model.isPlanning)
        }
    }
}

/// One suggestion: a checkbox, what it is and where, its size, and the reasoning when expanded.
struct RecommendationRow: View {
    @ObservedObject var model: CleanupModel
    let item: Recommendation
    let largest: Int64

    var body: some View {
        let isSelected = model.selected.contains(item.id)
        let isExpanded = model.expanded.contains(item.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                if item.isActionable {
                    Toggle("", isOn: Binding(get: { isSelected }, set: { _ in model.toggle(item) }))
                        .toggleStyle(.checkbox).labelsHidden()
                        .accessibilityLabel("Select \(item.title)")
                } else {
                    Image(systemName: item.tier == .keep ? "lock" : "terminal")
                        .font(.system(size: 11)).foregroundStyle(Theme.faintText).frame(width: 14)
                        .help(item.tier == .keep ? "Explained only, never removed by Sweep." : "Cleaned up with the tool's own command.")
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        CategoryLabel(category: item.category)
                        if let badge = item.badge { BadgeTag(text: badge) }
                        if item.source != "Scan" {
                            Text("via \(item.source)").font(.system(size: 11)).foregroundStyle(Theme.faintText)
                        }
                    }
                    PathText(path: item.primaryPath)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 5) {
                    SizeText(bytes: item.size)
                    Meter(fraction: Double(item.size) / Double(largest), tint: Theme.faintText).frame(width: 150)
                }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faintText).frame(width: 16)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { model.toggleExpanded(item) }
            .background(isSelected ? Theme.selectionSubtle : Color.clear)

            if isExpanded { details }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .topLeading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    detail("What it is", item.explanation)
                    detail(item.tier == .keep ? "Why Sweep keeps it" : "Why it may be safe", item.tier == .keep ? item.risks : item.safeBecause)
                    detail("Risks", item.tier == .keep ? "Removing it could lose data that exists nowhere else." : item.risks)
                }
            }
            HStack(spacing: 18) {
                fact("Proposed", item.action)
                fact("Confidence", item.confidence.title)
                if let date = item.lastActivity { fact("Last worked on", RelativeDate.string(date)) }
                if let before = item.beforeYouStart { fact("Before you start", before) }
            }
            if let command = item.command {
                HStack(spacing: 8) {
                    Text("Or run it yourself:").font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                    Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).foregroundStyle(Theme.mutedText).help("Copy")
                }
            }
            if item.paths.count > 1 {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(item.paths, id: \.self) { PathText(path: $0) }
                }
            }
            HStack {
                Button("Show in Finder") { StorageModel.reveal(item.primaryPath) }.buttonStyle(OutlineButtonStyle(height: 24))
            }
        }
        .padding(.leading, 40)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0x17181F))
    }

    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faintText)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title + ":").font(.system(size: 12)).foregroundStyle(Theme.faintText)
            Text(value).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
        }
    }
}

/// The cleanup plan: every path that will be touched, checked and measured again, before anything happens.
struct PlanSheet: View {
    @ObservedObject var model: CleanupModel
    let plan: CleanupPlan
    @State private var permanently = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review cleanup").font(.system(size: 16, weight: .semibold))
            Text("\(plan.validItems.count) item\(plan.validItems.count == 1 ? "" : "s"), \(ByteFormat.string(plan.totalSize)). Each path was just checked and measured again.")
                .font(.system(size: 13)).foregroundStyle(Theme.mutedText)
            if !plan.beforeYouStart.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Before you start").font(.system(size: 12, weight: .semibold))
                    ForEach(plan.beforeYouStart, id: \.self) { Text("• " + $0).font(.system(size: 12)).foregroundStyle(Theme.secondaryText) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.caution.opacity(0.08)))
            }
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
            .frame(minHeight: 160, maxHeight: 320)
            if plan.allowsPermanentDelete {
                Picker("", selection: $permanently) {
                    Text("Move to the Trash (recoverable)").tag(false)
                    Text("Delete permanently (all of it is regenerable)").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            } else {
                Text("Items will be moved to the Trash, so you can put them back until you empty it.")
                    .font(.system(size: 12)).foregroundStyle(Theme.mutedText)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.plan = nil }.buttonStyle(OutlineButtonStyle(height: 32)).keyboardShortcut(.cancelAction)
                Button(permanently ? "Delete \(ByteFormat.string(plan.totalSize))" : "Move \(ByteFormat.string(plan.totalSize)) to Trash") {
                    Task { await model.run(permanently: permanently) }
                }
                .buttonStyle(PillButtonStyle(fill: permanently ? Theme.critical : Theme.accent))
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
