import AppKit
import SwiftUI
import SweepCore

/// The Docker screen: what Docker's storage holds, and its own prune commands, each previewed before it runs.
@MainActor
final class DockerModel: ObservableObject {
    @Published private(set) var snapshot: DockerSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var running: String?
    @Published var pending: DockerAction?
    @Published var message: (text: String, succeeded: Bool)?

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        snapshot = await background { DockerClient().snapshot() }
        isLoading = false
    }

    func run(_ action: DockerAction) async {
        pending = nil
        running = action.id
        let result = await background { DockerClient().perform(action) }
        running = nil
        let summary = result.output.split(separator: "\n").last.map(String.init) ?? ""
        message = (result.succeeded ? "Done: \(action.command). \(summary)" : "\(action.command) failed: \(summary)", result.succeeded)
        await refresh()
    }

    func openDocker() {
        let engine: String
        if case .notRunning(let name) = snapshot?.status { engine = name } else { engine = "Docker Desktop" }
        let app = engine == "OrbStack" ? "/Applications/OrbStack.app" : "/Applications/Docker.app"
        NSWorkspace.shared.open(URL(fileURLWithPath: app))
    }
}
