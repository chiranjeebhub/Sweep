import SwiftUI
import SweepCore

struct SmartScanView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: SmartScanModel
    @ObservedObject private var junk: JunkModel
    @ObservedObject private var privacy: PrivacyModel
    @ObservedObject private var optimization: OptimizationModel

    init(model: SmartScanModel) {
        _model = ObservedObject(wrappedValue: model)
        _junk = ObservedObject(wrappedValue: model.junk)
        _privacy = ObservedObject(wrappedValue: model.privacy)
        _optimization = ObservedObject(wrappedValue: model.optimization)
    }

    var body: some View {
        switch model.phase {
        case .idle: home
        case .scanning(let step): scanning(step)
        case .results(let duration): results(duration)
        case .running: StatusMessage(symbol: "", title: "Cleaning up", detail: "Moving the selected items to the Trash.", showsProgress: true)
        case .done(let freed, let skipped, let message): done(freed: freed, skipped: skipped, message: message)
        }
    }

    // MARK: Home

    private var home: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            ScanRings(spinning: false)
            VStack(spacing: 10) {
                Text("Welcome back").font(.system(size: 32, weight: .bold))
                Text("One scan checks for junk, privacy traces and things slowing your Mac down. Nothing is removed until you review it.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.mutedText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 460)
            }
            Button {
                Task { await model.scan() }
            } label: {
                Text("Scan")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 112, height: 112)
                    .background(Circle().fill(Theme.accent))
                    .background(Circle().fill(Color(hex: 0x1E2742)).padding(-10))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)

            HStack(spacing: 16) {
                statusCard("Cleanup", symbol: "trash", tint: Theme.accent, detail: LastRun.summary(.cleanup))
                statusCard("Protection", symbol: "shield", tint: Theme.protection, detail: LastRun.summary(.protection))
                statusCard("Speed", symbol: "bolt", tint: Theme.speed, detail: LastRun.summary(.speed))
            }
            .frame(maxWidth: 780)
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .padding(48)
    }

    private func statusCard(_ title: String, symbol: String, tint: Color, detail: String) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.faintText)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .card()
    }

    // MARK: Scanning

    private func scanning(_ step: String) -> some View {
        VStack(spacing: 28) {
            ScanRings(spinning: true)
            VStack(spacing: 8) {
                Text("Scanning your Mac").font(.system(size: 28, weight: .bold))
                Text(step + "…").font(.system(size: 15)).foregroundStyle(Theme.mutedText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Results

    private func results(_ duration: TimeInterval) -> some View {
        VStack(spacing: 32) {
            VStack(spacing: 8) {
                Text("SCAN COMPLETE · \(Int(duration.rounded())) S")
                    .font(.system(size: 12, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Theme.accentText)
                Text("Here's what we found").font(.system(size: 30, weight: .bold))
                Text("Review any section before running. Everything selected below will be handled in one go.")
                    .font(.system(size: 15)).foregroundStyle(Theme.mutedText)
            }

            HStack(alignment: .top, spacing: 20) {
                ResultCard(
                    title: "Cleanup", symbol: "trash", tint: Theme.accent,
                    headline: ByteFormat.string(junk.selectedSize), caption: "of junk ready to remove",
                    rows: junk.categories.filter { !$0.items.isEmpty }.prefix(4).map {
                        ResultCard.Row(label: $0.title, value: ByteFormat.string(junk.selectedSize(of: $0)))
                    },
                    isIncluded: $model.includeCleanup,
                    review: { app.selection = .systemJunk })
                ResultCard(
                    title: "Protection", symbol: "shield", tint: Theme.protection,
                    headline: "\(privacy.selectedCount)", caption: "kinds of privacy traces",
                    rows: privacy.sources.prefix(4).map {
                        ResultCard.Row(label: $0.name,
                              value: $0.needsFullDiskAccess ? "Locked" : ByteFormat.string($0.size))
                    },
                    isIncluded: $model.includeProtection,
                    review: { app.selection = .privacy })
                ResultCard(
                    title: "Speed", symbol: "bolt", tint: Theme.speed,
                    headline: "\(optimization.selectedTaskCount)", caption: "tasks to run",
                    rows: [
                        ResultCard.Row(label: "Free up RAM", value: optimization.snapshot.map { ByteFormat.string($0.memoryUsed) + " used" } ?? "Ready"),
                        ResultCard.Row(label: "Flush DNS cache", value: "Ready"),
                        ResultCard.Row(label: "Background items", value: "\(optimization.backgroundItemCount)"),
                    ],
                    isIncluded: $model.includeSpeed,
                    review: { app.selection = .optimization })
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 16) {
                Button("Rescan") { Task { await model.scan() } }
                    .buttonStyle(OutlineButtonStyle())
                Button("Run all") { Task { await model.runAll() } }
                    .buttonStyle(PillButtonStyle(height: 52))
                    .disabled(!model.includeCleanup && !model.includeProtection && !model.includeSpeed)
            }
        }
        .padding(.horizontal, 48)
        .padding(.top, 48)
        .padding(.bottom, 40)
    }

    // MARK: Done

    private func done(freed: Int64, skipped: [String], message: String?) -> some View {
        VStack(spacing: 20) {
            Circle()
                .fill(Theme.speed.opacity(0.16))
                .frame(width: 120, height: 120)
                .overlay(Image(systemName: "checkmark").font(.system(size: 48, weight: .semibold)).foregroundStyle(Theme.speed))
            Text("All done").font(.system(size: 30, weight: .bold))
            Text("Freed \(ByteFormat.string(freed)). Everything removed is in the Trash if you need it back.")
                .font(.system(size: 15)).foregroundStyle(Theme.mutedText)
            if !skipped.isEmpty {
                Text("Skipped \(skipped.joined(separator: ", ")) because it was open. Quit it and run Privacy again.")
                    .font(.system(size: 13)).foregroundStyle(Theme.protection)
            }
            if let message {
                Text(message).font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            }
            Button("Done") { model.reset() }
                .buttonStyle(PillButtonStyle())
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The concentric rings above the Scan button. Spins while a scan runs.
private struct ScanRings: View {
    let spinning: Bool
    @State private var angle: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(Theme.surface, lineWidth: 2).frame(width: 244, height: 244)
            Circle().stroke(Theme.border, lineWidth: 2).frame(width: 192, height: 192)
            Circle().fill(Theme.panel).frame(width: 140, height: 140)
            Circle().stroke(Theme.track, lineWidth: 2).frame(width: 140, height: 140)
            Circle()
                .trim(from: 0, to: 0.16)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 244, height: 244)
                .rotationEffect(.degrees(angle - 90))
            Image(systemName: "sparkles").font(.system(size: 48, weight: .light)).foregroundStyle(Theme.accent)
        }
        .frame(width: 260, height: 260)
        .accessibilityHidden(true)
        .onAppear {
            guard spinning else { return }
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { angle = 360 }
        }
    }
}

private struct ResultCard: View {
    struct Row: Identifiable {
        var id: String { label }
        let label: String
        let value: String
    }

    let title: String
    let symbol: String
    let tint: Color
    let headline: String
    let caption: String
    let rows: [Row]
    @Binding var isIncluded: Bool
    let review: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, tint: tint, size: 36)
                Text(title).font(.system(size: 16, weight: .semibold))
                Spacer()
                CheckBox(isOn: $isIncluded, label: "Include \(title)")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(headline).font(.system(size: 40, weight: .bold)).foregroundStyle(tint)
                Text(caption).font(.system(size: 13)).foregroundStyle(Theme.mutedText)
            }
            VStack(spacing: 8) {
                if rows.isEmpty {
                    Text("Nothing found").font(.system(size: 13)).foregroundStyle(Theme.faintText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(rows) { row in
                    HStack {
                        Text(row.label).foregroundStyle(Theme.secondaryText)
                        Spacer()
                        Text(row.value).foregroundStyle(row.value == "Locked" ? Theme.protection : Theme.faintText)
                    }
                    .font(.system(size: 13))
                }
            }
            Spacer(minLength: 0)
            Button("Review details", action: review).buttonStyle(LinkButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(radius: 16)
        .opacity(isIncluded ? 1 : 0.55)
    }
}
