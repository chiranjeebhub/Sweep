import SwiftUI
import SweepCore

/// Editors, AI agents, runtimes and build tools: what each keeps on disk and what is worth reviewing.
struct DeveloperView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: DeveloperModel
    @ObservedObject var storage: StorageModel

    private let columns = [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), spacing: 16, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Developer", subtitle: "Editors, AI agents, runtimes and build tools. Read-only until you review in Cleanup.") {
                Button { Task { await model.analyze() } } label: { Label("Analyze again", systemImage: "arrow.clockwise") }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(model.isAnalyzing)
            }
            if model.reports.isEmpty {
                if model.isAnalyzing || model.analyzedAt == nil {
                    StatusMessage(symbol: "", title: "Looking at your developer tools", showsProgress: true)
                } else {
                    StatusMessage(symbol: "hammer", title: "No developer tools found",
                                  detail: "Sweep looks for Xcode, VS Code, Cursor, Claude Code, Node, Python, Rust, Homebrew and more.")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        stats
                        if storage.result == nil {
                            NoticeBar(symbol: "info.circle", title: "Project folders come from a disk scan.",
                                      detail: "Run a scan to include Rust target folders, Python environments and other per-project build output.") {
                                RescanButton(storage: storage)
                            }
                        }
                        credentials
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(model.reports) { report in
                                ToolCard(report: report, isExpanded: model.expanded.contains(report.id),
                                         toggle: { model.toggle(report) }, review: { model.review(report, app: app) })
                            }
                        }
                    }
                    .frame(maxWidth: 1120, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .task { await model.analyzeIfNeeded() }
    }

    private var stats: some View {
        HStack(spacing: 32) {
            stat("Tools found", "\(model.reports.filter { $0.id != "leftovers" }.count)", color: Theme.text)
            stat("On disk", ByteFormat.string(model.totalSize), color: Theme.text)
            stat("Worth reviewing", ByteFormat.string(model.reviewSize), color: Theme.safe,
                 note: "\(model.reviewCount) suggestion\(model.reviewCount == 1 ? "" : "s")")
            stat("Older versions and leftovers", "\(model.leftoverCount)", color: model.leftoverCount > 0 ? Theme.caution : Theme.text)
            Spacer()
            if model.isAnalyzing { ProgressView().controlSize(.small) }
        }
    }

    private func stat(_ title: String, _ value: String, color: Color, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.mutedText)
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit()).foregroundStyle(color)
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(Theme.faintText) }
        }
    }

    // MARK: Credentials in transcripts

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: "key", tint: model.secrets.isEmpty ? Theme.lavender : Theme.critical, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Credentials in AI transcripts").font(.system(size: 14, weight: .semibold))
                    Text(credentialsSummary).font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if model.isCheckingSecrets {
                    ProgressView().controlSize(.small)
                } else {
                    Button(model.secretsCheckedAt == nil ? "Check transcripts" : "Check again") { Task { await model.checkSecrets() } }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
            if !model.secrets.isEmpty {
                VStack(spacing: 0) {
                    ForEach(model.secrets) { finding in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(finding.kind).font(.system(size: 13, weight: .medium))
                                    Text(finding.masked).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondaryText)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Text([finding.agent, finding.project.map { URL(fileURLWithPath: $0).abbreviatedPath },
                                      finding.occurrences > 1 ? "\(finding.occurrences) times" : nil, RelativeDate.string(finding.lastSeen)]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 11)).foregroundStyle(Theme.faintText).lineLimit(1)
                            }
                            Spacer()
                            Button("Show file") { StorageModel.reveal(finding.file) }.buttonStyle(LinkButtonStyle())
                        }
                        .padding(.vertical, 8)
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                }
                Text("Rotate these keys with their provider: removing the transcript doesn't undo the exposure. Values are matched on this Mac and never leave it.")
                    .font(.system(size: 11)).foregroundStyle(Theme.faintText)
            }
        }
        .padding(16)
        .card()
    }

    private var credentialsSummary: String {
        if model.secretsCheckedAt == nil {
            return "Look for API keys, tokens and private keys pasted into Claude Code, Codex and Gemini CLI conversations. Offline and read-only."
        }
        if model.secrets.isEmpty { return "No credentials found in saved transcripts." }
        let files = Set(model.secrets.map(\.file)).count
        return "\(model.secrets.count) credential\(model.secrets.count == 1 ? "" : "s") in \(files) transcript\(files == 1 ? "" : "s"). Only masked values are shown."
    }
}

/// One tool: size, what it keeps, and how much of it is worth reviewing.
private struct ToolCard: View {
    let report: ToolReport
    let isExpanded: Bool
    let toggle: () -> Void
    let review: () -> Void

    private var reviewable: Int { report.id == "leftovers" ? report.details.count : report.reviewCount }
    private var reviewableSize: Int64 { report.id == "leftovers" ? report.totalSize : report.reviewSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: report.symbol, tint: report.id == "leftovers" ? Theme.caution : Theme.lavender, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(report.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if let version = report.version, !version.isEmpty {
                            Text(version).font(.system(size: 11)).foregroundStyle(Theme.faintText).lineLimit(1)
                        }
                    }
                    Text(report.summary).font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                SizeText(bytes: report.totalSize, weight: .semibold)
            }
            if !report.badgeCounts.isEmpty {
                HStack(spacing: 6) {
                    ForEach(report.badgeCounts.map(\.0), id: \.self) { name in
                        BadgeTag(text: name, count: report.badgeCounts.first { $0.0 == name }?.1)
                    }
                }
            }
            HStack(spacing: 10) {
                if reviewable > 0 {
                    Button("Review \(reviewable) · \(ByteFormat.string(reviewableSize))", action: review)
                        .buttonStyle(PillButtonStyle())
                } else {
                    Text("Nothing to clean up").font(.system(size: 12)).foregroundStyle(Theme.faintText)
                }
                Spacer()
                if !report.details.isEmpty {
                    Button(isExpanded ? "Hide details" : "Details", action: toggle).buttonStyle(LinkButtonStyle())
                }
            }
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(report.details.prefix(60).enumerated()), id: \.offset) { _, detail in
                        DetailRow(detail: detail)
                    }
                    if report.details.count > 60 {
                        Text("and \(report.details.count - 60) more").font(.system(size: 11)).foregroundStyle(Theme.faintText)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }
}

private struct DetailRow: View {
    let detail: ToolDetail

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(detail.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    if let badge = detail.badge { BadgeTag(text: badge) }
                }
                if let note = detail.note {
                    Text(note).font(.system(size: 11)).foregroundStyle(Theme.faintText).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let size = detail.size { SizeText(bytes: size).foregroundStyle(Theme.secondaryText) }
        }
        .padding(.vertical, 5)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .contextMenu {
            if let path = detail.path { Button("Show in Finder") { StorageModel.reveal(path) } }
        }
    }
}
