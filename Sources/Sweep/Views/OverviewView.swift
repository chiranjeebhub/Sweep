import SwiftUI
import SweepCore

/// The answer first: how full the disk is, what is likely recoverable, and where to start.
struct OverviewView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var storage: StorageModel

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Overview", subtitle: "") {
                RescanButton(storage: storage)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    notices
                    diskSummary
                    if storage.result == nil {
                        if storage.isScanning {
                            ScanProgressLine(storage: storage)
                            Text("Read-only. You can keep using your Mac while Sweep scans.")
                                .font(.system(size: 12)).foregroundStyle(Theme.faintText)
                        } else if !storage.isLoading {
                            emptyState
                        }
                    } else {
                        if storage.isScanning { ScanProgressLine(storage: storage) }
                        Rectangle().fill(Theme.divider).frame(height: 1)
                        HStack(alignment: .top, spacing: 44) {
                            startHere.frame(maxWidth: .infinity, alignment: .topLeading).layoutPriority(1)
                            whereSpaceGoes.frame(width: 340, alignment: .topLeading)
                        }
                        HStack(alignment: .top, spacing: 44) {
                            largestItems.frame(maxWidth: .infinity, alignment: .topLeading).layoutPriority(1)
                            lastScan.frame(width: 340, alignment: .topLeading)
                        }
                    }
                }
                .frame(maxWidth: 1120, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
        }
        .task { await storage.loadSavedIfNeeded() }
    }

    // MARK: Notices

    @ViewBuilder private var notices: some View {
        if let trash = storage.trashSize, trash > 50_000_000 {
            NoticeBar(symbol: "trash", title: "\(ByteFormat.string(trash)) is waiting in the Trash (\(storage.trashCount) item\(storage.trashCount == 1 ? "" : "s")).",
                      detail: "Moving items to the Trash keeps them recoverable. The space comes back when the Trash is emptied.") {
                Button("Empty Trash · \(ByteFormat.string(trash))") { app.selection = .trashBins }
                    .buttonStyle(OutlineButtonStyle())
            }
        }
        if let result = storage.result, !result.unreadable.isEmpty {
            NoticeBar(symbol: "lock", title: "\(result.unreadable.count) folder\(result.unreadable.count == 1 ? "" : "s") couldn't be measured.",
                      detail: "macOS keeps folders such as Mail, Messages and Safari private unless Sweep has Full Disk Access. They are listed under Last scan.",
                      tint: Theme.caution) {
                Button("Open Full Disk Access") { StorageModel.openFullDiskAccessSettings() }
                    .buttonStyle(OutlineButtonStyle())
            }
        }
    }

    // MARK: Disk

    @ViewBuilder private var diskSummary: some View {
        if let volume = storage.volume {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 32) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(volume.name).font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(ByteFormat.string(volume.used)).font(.system(size: 30, weight: .semibold).monospacedDigit())
                            Text("used of \(ByteFormat.string(volume.total))").font(.system(size: 15)).foregroundStyle(Theme.mutedText)
                        }
                    }
                    Spacer()
                    statBlock("Available", ByteFormat.string(volume.available), color: Theme.text,
                         help: "Free space on the disk. Purgeable space macOS can free on its own isn't counted.")
                    if storage.result != nil {
                        statBlock("Likely safe to remove", ByteFormat.string(storage.likelyRecoverable), color: Theme.safe,
                             help: "The total of suggestions in the Likely safe tier. Each is still reviewed and confirmed by you.")
                        Button("Review cleanup") { app.selection = .cleanup }
                            .buttonStyle(PillButtonStyle())
                    }
                }
                StorageStrip(volume: volume, categories: storage.summary?.categories ?? [], notScanned: storage.notScanned)
                FlowLayout(spacing: 16, lineSpacing: 6) {
                    ForEach(storage.summary?.categories ?? []) { item in
                        LegendItem(color: item.category.color, title: item.category.title, bytes: item.size)
                    }
                    if storage.notScanned > 0 {
                        LegendItem(color: Color(hex: 0x4A4B57), title: "Not scanned", bytes: storage.notScanned)
                    }
                    LegendItem(color: Theme.surface, title: "Available", bytes: volume.available)
                    if storage.result != nil {
                        LegendItem(color: .white, title: "Likely recoverable", bytes: nil, hatched: true)
                    }
                }
            }
        }
    }

    private func statBlock(_ title: String, _ value: String, color: Color, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(Theme.faintText)
            }
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit()).foregroundStyle(color)
        }
        .help(help)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            Text("Scan to see where your space goes").font(.system(size: 15, weight: .semibold)).padding(.top, 8)
            Text("Sweep reads file sizes in \(storage.scanRoot.abbreviatedPath) and changes nothing. Symbolic links are not followed and other disks are skipped.")
                .font(.system(size: 13)).foregroundStyle(Theme.mutedText)
            HStack(spacing: 10) {
                Button("Scan \(storage.scanRoot.abbreviatedPath)") { Task { await storage.scan() } }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Button("Choose another folder") { chooseFolder() }.buttonStyle(OutlineButtonStyle(height: 32))
            }
            .padding(.top, 4)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = storage.scanRoot
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: StorageModel.scanRootKey)
            Task { await storage.scan() }
        }
    }

    // MARK: Sections

    private var startHere: some View {
        let items = Array(storage.allRecommendations.filter { $0.tier != .keep }.prefix(5))
        return VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Start here", subtitle: "The largest items Sweep can explain and clean up.") {
                Button("All \(storage.actionableCount) in Cleanup") { app.selection = .cleanup }.buttonStyle(LinkButtonStyle())
            }
            .padding(.bottom, 6)
            if items.isEmpty {
                Text("Nothing large enough to suggest. Your disk is in good shape.")
                    .font(.system(size: 13)).foregroundStyle(Theme.mutedText).padding(.vertical, 8)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button {
                    app.cleanup.filter = .all
                    app.cleanup.expanded.insert(item.id)
                    app.selection = .cleanup
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        Circle().fill(item.tier.color).frame(width: 7, height: 7).padding(.horizontal, 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(item.safeBecause).font(.system(size: 12)).foregroundStyle(Theme.mutedText).lineLimit(1)
                            PathText(path: item.primaryPath)
                        }
                        Spacer(minLength: 12)
                        TierTag(tier: item.tier)
                        SizeText(bytes: item.size).frame(width: 74, alignment: .trailing)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < items.count - 1 { Rectangle().fill(Theme.hairline).frame(height: 1) }
            }
        }
    }

    private var whereSpaceGoes: some View {
        let categories = storage.summary?.categories ?? []
        let total = max(categories.reduce(0) { $0 + $1.size }, 1)
        let largest = max(categories.first?.size ?? 1, 1)
        return VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Where your space goes",
                         subtitle: "\(ByteFormat.string(storage.result?.totalSize ?? 0)) in \(storage.result?.rootURL.abbreviatedPath ?? "~")")
                .padding(.bottom, 8)
            ForEach(categories) { item in
                HStack(spacing: 8) {
                    Circle().fill(item.category.color).frame(width: 8, height: 8)
                    Text(item.category.title).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 8)
                    Meter(fraction: Double(item.size) / Double(largest), tint: item.category.color).frame(width: 90)
                    SizeText(bytes: item.size).frame(width: 66, alignment: .trailing)
                    Text(percent(item.size, of: total)).font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.faintText).frame(width: 42, alignment: .trailing)
                }
                .padding(.vertical, 5)
            }
        }
    }

    private func percent(_ part: Int64, of total: Int64) -> String {
        let value = Double(part) / Double(total) * 100
        if value < 0.1 { return "<0.1%" }
        return value < 10 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value)
    }

    private var largestItems: some View {
        let items = storage.largestRecognized
        return VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Largest items", subtitle: "Folders Sweep recognized. Click one to show it in Finder.")
                .padding(.bottom, 6)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button {
                    StorageModel.reveal(item.path)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            PathText(path: item.path)
                        }
                        Spacer(minLength: 12)
                        CategoryLabel(category: item.category)
                        SizeText(bytes: item.size).frame(width: 74, alignment: .trailing)
                    }
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < items.count - 1 { Rectangle().fill(Theme.hairline).frame(height: 1) }
            }
        }
    }

    @ViewBuilder private var lastScan: some View {
        if let result = storage.result {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Last scan", subtitle: RelativeDate.string(result.date))
                detail("Folder", result.rootURL.abbreviatedPath)
                detail("Measured", ByteFormat.string(result.totalSize))
                detail("Files", result.fileCount.formatted())
                detail("Took", Duration.seconds(result.duration).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))
                if !result.unreadable.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Not measured (no permission)").font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                        ForEach(result.unreadable.prefix(6), id: \.self) { PathText(path: $0) }
                        if result.unreadable.count > 6 {
                            Text("and \(result.unreadable.count - 6) more").font(.system(size: 11)).foregroundStyle(Theme.faintText)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.mutedText)
            Spacer()
            Text(value).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
    }
}
