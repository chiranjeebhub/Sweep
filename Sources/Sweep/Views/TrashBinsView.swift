import SwiftUI
import SweepCore

struct TrashBinsView: View {
    @ObservedObject var model: TrashModel
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Trash Bins", subtitle: "Files you've deleted still use space until the Trash is emptied.")
            Rectangle().fill(Theme.divider).frame(height: 1)
            VStack(spacing: 20) {
                IconTile(symbol: "trash", tint: Theme.accent, size: 96)
                if let size = model.size {
                    Text(ByteFormat.string(size)).font(.system(size: 40, weight: .bold)).foregroundStyle(Theme.accentText)
                    Text(model.itemCount == 1 ? "1 item in the Trash" : "\(model.itemCount) items in the Trash")
                        .font(.system(size: 15)).foregroundStyle(Theme.mutedText)
                } else {
                    Text("Sweep can't see inside the Trash yet").font(.system(size: 18, weight: .semibold))
                    Text("Give Sweep Full Disk Access in System Settings to measure it. You can still empty it below.")
                        .font(.system(size: 13)).foregroundStyle(Theme.mutedText)
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                }
                if let error = model.errorMessage {
                    Text(error).font(.system(size: 13)).foregroundStyle(Theme.protection)
                }
                Button(model.isWorking ? "Emptying…" : "Empty Trash") { confirming = true }
                    .buttonStyle(PillButtonStyle())
                    .disabled(model.isWorking || model.size == 0)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.refresh() }
        .alert("Permanently erase the items in the Trash?", isPresented: $confirming) {
            Button("Empty Trash", role: .destructive) { Task { await model.empty() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can't undo this action.")
        }
    }
}
