import SwiftUI
import SweepCore

/// Every cleanup Sweep has done: what, when, how, and what it freed.
struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "History", subtitle: "Every action Sweep took, with the exact paths, the operation and the space reclaimed.") {
                if !model.entries.isEmpty {
                    Button("Clear history") { confirmClear = true }.buttonStyle(OutlineButtonStyle())
                }
            }
            if model.entries.isEmpty {
                StatusMessage(symbol: "clock.arrow.circlepath", title: "Nothing yet",
                              detail: "When you clean something up, it is recorded here with every path and the result.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 32) {
                            summary("Actions", "\(model.entries.count)")
                            summary("Reclaimed in total", ByteFormat.string(model.totalFreed))
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                                row(entry)
                                if index < model.entries.count - 1 { Rectangle().fill(Theme.divider).frame(height: 1) }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.divider))
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                }
            }
        }
        .task { await model.reload() }
        .confirmationDialog("Clear the history?", isPresented: $confirmClear) {
            Button("Clear history", role: .destructive) { Task { await model.clear() } }
        } message: {
            Text("This only forgets the record. Nothing on disk changes.")
        }
    }

    private func summary(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.mutedText)
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit())
        }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        let isExpanded = model.expanded.contains(entry.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: entry.failures == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(entry.failures == 0 ? Theme.safe : Theme.caution)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.source) · \(entry.operation)").font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened)
                         + " · \(entry.items.count) item\(entry.items.count == 1 ? "" : "s")"
                         + (entry.failures > 0 ? ", \(entry.failures) failed" : ""))
                        .font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                }
                Spacer()
                SizeText(bytes: entry.freed, weight: .medium)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faintText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                if isExpanded { model.expanded.remove(entry.id) } else { model.expanded.insert(entry.id) }
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entry.items) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.succeeded ? "checkmark" : "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(item.succeeded ? Theme.safe : Theme.critical)
                                .frame(width: 12)
                            VStack(alignment: .leading, spacing: 1) {
                                PathText(path: item.path)
                                if let error = item.error {
                                    Text(error).font(.system(size: 11)).foregroundStyle(Theme.caution)
                                }
                            }
                            Spacer()
                            if item.succeeded { SizeText(bytes: item.bytes).foregroundStyle(Theme.mutedText) }
                        }
                    }
                }
                .padding(.leading, 40)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
            }
        }
    }
}
