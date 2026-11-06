import AppKit
import SwiftUI
import SweepCore

/// The menu bar panel: free space at a glance and shortcuts into the main window.
struct MenuBarView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var storage: StorageModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ring
                VStack(alignment: .leading, spacing: 3) {
                    if let volume = storage.volume {
                        Text("\(ByteFormat.string(volume.available)) free").font(.system(size: 16, weight: .semibold).monospacedDigit())
                        Text("\(ByteFormat.string(volume.used)) of \(ByteFormat.string(volume.total)) used on \(volume.name)")
                            .font(.system(size: 11)).foregroundStyle(Theme.mutedText)
                    } else {
                        Text("Disk").font(.system(size: 16, weight: .semibold))
                    }
                }
            }
            VStack(spacing: 0) {
                if storage.result != nil {
                    line("Likely safe to remove", ByteFormat.string(storage.likelyRecoverable), color: Theme.safe)
                }
                if let trash = storage.trashSize {
                    line("In the Trash", ByteFormat.string(trash), color: Theme.text)
                }
                if let date = storage.result?.date {
                    line("Last scan", RelativeDate.string(date), color: Theme.mutedText)
                }
            }
            VStack(spacing: 4) {
                shortcut("Review cleanup", symbol: "sparkles", module: .cleanup)
                shortcut("Find duplicates", symbol: "doc.on.doc", module: .duplicates)
                shortcut("Empty Trash", symbol: "trash", module: .trashBins)
                shortcut("Developer tools", symbol: "hammer", module: .developer)
            }
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack {
                Button(storage.isScanning ? "Scanning…" : "Scan now") { Task { await storage.scan() } }
                    .buttonStyle(LinkButtonStyle()).disabled(storage.isScanning)
                Spacer()
                Button("Open Sweep") { open(.overview) }.buttonStyle(LinkButtonStyle())
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(LinkButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(Theme.window)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .task {
            storage.refreshVolume()
            await storage.refreshTrash()
            await storage.loadSavedIfNeeded()
        }
    }

    private var ring: some View {
        let fraction = storage.volume.map { Double($0.used) / Double(max($0.total, 1)) } ?? 0
        let tint = fraction > 0.9 ? Theme.critical : (fraction > 0.75 ? Theme.caution : Theme.accent)
        return ZStack {
            Circle().stroke(Theme.track, lineWidth: 6)
            Circle().trim(from: 0, to: fraction).stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
            Text("\(Int((fraction * 100).rounded()))%").font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .frame(width: 52, height: 52)
        .accessibilityLabel("Disk \(Int(fraction * 100)) percent full")
    }

    private func line(_ title: String, _ value: String, color: Color) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.mutedText)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(color)
        }
        .padding(.vertical, 4)
    }

    private func shortcut(_ title: String, symbol: String, module: Module) -> some View {
        Button { open(module) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(Theme.accentText)
                Text(title).font(.system(size: 13))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faintText)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func open(_ module: Module) {
        app.selection = module
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}
