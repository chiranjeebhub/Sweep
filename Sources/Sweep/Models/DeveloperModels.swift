import Combine
import SwiftUI
import SweepCore

/// The Developer screen: what each editor, agent, runtime and build tool keeps on disk.
@MainActor
final class DeveloperModel: ObservableObject {
    @Published private(set) var reports: [ToolReport] = []
    @Published private(set) var isAnalyzing = false
    @Published private(set) var analyzedAt: Date?
    @Published private(set) var secrets: [SecretFinding] = []
    @Published private(set) var isCheckingSecrets = false
    @Published private(set) var secretsCheckedAt: Date?
    @Published var expanded: Set<String> = []

    let storage: StorageModel
    let cleanup: CleanupModel
    private var analyzedScanDate: Date?
    private var subscription: AnyCancellable?

    init(storage: StorageModel, cleanup: CleanupModel) {
        self.storage = storage
        self.cleanup = cleanup
        // A new scan finds project folders the analyzers use, so look again when one arrives.
        subscription = storage.$result
            .compactMap { $0?.date }
            .removeDuplicates()
            .sink { [weak self] _ in Task { await self?.analyze() } }
    }

    var totalSize: Int64 { reports.filter { $0.id != "leftovers" }.reduce(0) { $0 + $1.totalSize } }
    var reviewSize: Int64 { reports.filter { $0.id != "leftovers" }.reduce(0) { $0 + $1.reviewSize } }
    var reviewCount: Int { reports.filter { $0.id != "leftovers" }.reduce(0) { $0 + $1.reviewCount } }
    var leftoverCount: Int { reports.first { $0.id == "leftovers" }?.details.count ?? 0 }

    func analyzeIfNeeded() async {
        if analyzedAt == nil || analyzedScanDate != storage.result?.date { await analyze() }
    }

    func analyze() async {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        let scan = storage.result?.root
        analyzedScanDate = storage.result?.date
        let found = await background { DeveloperAnalyzer(scan: scan).analyzeAll() }
        reports = found
        analyzedAt = Date()
        storage.setExtraRecommendations(found.filter { $0.id != "leftovers" }.flatMap(\.items))
        isAnalyzing = false
    }

    func checkSecrets() async {
        guard !isCheckingSecrets else { return }
        isCheckingSecrets = true
        secrets = await background { SecretScanner().scan() }
        secretsCheckedAt = Date()
        isCheckingSecrets = false
    }

    /// Opens Cleanup with this tool's suggestions selected.
    func review(_ report: ToolReport, app: AppModel) {
        let ids: [String]
        if report.id == "leftovers" {
            let paths = Set(report.details.compactMap(\.path))
            ids = storage.allRecommendations.filter { paths.contains($0.primaryPath) }.map(\.id)
        } else {
            ids = report.items.filter { $0.tier != .keep && $0.isActionable }.map(\.id)
        }
        cleanup.filter = .all
        cleanup.selectOnly(ids)
        app.selection = .cleanup
    }

    func toggle(_ report: ToolReport) {
        if expanded.contains(report.id) { expanded.remove(report.id) } else { expanded.insert(report.id) }
    }
}
