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
                VStack(alignment: .leading, spacing: 18) {
                    notices
                    diskSummary
                    if storage.result == nil {
                        if storage.isScanning {
                            ScanProgressLine(storage: storage)
                            Text("Read-only. You can keep using your Mac while Sweep scans.")
                                .font(.system(size: 12)).foregroundStyle(Theme.faintText)
                        } else {
                            emptyState
                        }
                    } else {
                        if storage.isScanning { ScanProgressLine(storage: storage) }
                        HStack(alignment: .top, spacing: 18) {
                            startHere
                                .padding(20)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .card(radius: 16)
                                .layoutPriority(1)
                            whereSpaceGoes
                                .padding(20)
                                .frame(width: 340, alignment: .topLeading)
                                .card(radius: 16)
                        }
                    }
                }
                .frame(maxWidth: 1040, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
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
                      detail: "macOS keeps folders such as Mail, Messages and Safari private unless Sweep has Full Disk Access.",
                      tint: Theme.caution) {
                Button("Open Full Disk Access") { StorageModel.openFullDiskAccessSettings() }
                    .buttonStyle(OutlineButtonStyle())
            }
        }
    }

    // MARK: Disk

    @ViewBuilder private var diskSummary: some View {
        if let volume = storage.volume {
            HStack(alignment: .center, spacing: 36) {
                DiskRing(volume: volume, categories: storage.summary?.categories ?? [], notScanned: storage.notScanned)
                    .frame(width: 168, height: 168)
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(volume.name.uppercased())
                            .font(.system(size: 11, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(Theme.faintText)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(ByteFormat.string(volume.used))
                                .font(.system(size: 34, weight: .bold).monospacedDigit()).tracking(-0.5)
                            Text("of \(ByteFormat.string(volume.total)) used")
                                .font(.system(size: 15)).foregroundStyle(Theme.mutedText)
                        }
                    }
                    HStack(spacing: 12) {
                        statTile("Available", ByteFormat.string(volume.available), symbol: "internaldrive", tint: Theme.accent,
                                 help: "Free space on the disk. Purgeable space macOS can free on its own isn't counted.")
                        if storage.result != nil {
                            statTile("Safe to remove", ByteFormat.string(storage.likelyRecoverable), symbol: "sparkles", tint: Theme.safe,
                                     help: "The total of suggestions in the Likely safe tier. Each is still reviewed and confirmed by you.")
                        }
                    }
                    if storage.result != nil {
                        Button {
                            app.selection = .cleanup
                        } label: {
                            Label("Review cleanup", systemImage: "arrow.right").labelStyle(TrailingIconLabelStyle())
                        }
                        .buttonStyle(PillButtonStyle(height: 34))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(26)
            .card(radius: 16)
        }
    }

    private func statTile(_ title: String, _ value: String, symbol: String, tint: Color, help: String) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: tint, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.mutedText)
                Text(value).font(.system(size: 19, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text)
            }
        }
        .padding(.vertical, 12)
        .padding(.leading, 12)
        .padding(.trailing, 20)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface.opacity(0.6)))
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
            SectionTitle(title: "Start here", subtitle: nil) {
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(item.safeBecause).font(.system(size: 12)).foregroundStyle(Theme.mutedText).lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        TierTag(tier: item.tier)
                        SizeText(bytes: item.size).frame(width: 74, alignment: .trailing)
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < items.count - 1 { Rectangle().fill(Theme.hairline).frame(height: 1) }
            }
        }
    }

    private var whereSpaceGoes: some View {
        let categories = Array((storage.summary?.categories ?? []).prefix(6))
        let largest = max(categories.first?.size ?? 1, 1)
        return VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Where your space goes")
                .padding(.bottom, 10)
            ForEach(categories) { item in
                HStack(spacing: 8) {
                    Circle().fill(item.category.color).frame(width: 8, height: 8)
                    Text(item.category.title).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 8)
                    Meter(fraction: Double(item.size) / Double(largest), tint: item.category.color).frame(width: 90)
                    SizeText(bytes: item.size).frame(width: 66, alignment: .trailing)
                }
                .padding(.vertical, 5)
            }
        }
    }
}

/// Puts a label's icon after its title, as on "Review cleanup →".
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon.font(.system(size: 11, weight: .bold))
        }
    }
}

/// Disk usage as a ring: each scanned category in its colour, then the unscanned part, with free space left as track.
struct DiskRing: View {
    let volume: VolumeInfo
    let categories: [ScanSummary.CategoryTotal]
    let notScanned: Int64

    private struct Segment: Identifiable {
        let id: Int
        let start: Double
        let end: Double
        let color: Color
    }

    private var segments: [Segment] {
        let total = max(Double(volume.total), 1)
        var parts: [(Double, Color)] = categories.map { (Double($0.size) / total, $0.category.color) }
        if notScanned > 0 { parts.append((Double(notScanned) / total, Color(hex: 0x4A4B57))) }
        var result: [Segment] = []
        var cursor = 0.0
        let gap = 0.004
        for (index, part) in parts.enumerated() where part.0 > 0.002 {
            let end = min(cursor + part.0, 1)
            result.append(Segment(id: index, start: cursor, end: max(cursor, end - gap), color: part.1))
            cursor = end
        }
        return result
    }

    private var usedFraction: Double { Double(volume.used) / max(Double(volume.total), 1) }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.surface, lineWidth: 16)
            ForEach(segments) { segment in
                Circle()
                    .trim(from: segment.start, to: segment.end)
                    .stroke(segment.color, style: StrokeStyle(lineWidth: 16, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                Text("\(Int((usedFraction * 100).rounded()))%")
                    .font(.system(size: 30, weight: .bold).monospacedDigit()).tracking(-0.5)
                Text("used").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.mutedText)
            }
        }
        .padding(8)
        .accessibilityElement()
        .accessibilityLabel("Disk \(Int((usedFraction * 100).rounded())) percent used")
    }
}
