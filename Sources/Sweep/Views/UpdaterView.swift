import AppKit
import SwiftUI
import SweepCore

struct UpdaterView: View {
    @ObservedObject var model: UpdaterModel

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Updater", subtitle: "Keep your apps on their latest versions.") {
                if model.hasChecked && !model.isChecking {
                    Button("Check again") { Task { await model.check() } }.buttonStyle(LinkButtonStyle())
                }
            }
            Rectangle().fill(Theme.divider).frame(height: 1)

            if model.isChecking || !model.hasChecked {
                StatusMessage(symbol: "", title: "Checking your apps for updates…", showsProgress: true)
            } else if model.updates.isEmpty {
                VStack(spacing: 18) {
                    IconTile(symbol: "checkmark.circle", tint: Theme.speed, size: 96)
                    Text("Your apps are up to date").font(.system(size: 22, weight: .bold))
                    Text(coverageNote)
                        .font(.system(size: 13)).foregroundStyle(Theme.mutedText)
                        .multilineTextAlignment(.center).frame(maxWidth: 460)
                    if let message = model.message {
                        Text(message).font(.system(size: 13)).foregroundStyle(Theme.speed)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
                FooterBar {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.updates.count == 1 ? "1 update available" : "\(model.updates.count) updates available")
                            .font(.system(size: 15, weight: .semibold))
                        Text(model.message ?? coverageNote)
                            .font(.system(size: 12.5))
                            .foregroundStyle(model.message == nil ? Theme.faintText : Theme.protection)
                            .lineLimit(2)
                    }
                    Spacer()
                }
            }
        }
        .task { if !model.hasChecked && !model.isChecking { await model.check() } }
    }

    private var coverageNote: String {
        "Checked \(model.appCount) apps. Sweep covers App Store apps and apps that update with Sparkle. Apps with their own updater, such as Chrome, keep themselves current."
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.updates) { update in
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: update.app.url.path))
                            .resizable().frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(update.app.name).font(.system(size: 13.5, weight: .medium))
                            Text("\(update.app.version ?? "Unknown") → \(update.latestVersion) · \(sourceName(update))")
                                .font(.system(size: 11.5)).foregroundStyle(Theme.faintText)
                        }
                        Spacer()
                        if model.installing.contains(update.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(model.actionTitle(for: update)) { Task { await model.update(update) } }
                                .buttonStyle(LinkButtonStyle())
                                .disabled(!model.installing.isEmpty)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 54)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func sourceName(_ update: AppUpdate) -> String {
        switch update.source {
        case .appStore: "App Store"
        case .sparkle: "From the developer"
        }
    }
}
