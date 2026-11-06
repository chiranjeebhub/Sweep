import SwiftUI
import SweepCore

extension Category {
    /// Chart colour. Identity is always carried by a label too.
    var color: Color {
        switch self {
        case .applicationData: Color(hex: 0x5B8CFF)
        case .cache: Color(hex: 0xE5B94E)
        case .buildArtifacts: Color(hex: 0xFF8A65)
        case .developerTools: Color(hex: 0xB48CFF)
        case .dockerStorage: Color(hex: 0x2FC6A6)
        case .logs: Color(hex: 0xE07070)
        case .downloads: Color(hex: 0x6FCF6F)
        case .userData: Color(hex: 0xE878B0)
        case .binaryData: Color(hex: 0xA39486)
        case .systemFiles: Color(hex: 0x7C8494)
        case .unknown: Color(hex: 0x5B5F6B)
        }
    }
}

extension Tier {
    var color: Color {
        switch self {
        case .likelySafe: Theme.safe
        case .reviewFirst: Theme.caution
        case .keep: Theme.faintText
        }
    }

    var symbol: String {
        switch self {
        case .likelySafe: "checkmark.circle"
        case .reviewFirst: "questionmark.circle"
        case .keep: "lock"
        }
    }
}

/// The tier's coloured tag: the only coloured tag in the app.
struct TierTag: View {
    let tier: Tier
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: tier.symbol).font(.system(size: 10, weight: .semibold))
            Text(tier.title).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tier.color)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 4).fill(tier.color.opacity(0.13)))
        .fixedSize()
    }
}

/// A small outlined tag such as "Leftover" or "Inactive".
struct BadgeTag: View {
    let text: String
    var count: Int? = nil
    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.caution)
            if let count { Text("\(count)").font(.system(size: 11)).foregroundStyle(Theme.mutedText) }
        }
        .padding(.horizontal, 6)
        .frame(height: 19)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.caution.opacity(0.10)))
        .fixedSize()
    }
}

/// A coloured dot and the category's name. Never a filled pill.
struct CategoryLabel: View {
    let category: Category
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(category.color).frame(width: 7, height: 7)
            Text(category.title).font(.system(size: 12)).foregroundStyle(Theme.mutedText)
        }
        .fixedSize()
    }
}

/// A path in monospaced type, with the home folder shortened to ~.
struct PathText: View {
    let path: String
    var body: some View {
        Text(URL(fileURLWithPath: path).abbreviatedPath)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.faintText)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

/// A size in tabular figures, right aligned.
struct SizeText: View {
    let bytes: Int64
    var weight: Font.Weight = .regular
    var body: some View {
        Text(ByteFormat.string(bytes))
            .font(.system(size: 13, weight: weight).monospacedDigit())
            .lineLimit(1)
    }
}

/// A section title with an optional line under it, as on the Overview.
struct SectionTitle<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.mutedText) }
            }
            Spacer()
            trailing
        }
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A thin meter behind a size.
struct Meter: View {
    let fraction: Double
    var tint: Color = Theme.accent
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface)
                Capsule().fill(tint).frame(width: max(2, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// A notice row with an icon, two lines of text and an optional button.
struct NoticeBar<Action: View>: View {
    let symbol: String
    let title: String
    let detail: String
    var tint: Color = Theme.mutedText
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.mutedText).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .card()
    }
}

/// The whole disk as one bar: scanned data by category, then the rest of used space, then free space.
struct StorageStrip: View {
    let volume: VolumeInfo
    let categories: [ScanSummary.CategoryTotal]
    let notScanned: Int64

    var body: some View {
        GeometryReader { proxy in
            let total = max(Double(volume.total), 1)
            let width = proxy.size.width
            HStack(spacing: 1.5) {
                ForEach(categories) { item in
                    let segment = width * Double(item.size) / total
                    if segment >= 1 {
                        ZStack(alignment: .trailing) {
                            Rectangle().fill(item.category.color)
                            if item.recoverable > 0 {
                                // The likely recoverable part, hatched.
                                Rectangle()
                                    .fill(Color.white.opacity(0.28))
                                    .frame(width: segment * Double(item.recoverable) / Double(max(item.size, 1)))
                            }
                        }
                        .frame(width: segment)
                    }
                }
                if notScanned > 0 {
                    Rectangle().fill(Color(hex: 0x4A4B57)).frame(width: width * Double(notScanned) / total)
                }
                Spacer(minLength: 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
        }
        .frame(height: 26)
        .accessibilityElement()
        .accessibilityLabel("Disk usage by category")
    }
}

/// Wraps lines of legend items onto as many rows as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 16
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// One legend entry: dot, name and size.
struct LegendItem: View {
    let color: Color
    let title: String
    let bytes: Int64?
    var hatched = false

    var body: some View {
        HStack(spacing: 5) {
            if hatched {
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.35)).frame(width: 9, height: 9)
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.mutedText)
            if let bytes {
                Text(ByteFormat.string(bytes)).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

/// Shown on screens that need a scan before they have anything to say.
struct ScanFirstState: View {
    @ObservedObject var storage: StorageModel
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.faintText)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(Theme.mutedText).multilineTextAlignment(.center).frame(maxWidth: 440)
            if storage.isScanning {
                ScanProgressLine(storage: storage).frame(maxWidth: 360)
            } else {
                Button("Scan \(storage.scanRoot.abbreviatedPath)") { Task { await storage.scan() } }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

/// "Scanning… 120,000 files, 40 GB so far" with an indeterminate bar.
struct ScanProgressLine: View {
    @ObservedObject var storage: StorageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Scanning…").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(storage.progressFiles.formatted()) files, \(ByteFormat.string(storage.progressBytes))")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.mutedText)
                Button("Stop") { storage.cancelScan() }.buttonStyle(LinkButtonStyle())
            }
            ProgressView().progressViewStyle(.linear).tint(Theme.accent)
        }
    }
}

/// The "Rescan" button used in screen headers.
struct RescanButton: View {
    @ObservedObject var storage: StorageModel
    var body: some View {
        Button {
            Task { await storage.scan() }
        } label: {
            Label(storage.result == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
        }
        .buttonStyle(OutlineButtonStyle())
        .disabled(storage.isScanning)
    }
}
