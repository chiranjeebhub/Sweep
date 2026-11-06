import SwiftUI
import SweepCore

/// Docker's images, containers, volumes and build cache, cleaned only with Docker's own commands.
struct DockerView: View {
    @ObservedObject var model: DockerModel
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Docker", subtitle: "Cleaned only with Docker's own commands. Volumes are never removed.") {
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(model.isLoading || model.running != nil)
            }
            content
        }
        .task { if model.snapshot == nil { await model.refresh() } }
        .sheet(item: $model.pending) { action in confirm(action) }
    }

    @ViewBuilder private var content: some View {
        if let snapshot = model.snapshot {
            switch snapshot.status {
            case .notInstalled:
                StatusMessage(symbol: "shippingbox", title: "Docker isn't installed",
                              detail: "Sweep looks for the docker command from Docker Desktop, OrbStack, Colima and Homebrew.")
            case .notRunning(let engine):
                VStack(spacing: 14) {
                    StatusMessage(symbol: "pause.circle", title: "\(engine) isn't running",
                                  detail: diskImageText(snapshot) ?? "Start it so Sweep can ask Docker what it's storing.")
                        .frame(height: 220)
                    HStack(spacing: 10) {
                        Button("Open \(engine)") { model.openDocker() }.buttonStyle(PillButtonStyle())
                        Button("Check again") { Task { await model.refresh() } }.buttonStyle(OutlineButtonStyle(height: 32))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .running(let engine, let version):
                running(snapshot, engine: engine, version: version)
            }
        } else {
            StatusMessage(symbol: "", title: "Asking Docker what it's storing", showsProgress: true)
        }
    }

    private func diskImageText(_ snapshot: DockerSnapshot) -> String? {
        guard let disk = snapshot.diskImage else { return nil }
        return "Its virtual disk uses \(ByteFormat.string(disk.allocated)) on this Mac (it can grow to \(ByteFormat.string(disk.maximum))). Start it to see what's inside."
    }

    private func running(_ snapshot: DockerSnapshot, engine: String, version: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let message = model.message {
                    Text(message.text).font(.system(size: 12)).foregroundStyle(message.succeeded ? Theme.safe : Theme.critical)
                        .textSelection(.enabled)
                }
                usage(snapshot, engine: engine, version: version)
                actions(snapshot)
                Picker("", selection: $tab) {
                    Text("Images (\(snapshot.images.count))").tag(0)
                    Text("Containers (\(snapshot.containers.count))").tag(1)
                    Text("Volumes (\(snapshot.volumes.count))").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                switch tab {
                case 0: images(snapshot)
                case 1: containers(snapshot)
                default: volumes(snapshot)
                }
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
        }
    }

    private func usage(_ snapshot: DockerSnapshot, engine: String, version: String) -> some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(engine) · Docker \(version)").font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                if let disk = snapshot.diskImage {
                    Text(ByteFormat.string(disk.allocated)).font(.system(size: 22, weight: .semibold).monospacedDigit())
                    Text("Virtual disk on this Mac").font(.system(size: 11)).foregroundStyle(Theme.faintText)
                }
            }
            ForEach(snapshot.usage) { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.type).font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                    Text(ByteFormat.string(row.size)).font(.system(size: 22, weight: .semibold).monospacedDigit())
                    Text("\(ByteFormat.string(row.reclaimable)) reclaimable").font(.system(size: 11))
                        .foregroundStyle(row.reclaimable > 0 ? Theme.safe : Theme.faintText)
                }
            }
            Spacer()
        }
    }

    private func actions(_ snapshot: DockerSnapshot) -> some View {
        let all: [(DockerAction, Bool)] = [
            (.pruneContainers(snapshot), !snapshot.stoppedContainers.isEmpty),
            (.pruneDanglingImages(snapshot), !snapshot.danglingImages.isEmpty),
            (.pruneBuildCache(snapshot), (snapshot.usage("Build Cache")?.size ?? 0) > 0),
            (.pruneUnusedImages(snapshot), !snapshot.unusedImages.isEmpty),
        ]
        return VStack(spacing: 0) {
            ForEach(all.indices, id: \.self) { index in
                let action = all[index].0
                let enabled = all[index].1
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.title).font(.system(size: 13, weight: .medium))
                        Text(action.explanation).font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                        Text(action.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.faintText)
                    }
                    Spacer()
                    if let estimate = action.estimate, estimate > 0 { SizeText(bytes: estimate).foregroundStyle(Theme.safe) }
                    if model.running == action.id {
                        ProgressView().controlSize(.small).frame(width: 70)
                    } else {
                        Button("Review") { model.pending = action }
                            .buttonStyle(OutlineButtonStyle())
                            .disabled(!enabled || model.running != nil)
                    }
                }
                .padding(.vertical, 10).padding(.horizontal, 16)
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
        }
        .card()
    }

    private func images(_ snapshot: DockerSnapshot) -> some View {
        VStack(spacing: 0) {
            ForEach(snapshot.images) { image in
                row(title: image.name, detail: [image.inUse ? "Used by a container" : "Not used", image.created].joined(separator: " · "),
                    badge: image.isDangling ? "Untagged" : (image.inUse ? nil : "Unused"), size: image.size,
                    action: image.inUse ? nil : .removeImage(image))
            }
        }
    }

    private func containers(_ snapshot: DockerSnapshot) -> some View {
        VStack(spacing: 0) {
            ForEach(snapshot.containers) { container in
                row(title: container.name, detail: "\(container.image) · \(container.status)",
                    badge: container.isRunning ? nil : "Stopped", size: nil,
                    action: container.isRunning ? nil : .removeContainer(container))
            }
        }
    }

    private func volumes(_ snapshot: DockerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Volumes hold databases and other data containers save. Sweep lists them but never removes them; use docker volume rm yourself if you're sure.")
                .font(.system(size: 12)).foregroundStyle(Theme.mutedText).padding(.bottom, 8)
            ForEach(snapshot.volumes) { volume in
                row(title: volume.name, detail: volume.driver, badge: volume.inUse ? nil : "Not attached", size: nil, action: nil)
            }
        }
    }

    private func row(title: String, detail: String, badge: String?, size: Int64?, action: DockerAction?) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        if let badge { BadgeTag(text: badge) }
                    }
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.faintText).lineLimit(1)
                }
                Spacer()
                if let size { SizeText(bytes: size) }
                if let action {
                    Button("Remove") { model.pending = action }.buttonStyle(LinkButtonStyle()).disabled(model.running != nil)
                }
            }
            .padding(.vertical, 8)
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    private func confirm(_ action: DockerAction) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(action.title).font(.system(size: 15, weight: .semibold))
            Text(action.explanation).font(.system(size: 13)).foregroundStyle(Theme.mutedText)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sweep will run").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faintText)
                Text(action.command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
            }
            if let estimate = action.estimate, estimate > 0 {
                Text("Docker estimates about \(ByteFormat.string(estimate)) is freed inside its virtual disk. Docker Desktop returns that space to macOS over time.")
                    .font(.system(size: 12)).foregroundStyle(Theme.mutedText).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.pending = nil }.buttonStyle(OutlineButtonStyle(height: 32)).keyboardShortcut(.cancelAction)
                Button("Run") { Task { await model.run(action) } }.buttonStyle(PillButtonStyle(fill: Theme.critical))
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}
