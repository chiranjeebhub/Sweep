import XCTest
@testable import SweepCore

final class SweepCoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ path: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    func testFolderSizeIncludesNestedFiles() throws {
        _ = try makeFile("folder/a.bin", bytes: 10_000)
        _ = try makeFile("folder/nested/b.bin", bytes: 20_000)
        let size = FileSize.allocatedSize(of: root.appendingPathComponent("folder"))
        XCTAssertGreaterThanOrEqual(size, 30_000)
    }

    func testJunkScannerListsCachesLargestFirstAndSkipsProtected() throws {
        _ = try makeFile("Library/Caches/com.small.app/data", bytes: 5_000)
        _ = try makeFile("Library/Caches/com.big.app/data", bytes: 50_000)
        _ = try makeFile("Library/Caches/com.sweep.test/data", bytes: 80_000)
        let scanner = JunkScanner(home: root, systemLibrary: root.appendingPathComponent("System"),
                                  protectedNames: ["com.sweep.test"])
        let caches = scanner.scan(.userCaches)
        XCTAssertEqual(caches.items.map(\.name), ["com.big.app", "com.small.app"])
        XCTAssertGreaterThanOrEqual(caches.size, 55_000)
    }

    func testLargeFileScannerUsesThresholdAndKinds() throws {
        _ = try makeFile("Movies/clip.mov", bytes: 300_000)
        _ = try makeFile("Downloads/backup.zip", bytes: 200_000)
        _ = try makeFile("Downloads/notes.txt", bytes: 1_000)
        let scanner = LargeFileScanner(roots: [root.appendingPathComponent("Movies"), root.appendingPathComponent("Downloads")],
                                       threshold: 100_000)
        let files = scanner.scan()
        XCTAssertEqual(files.map(\.name), ["clip.mov", "backup.zip"])
        XCTAssertEqual(files.map(\.kind), [.video, .archive])
    }

    func testRemnantsFindSupportFilesByBundleIdentifier() throws {
        _ = try makeFile("Library/Application Support/com.example.Editor/state.json", bytes: 4_000)
        _ = try makeFile("Library/Caches/com.example.Editor/cache.db", bytes: 4_000)
        _ = try makeFile("Library/Preferences/com.example.Editor.plist", bytes: 100)
        _ = try makeFile("Library/Caches/com.other.App/cache.db", bytes: 4_000)
        let app = InstalledApp(url: root.appendingPathComponent("Editor.app"), name: "Editor",
                               bundleIdentifier: "com.example.Editor", version: "1.0", size: 0, lastUsed: nil)
        let remnants = AppScanner(applicationFolders: [], library: root.appendingPathComponent("Library")).remnants(of: app)
        XCTAssertEqual(Set(remnants.groups.map(\.title)), ["Supporting files", "Caches", "Preferences"])
        XCTAssertFalse(remnants.urls.contains { $0.path.contains("com.other.App") })
    }

    func testLeftoversSkipInstalledAndAppleIdentifiers() throws {
        _ = try makeFile("Library/Application Support/com.gone.App/data", bytes: 4_000)
        _ = try makeFile("Library/Application Support/com.still.Here/data", bytes: 4_000)
        _ = try makeFile("Library/Application Support/com.apple.Something/data", bytes: 4_000)
        _ = try makeFile("Library/Application Support/Some Folder/data", bytes: 4_000)
        let scanner = AppScanner(applicationFolders: [], library: root.appendingPathComponent("Library"))
        let leftovers = scanner.leftovers { $0 == "com.still.Here" }
        XCTAssertEqual(leftovers.map(\.bundleIdentifier), ["com.gone.App"])
    }

    func testTrasherReportsFreedSpace() throws {
        let file = try makeFile("trash-me.bin", bytes: 8_000)
        let result = Trasher().trash([file, root.appendingPathComponent("missing")])
        XCTAssertEqual(result.removedCount, 1)
        XCTAssertGreaterThanOrEqual(result.freedBytes, 8_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testUnusedApps() {
        let now = Date()
        let recent = InstalledApp(url: root, name: "A", bundleIdentifier: nil, version: nil, size: 0,
                                  lastUsed: now.addingTimeInterval(-86_400))
        let old = InstalledApp(url: root, name: "B", bundleIdentifier: nil, version: nil, size: 0,
                               lastUsed: now.addingTimeInterval(-200 * 86_400))
        XCTAssertFalse(recent.isUnused(now: now))
        XCTAssertTrue(old.isUnused(now: now))
    }

    func testSystemSnapshotIsSane() {
        let snapshot = SystemStats().sample()
        XCTAssertGreaterThan(snapshot.memoryTotal, 0)
        XCTAssertGreaterThan(snapshot.diskTotal, 0)
        XCTAssertTrue((0...1).contains(snapshot.cpuLoad))
    }
}
