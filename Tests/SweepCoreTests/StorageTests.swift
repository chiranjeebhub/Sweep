import XCTest
@testable import SweepCore

final class StorageTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // Resolve /var -> /private/var so paths compare equal to what the scanner reports.
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func makeFile(_ path: String, bytes: Int, byte: UInt8 = 1) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: byte, count: bytes).write(to: url)
        return url
    }

    func testScannerAddsUpFoldersAndCountsHardLinksOnce() throws {
        let file = try makeFile("a/b/c/file.bin", bytes: 200_000)
        try makeFile("a/other.bin", bytes: 100_000)
        try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("a/b/link.bin"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("a/symlink"), withDestinationURL: root.appendingPathComponent("a/b"))

        let result = DiskScanner(root: root).scan()
        let a = try XCTUnwrap(result.root.child(named: "a"))
        let b = try XCTUnwrap(a.child(named: "b"))
        XCTAssertGreaterThanOrEqual(b.size, 200_000)
        XCTAssertLessThan(b.size, 400_000, "the hard link must not be counted twice")
        XCTAssertEqual(a.size, a.ownSize + b.size)
        XCTAssertEqual(result.root.size, a.size)
        XCTAssertNil(a.child(named: "symlink"), "symbolic links are never followed")
        XCTAssertNotNil(result.root.node(at: b.path + "/c"))
    }

    func testClassifierMatchesRulesAndInheritsFromLeaves() throws {
        let home = root.path
        try makeFile("Library/Caches/com.example.app/cache.db", bytes: 10)
        try makeFile("code/web/package.json", bytes: 10)
        try makeFile("code/web/node_modules/left-pad/index.js", bytes: 10)
        try makeFile("code/rusty/Cargo.toml", bytes: 10)
        try makeFile("code/rusty/target/debug/app", bytes: 10)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("code/web/.git"), withIntermediateDirectories: true)

        let result = DiskScanner(root: root).scan()
        Classifier(home: home).classify(result.root)
        func rule(_ path: String) -> String? { result.root.node(at: home + "/" + path)?.classification?.rule.id }

        XCTAssertEqual(rule("Library/Caches"), "library.caches")
        XCTAssertEqual(rule("Library/Caches/com.example.app"), "library.caches", "inherited from the container")
        XCTAssertEqual(rule("code/web/node_modules"), "node.modules")
        XCTAssertEqual(rule("code/web/node_modules/left-pad"), "node.modules", "a leaf owns everything inside")
        XCTAssertEqual(rule("code/rusty/target"), "rust.target")
        XCTAssertEqual(rule("code/web"), "project.code")
        XCTAssertNil(result.root.node(at: home + "/code/web/node_modules/left-pad")?.ownRule)
    }

    func testRecommendationsExpandChildrenAndRespectMinimumSize() throws {
        let home = root.path
        try makeFile("Library/Caches/com.big.app/blob", bytes: 60_000_000)
        try makeFile("Library/Caches/com.small.app/blob", bytes: 1_000)
        let result = DiskScanner(root: root).scan()
        Classifier(home: home).classify(result.root)
        let items = RecommendationEngine.recommendations(for: result.root)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.paths, [home + "/Library/Caches/com.big.app"])
        XCTAssertEqual(items.first?.tier, .likelySafe)
        XCTAssertTrue(items.first?.allowsPermanentDelete == true)
    }

    func testSafetyGateRefusesProtectedLinkedAndOutsidePaths() throws {
        let home = root.path
        try makeFile("Library/Caches/com.example/x", bytes: 10)
        try makeFile("real/thing/x", bytes: 10)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: root.appendingPathComponent("real"))

        XCTAssertNil(SafetyGate.problem(with: home + "/Library/Caches/com.example", home: home))
        XCTAssertNotNil(SafetyGate.problem(with: home + "/Library/Caches", home: home), "protected folder")
        XCTAssertNotNil(SafetyGate.problem(with: home, home: home))
        XCTAssertNotNil(SafetyGate.problem(with: "/etc/hosts", home: home), "outside home")
        XCTAssertNotNil(SafetyGate.problem(with: home + "/linked/thing", home: home), "through a symlink")
        XCTAssertNotNil(SafetyGate.problem(with: home + "/real/../real/thing", home: home), "not standardized")
        XCTAssertNotNil(SafetyGate.problem(with: home + "/.ssh/id_rsa", home: home))
        XCTAssertNotNil(SafetyGate.problem(with: home + "/missing", home: home))
    }

    func testCleanupPlanAndExecutorDeleteOnlyCheckedPaths() throws {
        let home = root.path
        try makeFile("Library/Caches/com.example/x", bytes: 5_000)
        let item = Recommendation(id: "t", title: "Test", explanation: "", paths: [home + "/Library/Caches/com.example", home + "/Library/Caches"],
                                  size: 5_000, tier: .likelySafe, category: .cache, confidence: .high, safeBecause: "", risks: "",
                                  action: "", methods: [.trash, .delete], ruleID: "test")
        let plan = CleanupPlan(recommendations: [item], home: home)
        XCTAssertEqual(plan.validItems.map(\.path), [home + "/Library/Caches/com.example"])
        XCTAssertTrue(plan.allowsPermanentDelete)
        let results = CleanupExecutor(method: .delete, home: home).run(plan)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/Library/Caches/com.example"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/Library/Caches"))
    }

    func testDuplicateFinderGroupsIdenticalFilesAndSkipsDependencies() throws {
        try makeFile("docs/a.bin", bytes: 2_000_000, byte: 7)
        try makeFile("docs/copy/a.bin", bytes: 2_000_000, byte: 7)
        try makeFile("docs/different.bin", bytes: 2_000_000, byte: 8)
        try makeFile("proj/node_modules/a.bin", bytes: 2_000_000, byte: 7)
        let groups = DuplicateFinder(roots: [root], minimumSize: 1_000_000).find()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].files.count, 2)
        XCTAssertFalse(groups[0].files.contains { $0.path.contains("node_modules") })
    }

    func testScanStoreRoundTripKeepsTotals() throws {
        try makeFile("a/b/file", bytes: 300_000)
        try makeFile("a/tiny/deep/er/file", bytes: 10)
        let result = DiskScanner(root: root).scan()
        let file = root.appendingPathComponent("saved-scan.json")
        ScanStore.save(result, to: file)
        let loaded = try XCTUnwrap(ScanStore.load(from: file))
        XCTAssertEqual(loaded.root.size, result.root.size)
        XCTAssertEqual(loaded.root.child(named: "a")?.size, result.root.child(named: "a")?.size)
    }
}
