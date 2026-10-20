import AppKit
import SwiftUI
import SweepCore

struct OptimizationView: View {
    @ObservedObject var model: OptimizationModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Optimization").font(.system(size: 22, weight: .bold))
                    Text("Take control of what runs on your Mac and free up memory.")
                        .font(.system(size: 13)).foregroundStyle(Theme.mutedText)
                }

                stats

                VStack(spacing: 0) {
                    taskRow(title: "Free up RAM", detail: "Clear inactive memory held by apps you have closed",
                            badge: model.snapshot.map { ByteFormat.string($0.memoryUsed) + " used" } ?? "",
                            isOn: $model.freeMemory)
                    taskRow(title: "Flush DNS cache", detail: "Fixes some slow or failing website connections",
                            badge: "Ready", isOn: $model.flushDNS)
                    infoRow(title: "Login items", detail: "Apps that open automatically when you sign in",
                            badge: "Manage", action: model.openLoginItemsSettings)
                    infoRow(title: "Background items", detail: "Helpers and agents that start with your Mac",
                            badge: "\(model.backgroundItemCount) items", action: model.openLoginItemsSettings)
                }
                .card()

                VStack(alignment: .leading, spacing: 0) {
                    Text("Heavy consumers")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 6)
                    Text("Apps using the most memory right now")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.faintText)
                        .padding(.horizontal, 18).padding(.bottom, 8)
                    ForEach(model.heavyApps) { app in
                        HStack(spacing: 12) {
                            if let icon = app.icon {
                                Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                            }
                            Text(app.name).font(.system(size: 13.5))
                            Spacer()
                            Text(ByteFormat.string(app.memory)).font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText)
                            Button("Quit") { model.quit(app) }.buttonStyle(LinkButtonStyle())
                        }
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
                    }
                }
                .card()

                HStack {
                    if let message = model.lastMessage {
                        Text(message).font(.system(size: 13)).foregroundStyle(Theme.speed)
                    }
                    Spacer()
                    Button(model.isRunning ? "Working…" : "Perform \(model.selectedTaskCount) tasks") {
                        model.runSelectedTasks()
                    }
                    .buttonStyle(PillButtonStyle(fill: Theme.speed, foreground: Color(hex: 0x06150F)))
                    .disabled(model.selectedTaskCount == 0 || model.isRunning)
                }
                Text("Freeing memory and flushing DNS need your administrator password.")
                    .font(.system(size: 12)).foregroundStyle(Theme.faintText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 24)
        }
        .onAppear { model.refresh() }
    }

    private var stats: some View {
        HStack(spacing: 16) {
            statCard("Memory",
                     detail: model.snapshot.map { "\(ByteFormat.string($0.memoryTotal)) total" } ?? "",
                     value: model.snapshot.map { "\(ByteFormat.string($0.memoryUsed)) used" } ?? "–",
                     fraction: model.snapshot?.memoryFraction ?? 0, tint: Theme.protection)
            statCard("CPU",
                     detail: model.snapshot.map { "\($0.cpuCores) cores" } ?? "",
                     value: model.snapshot.map { "\(Int(($0.cpuLoad * 100).rounded()))% load" } ?? "–",
                     fraction: model.snapshot?.cpuLoad ?? 0, tint: Theme.speed)
            statCard("Startup disk",
                     detail: model.snapshot.map { ByteFormat.string($0.diskTotal) } ?? "",
                     value: model.snapshot.map { "\(ByteFormat.string($0.diskFree)) free" } ?? "–",
                     fraction: model.snapshot?.diskUsedFraction ?? 0, tint: Theme.accent)
        }
    }

    private func statCard(_ label: String, detail: String, value: String, fraction: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label).foregroundStyle(Theme.secondaryText).fontWeight(.medium)
                Spacer()
                Text(detail).foregroundStyle(Theme.faintText)
            }
            .font(.system(size: 13))
            Text(value).font(.system(size: 26, weight: .bold))
            UsageBar(fraction: fraction, tint: tint)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .card()
    }

    private func taskRow(title: String, detail: String, badge: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            CheckBox(isOn: isOn, tint: Theme.speed, label: title)
            rowText(title: title, detail: detail)
            Spacer()
            badgeView(badge)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private func infoRow(title: String, detail: String, badge: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.up.forward.app").foregroundStyle(Theme.faintText).frame(width: 16)
            rowText(title: title, detail: detail)
            Spacer()
            Button(action: action) { badgeView(badge) }.buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private func rowText(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.faintText)
        }
    }

    private func badgeView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
    }
}
