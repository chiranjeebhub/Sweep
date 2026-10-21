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

    func testRemnantsMatchNameWithoutSpacesCrashReportsAndSystemFiles() throws {
        _ = try makeFile("Library/Caches/BucketBrowser/QuickLook/thumb.db", bytes: 4_000)
        _ = try makeFile("Library/Logs/DiagnosticReports/BucketBrowser-2026-10-21-080101.ips", bytes: 1_000)
        _ = try makeFile("Library/Logs/DiagnosticReports/Other-2026-10-21-080101.ips", bytes: 1_000)
        _ = try makeFile("Library/Cookies/com.bucketbrowser.app.binarycookies", bytes: 100)
        _ = try makeFile("Library/Preferences/com.bucketbrowser.screenshots.plist", bytes: 100)
        _ = try makeFile("System/LaunchDaemons/com.bucketbrowser.app.helper.plist", bytes: 100)
        _ = try makeFile("System/PrivilegedHelperTools/com.bucketbrowser.app.helper", bytes: 1_000)
        let app = InstalledApp(url: root.appendingPathComponent("Bucket Browser.app"), name: "Bucket Browser",
                               bundleIdentifier: "com.bucketbrowser.app", version: "1.0", size: 0, lastUsed: nil)
        let scanner = AppScanner(applicationFolders: [], library: root.appendingPathComponent("Library"),
                                 systemLibrary: root.appendingPathComponent("System"))
        let remnants = scanner.remnants(of: app)
        XCTAssertEqual(Set(remnants.groups.map(\.title)), ["Supporting files", "Caches", "Logs", "System files"])
        XCTAssertEqual(remnants.groups.first { $0.title == "System files" }?.urls.count, 2)
        XCTAssertFalse(remnants.urls.contains { $0.lastPathComponent.hasPrefix("Other-") })
        XCTAssertFalse(remnants.urls.contains { $0.lastPathComponent.contains("screenshots") })
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

    func testVersionCompareTreatsPartsAsNumbers() {
        XCTAssertTrue(VersionCompare.isNewer("1.10", than: "1.9"))
        XCTAssertTrue(VersionCompare.isNewer("2.0.1", than: "2.0"))
        XCTAssertFalse(VersionCompare.isNewer("1.0.0", than: "1.0"))
        XCTAssertFalse(VersionCompare.isNewer("3.2", than: "3.10"))
    }

    func testAppcastParserSkipsDeltasAndReadsVersions() throws {
        let feed = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
          <item>
            <sparkle:version>120</sparkle:version>
            <sparkle:shortVersionString>1.2</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <enclosure url="https://example.com/App-1.2.zip" length="10" type="application/octet-stream"/>
            <sparkle:deltas>
              <enclosure url="https://example.com/delta.delta" sparkle:version="999" sparkle:deltaFrom="110"/>
            </sparkle:deltas>
          </item>
          <item>
            <enclosure url="https://example.com/App-1.3b.zip" sparkle:version="130" sparkle:shortVersionString="1.3b"/>
            <sparkle:channel>beta</sparkle:channel>
          </item>
        </channel></rss>
        """
        let items = AppcastParser.parse(Data(feed.utf8))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].version, "120")
        XCTAssertEqual(items[0].shortVersion, "1.2")
        XCTAssertEqual(items[0].minimumSystemVersion, "13.0")
        XCTAssertEqual(items[0].downloadURL?.lastPathComponent, "App-1.2.zip")
        XCTAssertNil(items[0].channel)
        XCTAssertEqual(items[1].channel, "beta")
        XCTAssertEqual(items[1].version, "130")
    }

    func testUpdateInstallerOnlyHandlesArchives() {
        XCTAssertTrue(UpdateInstaller.canInstall(URL(string: "https://example.com/App.zip")!))
        XCTAssertTrue(UpdateInstaller.canInstall(URL(string: "https://example.com/App.dmg")!))
        XCTAssertTrue(UpdateInstaller.canInstall(URL(string: "https://example.com/App.tar.xz")!))
        XCTAssertFalse(UpdateInstaller.canInstall(URL(string: "https://example.com/App.pkg")!))
    }

    func testKnownAdwareMatchingIgnoresCaseAndPunctuation() {
        XCTAssertEqual(MalwareScanner.knownFamily(in: "com.Search-Baron.agent"), "Search Baron")
        XCTAssertEqual(MalwareScanner.knownFamily(in: "Advanced Mac Cleaner.app"), "Advanced Mac Cleaner")
        XCTAssertNil(MalwareScanner.knownFamily(in: "com.google.keystone.agent"))
    }

    func testMalwareScannerFlagsAdwareAndHiddenPrograms() throws {
        let agents = root.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let hidden = try makeFile(".hidden/runner", bytes: 10)
        let legit = try makeFile("bin/tool", bytes: 10)
        func agent(_ label: String, program: String) throws {
            let plist: NSDictionary = ["Label": label, "ProgramArguments": [program]]
            try plist.write(to: agents.appendingPathComponent("\(label).plist"))
        }
        try agent("com.pcvark.helper", program: "/nonexistent/helper")
        try agent("com.example.sneaky", program: hidden.path)
        try agent("com.example.fine", program: legit.path)
        try agent("com.example.gone", program: "/nonexistent/gone")

        let scanner = MalwareScanner(home: root, systemLibrary: root.appendingPathComponent("System"),
                                     applicationFolders: [])
        let threats = Dictionary(uniqueKeysWithValues: scanner.scan().map { ($0.name, $0.severity) })
        XCTAssertEqual(threats["com.pcvark.helper"], .high)
        XCTAssertEqual(threats["com.example.sneaky"], .medium)
        XCTAssertEqual(threats["com.example.gone"], .low)
        XCTAssertNil(threats["com.example.fine"])
    }

    func testMaintenanceRunnerReadsEachTaskStatus() {
        let tasks = MaintenanceTask.all.filter { ["scripts", "spotlight"].contains($0.id) }
        let results = MaintenanceRunner.parse("sweep-result:scripts:0\rsweep-result:spotlight:1\r", tasks: tasks)
        XCTAssertEqual(results["scripts"], .done)
        XCTAssertEqual(results["spotlight"], .failed)
    }
}
