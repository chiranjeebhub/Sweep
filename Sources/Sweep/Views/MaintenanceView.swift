import SwiftUI
import SweepCore

struct MaintenanceView: View {
    @ObservedObject var model: MaintenanceModel

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Maintenance", subtitle: "Run the housekeeping tasks that keep macOS quick and tidy.")
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.tasks) { task in
                        row(task)
                    }
                }
                .card()
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
            }
            FooterBar {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selected.isEmpty ? "Nothing selected" : "\(model.selected.count) tasks selected")
                        .font(.system(size: 15, weight: .semibold))
                    if model.needsPassword {
                        Text("Some tasks need your administrator password.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.faintText)
                    }
                }
                Spacer()
                Button(model.isRunning ? "Running…" : "Run") { Task { await model.run() } }
                    .buttonStyle(PillButtonStyle(fill: Theme.speed, foreground: Color(hex: 0x06150F)))
                    .disabled(model.selected.isEmpty || model.isRunning)
            }
        }
    }

    private func row(_ task: MaintenanceTask) -> some View {
        HStack(spacing: 14) {
            CheckBox(isOn: Binding(get: { model.selected.contains(task.id) },
                                   set: { if $0 { model.selected.insert(task.id) } else { model.selected.remove(task.id) } }),
                     tint: Theme.speed, label: task.title)
                .disabled(model.isRunning)
            Image(systemName: task.symbol).foregroundStyle(Theme.speed).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(.system(size: 14, weight: .semibold))
                Text(resultHint(task) ?? task.detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(resultHint(task) == nil ? Theme.faintText : Theme.danger)
            }
            Spacer()
            status(task)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private func resultHint(_ task: MaintenanceTask) -> String? {
        model.results[task.id] == .failed ? task.failureHint : nil
    }

    @ViewBuilder private func status(_ task: MaintenanceTask) -> some View {
        if model.isRunning && model.selected.contains(task.id) {
            ProgressView().controlSize(.small)
        } else if let result = model.results[task.id] {
            switch result {
            case .done: badge("Done", color: Theme.speed)
            case .failed: badge("Failed", color: Theme.danger)
            case .cancelled: badge("Cancelled", color: Theme.faintText)
            }
        } else if task.needsAdmin {
            Image(systemName: "lock").font(.system(size: 12)).foregroundStyle(Theme.faintText)
                .help("Needs your administrator password")
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.14)))
    }
}
