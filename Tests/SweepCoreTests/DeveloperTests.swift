import XCTest
@testable import SweepCore

final class DeveloperTests: XCTestCase {
    private var home: String!

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        home = url.resolvingSymlinksInPath().path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    private func write(_ relative: String, _ text: String = "x", bytes: Int? = nil) throws {
        let url = URL(fileURLWithPath: home + "/" + relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let bytes { try Data(repeating: 1, count: bytes).write(to: url) } else { try text.write(to: url, atomically: true, encoding: .utf8) }
    }

    func testVersionComparison() {
        XCTAssertTrue(DeveloperAnalyzer.isNewer("1.10.0", than: "1.9.3"))
        XCTAssertFalse(DeveloperAnalyzer.isNewer("v18.0.0", than: "v20.1.0"))
        XCTAssertFalse(DeveloperAnalyzer.isNewer("2.0", than: "2.0.0"))
    }

    func testClaudeCodeOlderVersionsAreSuperseded() throws {
        try write(".local/share/claude/versions/2.0.1", bytes: 2_000_000)
        try write(".local/share/claude/versions/2.0.5", bytes: 2_000_000)
        try FileManager.default.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/.local/bin/claude", withDestinationPath: home + "/.local/share/claude/versions/2.0.5")
        try write(".claude/projects/-gone/a.jsonl", "{\"cwd\":\"\(home!)/gone\",\"type\":\"user\"}\n")
        let report = try XCTUnwrap(DeveloperAnalyzer(home: home).claudeCode())
        XCTAssertEqual(report.version, "2.0.5")
        XCTAssertEqual(report.items.filter { $0.badge == "Superseded" }.map(\.primaryPath), [home + "/.local/share/claude/versions/2.0.1"])
        XCTAssertTrue(report.details.contains { $0.badge == "Leftover" && $0.title == "gone" })
    }

    func testEditorFindsDeletedWorkspacesAndOldExtensions() throws {
        try write("Library/Application Support/Code/User/workspaceStorage/abc/workspace.json", "{\"folder\":\"file://\(home!)/deleted-project\"}")
        try write("Library/Application Support/Code/User/workspaceStorage/abc/state.vscdb", bytes: 1_500_000)
        try write(".vscode/extensions/ms-python.python-2024.1.0/package.json")
        try write(".vscode/extensions/ms-python.python-2024.10.0/package.json")
        let report = try XCTUnwrap(DeveloperAnalyzer(home: home).editor(id: "vscode", name: "VS Code", support: "Code", dotFolder: ".vscode", symbol: "x"))
        XCTAssertTrue(report.items.contains { $0.badge == "Leftover" && $0.primaryPath.hasSuffix("workspaceStorage/abc") })
        XCTAssertTrue(report.items.contains { $0.badge == "Superseded" && $0.primaryPath.hasSuffix("ms-python.python-2024.1.0") })
        XCTAssertFalse(report.items.contains { $0.primaryPath.hasSuffix("ms-python.python-2024.10.0") })
    }

    func testOllamaUnusedBlobsAreLeftovers() throws {
        try write(".ollama/models/manifests/registry.ollama.ai/library/tiny/latest",
                  "{\"layers\":[{\"digest\":\"sha256:aaa\",\"size\":10}],\"config\":{\"digest\":\"sha256:bbb\",\"size\":1}}")
        try write(".ollama/models/blobs/sha256-aaa", bytes: 10)
        try write(".ollama/models/blobs/sha256-bbb", bytes: 10)
        try write(".ollama/models/blobs/sha256-ccc", bytes: 2_000_000)
        let report = try XCTUnwrap(DeveloperAnalyzer(home: home).localModels())
        XCTAssertEqual(report.items.filter { $0.badge == "Leftover" }.map(\.primaryPath), [home + "/.ollama/models/blobs/sha256-ccc"])
        XCTAssertTrue(report.details.contains { $0.title == "tiny:latest" })
    }

    func testSecretScannerMasksCredentials() throws {
        let token = "ghp_" + String(repeating: "A1b2", count: 9)
        try write(".claude/projects/p/s.jsonl", "{\"cwd\":\"/Users/me/app\",\"text\":\"use \(token) please\"}\n")
        let findings = SecretScanner(home: home).scan()
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.kind, "GitHub token")
        XCTAssertEqual(findings.first?.project, "/Users/me/app")
        XCTAssertFalse(findings.first?.masked.contains(token) ?? true)
        XCTAssertTrue(findings.first?.masked.hasPrefix("ghp_") ?? false)
    }

    func testDockerSizesParseDecimalUnits() {
        XCTAssertEqual(DockerClient.bytes("1.5GB"), 1_500_000_000)
        XCTAssertEqual(DockerClient.bytes("512MB (40%)"), 512_000_000)
        XCTAssertEqual(DockerClient.bytes("12.5kB"), 12_500)
        XCTAssertEqual(DockerClient.bytes("0B"), 0)
        XCTAssertEqual(DockerClient.bytes(nil), 0)
    }

    func testDockerActionsNeverForce() {
        let snapshot = DockerSnapshot(status: .notInstalled, usage: [], containers: [], images: [], volumes: [], diskImage: nil)
        for action in [DockerAction.pruneContainers(snapshot), .pruneDanglingImages(snapshot), .pruneUnusedImages(snapshot), .pruneBuildCache(snapshot)] {
            XCTAssertFalse(action.arguments.contains { $0 == "-f" || $0 == "--force" })
            XCTAssertFalse(action.arguments.contains("volume"))
        }
    }
}
