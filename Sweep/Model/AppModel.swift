import SwiftUI
import AppKit

struct CleanReport: Equatable {
    var results: [CleanResult]
    var volumeName: String
    /// What the findings added up to.
    var expectedBytes: Int64
    /// How much the drive's free space really grew. Files that share space on disk make this smaller than expected.
    var freedBytes: Int64
    var freeAfter: Int64
    /// Bytes moved to the Trash. That space only comes back once the Trash is emptied.
    var trashedBytes: Int64

    var failures: [CleanResult] { results.filter { !$0.outcome.isSuccess } }
}

/// Everything the Clean Up screens show, and every action they can take.
@Observable
final class AppModel {
    enum Mode: String, CaseIterable, Identifiable {
        case cleanUp = "Clean Up"
        case explore = "Explore"
        var id: String { rawValue }
    }

    enum ScanPhase: Equatable {
        case idle
        case scanning(done: Int, total: Int)
        case finished
    }

    enum CleanPhase: Equatable {
        case idle
        case confirming
        case cleaning(done: Int, total: Int, current: String)
        case finished
    }

    // MARK: Drives

    private(set) var volumes: [Volume] = []
    var selectedVolumeID: Volume.ID? {
        didSet { if oldValue != selectedVolumeID { selectedVolumeChanged() } }
    }
    var mode: Mode = .cleanUp {
        didSet { if mode == .explore { openExplorer() } }
    }

    // MARK: Scan

    private(set) var scanPhase: ScanPhase = .idle
    private(set) var findings: [Finding] = [] {
        didSet { refreshVisible() }
    }
    private(set) var needsAccess: [String] = []
    private(set) var hasFullDiskAccess = true
    var dismissedAccessBanner = false

    // MARK: What the selected drive shows

    private(set) var safeFindings: [Finding] = []
    private(set) var reviewFindings: [Finding] = []
    private(set) var safeBytes: Int64 = 0
    private(set) var reviewBytes: Int64 = 0
    var focusedID: Finding.ID?

    // MARK: Selection

    private(set) var checked: Set<Finding.ID> = [] {
        didSet { refreshSelection() }
    }
    private(set) var checkedBytes: Int64 = 0
    private(set) var checkedCount = 0
    private(set) var checkedReviewCount = 0

    // MARK: Cleaning

    private(set) var cleanPhase: CleanPhase = .idle
    private(set) var report: CleanReport?
    var reviewMethod: CleanMethod = .moveToTrash

    let explorer = ExplorerModel()

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var cleanTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var userChangedSelection = false
    /// True for preview models, which must never scan the real disk.
    @ObservationIgnored private var usesSampleData = false

    // MARK: Derived

    var selectedVolume: Volume? { volumes.first { $0.id == selectedVolumeID } }
    var focusedFinding: Finding? { focusedID.flatMap { id in findings.first { $0.id == id } } }
    var isScanning: Bool { if case .scanning = scanPhase { true } else { false } }

    var checkedFindings: [Finding] {
        findings.filter { checked.contains($0.id) && $0.volumeID == selectedVolumeID && $0.canClean }
    }

    var isShowingCleanSheet: Bool {
        get { cleanPhase != .idle }
        set { if !newValue { dismissCleanSheet() } }
    }

    subscript(checked id: Finding.ID) -> Bool {
        get { checked.contains(id) }
        set { setChecked(id, newValue) }
    }

    // MARK: Starting up

    func start() {
        guard !started else { return }
        started = true
        refreshVolumes()
        selectedVolumeID = volumes.first?.id
        rescan()
    }

    func refreshVolumes() {
        let latest = VolumeProvider.volumes()
        let arrived = Set(latest.map(\.id)).subtracting(volumes.map(\.id))
        volumes = latest
        if selectedVolume == nil { selectedVolumeID = latest.first?.id }
        if started, !arrived.isEmpty, !isScanning { rescan() }
    }

    // MARK: Scanning

    func rescan() {
        scanTask?.cancel()
        volumes = VolumeProvider.volumes()
        hasFullDiskAccess = Permissions.hasFullDiskAccess()
        needsAccess = []
        let environment = makeEnvironment()
        let isFirstScan = findings.isEmpty
        scanPhase = .scanning(done: 0, total: 0)

        scanTask = Task {
            var staged: [Finding] = []
            for await event in CleanupScanner.scan(environment: environment) {
                switch event {
                case .planned(let total):
                    // More places can turn up while the scan runs; keep the count of what's done.
                    if case .scanning(let done, _) = scanPhase { scanPhase = .scanning(done: done, total: total) }
                case .progress(let done, let total):
                    scanPhase = .scanning(done: done, total: total)
                case .found(let finding):
                    staged.append(finding)
                    if isFirstScan { reveal(finding) }
                case .needsAccess(let name):
                    needsAccess.append(name)
                }
            }
            if Task.isCancelled { return }
            animated { findings = staged }
            let known = Set(staged.map(\.id))
            if userChangedSelection {
                checked.formIntersection(known)
            } else {
                checked = Set(staged.filter { $0.safety == .safe && $0.canClean }.map(\.id))
            }
            scanPhase = .finished
        }
    }

    /// While the very first scan runs, results appear one by one so the screen feels alive.
    private func reveal(_ finding: Finding) {
        animated {
            findings.append(finding)
            if finding.safety == .safe, finding.canClean, !userChangedSelection { checked.insert(finding.id) }
        }
    }

    private func makeEnvironment() -> ScanEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cacheFolder = home.appendingPathComponent("Library/Caches").path
        let cacheNames = ((try? FileManager.default.contentsOfDirectory(atPath: cacheFolder)) ?? [])
            .map { $0.hasSuffix(".ShipIt") ? String($0.dropLast(".ShipIt".count)) : $0 }

        var roots = ["Development", "Developer", "Projects", "Code", "src", "Sites", "Work"]
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        roots += volumes.filter { !$0.isInternal }.map(\.mountURL)

        return ScanEnvironment(
            home: home,
            volumes: volumes,
            derivedDataFolders: XcodePreferences.derivedDataFolders(home: home),
            runningApps: RunningApps.snapshot(),
            appNames: RunningApps.appNames(forBundleIDs: cacheNames),
            projectRoots: roots
        )
    }

    // MARK: Selection

    func setChecked(_ id: Finding.ID, _ isOn: Bool) {
        userChangedSelection = true
        if isOn { checked.insert(id) } else { checked.remove(id) }
    }

    func setChecked(_ items: [Finding], to isOn: Bool) {
        userChangedSelection = true
        let ids = items.filter(\.canClean).map(\.id)
        if isOn { checked.formUnion(ids) } else { checked.subtract(ids) }
    }

    func checkedState(of items: [Finding]) -> Bool {
        let cleanable = items.filter(\.canClean)
        return !cleanable.isEmpty && cleanable.allSatisfy { checked.contains($0.id) }
    }

    // MARK: Cleaning

    func prepareCleanup() {
        guard checkedCount > 0, cleanPhase == .idle else { return }
        cleanPhase = .confirming
    }

    func confirmCleanup() {
        guard cleanPhase == .confirming, let volume = selectedVolume else { return }
        let method = reviewMethod
        let items = checkedFindings.map { CleanItem(finding: $0, method: $0.safety == .review ? method : .deletePermanently) }
        guard !items.isEmpty else { cleanPhase = .idle; return }

        let expected = items.reduce(0) { $0 + $1.finding.bytes }
        let freeBefore = DiskSpace.stats(at: volume.scanRoot.path)?.free ?? volume.freeBytes
        cleanPhase = .cleaning(done: 0, total: items.count, current: items[0].finding.title)

        cleanTask = Task {
            var results: [CleanResult] = []
            for await event in Cleaner.run(items: items) {
                switch event {
                case .started:
                    break
                case .began(let title, let index):
                    cleanPhase = .cleaning(done: index, total: items.count, current: title)
                case .finished(let result):
                    results.append(result)
                    if result.outcome.isSuccess {
                        animated {
                            findings.removeAll { $0.id == result.id }
                            checked.remove(result.id)
                        }
                    }
                case .done:
                    break
                }
            }
            volumes = VolumeProvider.volumes()
            let freeAfter = DiskSpace.stats(at: volume.scanRoot.path)?.free ?? freeBefore
            report = CleanReport(
                results: results,
                volumeName: volume.name,
                expectedBytes: expected,
                freedBytes: max(0, freeAfter - freeBefore),
                freeAfter: freeAfter,
                trashedBytes: results.filter { $0.outcome == .trashed }.reduce(0) { $0 + $1.bytes }
            )
            cleanPhase = .finished
        }
    }

    func stopCleaning() {
        cleanTask?.cancel()
    }

    func dismissCleanSheet() {
        switch cleanPhase {
        case .confirming, .finished:
            cleanPhase = .idle
            report = nil
        case .idle, .cleaning:
            break
        }
    }

    // MARK: Permissions

    func recheckPermissions() {
        hasFullDiskAccess = Permissions.hasFullDiskAccess()
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Bookkeeping

    private func selectedVolumeChanged() {
        refreshVisible()
        if mode == .explore { openExplorer() }
    }

    private func openExplorer() {
        guard !usesSampleData, let volume = selectedVolume else { return }
        explorer.open(volume)
    }

    private func refreshVisible() {
        let onThisDrive = findings.filter { $0.volumeID == selectedVolumeID }
        safeFindings = onThisDrive.filter { $0.safety == .safe }.sorted { $0.bytes > $1.bytes }
        reviewFindings = onThisDrive.filter { $0.safety == .review }.sorted { $0.bytes > $1.bytes }
        safeBytes = safeFindings.reduce(0) { $0 + $1.bytes }
        reviewBytes = reviewFindings.reduce(0) { $0 + $1.bytes }
        if let focusedID, !onThisDrive.contains(where: { $0.id == focusedID }) { self.focusedID = nil }
        explorer.setContext(findings: findings)
        refreshSelection()
    }

    private func refreshSelection() {
        let picked = checkedFindings
        checkedBytes = picked.reduce(0) { $0 + $1.bytes }
        checkedCount = picked.count
        checkedReviewCount = picked.filter { $0.safety == .review }.count
    }

    /// Runs a state change with a smooth animation, or none when the person asked for less motion.
    private func animated(_ change: () -> Void) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            change()
        } else {
            withAnimation(.smooth(duration: 0.32), change)
        }
    }
}

#if DEBUG
// MARK: - Sample data for previews

extension AppModel {
    /// A model filled with believable data so previews and screenshots don't need a real scan.
    static func sample(cleanPhase: CleanPhase = .idle, report: CleanReport? = nil, mode: Mode = .cleanUp) -> AppModel {
        let model = AppModel()
        model.started = true
        model.usesSampleData = true
        model.volumes = [
            Volume(id: "/", name: "Macintosh HD", mountURL: URL(fileURLWithPath: "/"), scanRoot: URL(fileURLWithPath: "/System/Volumes/Data"),
                   totalBytes: 494_000_000_000, freeBytes: 61_000_000_000, isInternal: true),
            Volume(id: "/Volumes/Backup", name: "Backup Drive", mountURL: URL(fileURLWithPath: "/Volumes/Backup"),
                   scanRoot: URL(fileURLWithPath: "/Volumes/Backup"), totalBytes: 500_000_000_000, freeBytes: 18_000_000_000, isInternal: false),
        ]
        model.selectedVolumeID = "/"
        model.findings = SampleFindings.all
        model.scanPhase = .finished
        model.checked = Set(SampleFindings.all.filter { $0.safety == .safe && $0.canClean }.map(\.id))
        model.focusedID = SampleFindings.all.first?.id
        model.cleanPhase = cleanPhase
        model.report = report
        model.mode = mode
        return model
    }
}

enum SampleFindings {
    private static func make(
        _ title: String, _ subtitle: String, _ category: Category, _ safety: Safety, gb: Double, files: Int,
        path: String, what: String, consequence: String, blocked: [Blocker] = [], inside: [BreakdownItem] = []
    ) -> Finding {
        Finding(
            id: "sample|\(path)", ruleID: "sample", title: title, subtitle: subtitle, what: what, consequence: consequence,
            category: category, safety: safety, url: URL(fileURLWithPath: path), volumeID: "/", bytes: Int64(gb * 1_000_000_000),
            fileCount: files, lastChanged: .now.addingTimeInterval(-86_400 * 12), action: .deleteItem,
            guardRoot: URL(fileURLWithPath: PathUtil.parent(of: path)), leafNames: nil, leafSuffix: nil, directChildOnly: true,
            blockedBy: blocked, breakdown: inside
        )
    }

    static let all: [Finding] = [
        make("Recipe Book", "Build output · project in Development", .xcode, .safe, gb: 8.4, files: 113_757,
             path: "/Users/demo/Library/Developer/Xcode/DerivedData/Recipe_Book-abc",
             what: "Build output Xcode keeps for each project: compiled code, search indexes and test results.",
             consequence: "The next build of that project starts from scratch, so it takes longer once.",
             inside: [BreakdownItem(id: "1", title: "Index.noindex", detail: nil, bytes: 4_100_000_000),
                      BreakdownItem(id: "2", title: "Build", detail: nil, bytes: 3_900_000_000),
                      BreakdownItem(id: "3", title: "SourcePackages", detail: nil, bytes: 400_000_000)]),
        make("Weather App", "Build output · project in Development", .xcode, .safe, gb: 5.2, files: 20_896,
             path: "/Users/demo/Library/Developer/Xcode/DerivedData/Weather_App-abc",
             what: "Build output Xcode keeps for each project: compiled code, search indexes and test results.",
             consequence: "The next build of that project starts from scratch, so it takes longer once.",
             blocked: [Blocker(appName: "Xcode", message: "Quit Xcode first")]),
        make("Example Browser", "App cache · Last changed 2 minutes ago", .appCaches, .safe, gb: 1.6, files: 4_210,
             path: "/Users/demo/Library/Caches/com.example.browser",
             what: "Temporary files an app saved so it can run faster.",
             consequence: "The app makes them again. It can feel slower the first time you open it."),
        make("Swift Package Manager cache", "Package cache · Last changed 3 hours ago", .packages, .safe, gb: 1.0, files: 2_005,
             path: "/Users/demo/Library/Caches/org.swift.swiftpm",
             what: "Package sources and manifests Swift downloaded.", consequence: "The next package resolve is slower once."),
        make("web-app", "node_modules · Last changed 4 months ago", .projects, .safe, gb: 0.62, files: 38_220,
             path: "/Users/demo/Development/web-app/node_modules",
             what: "JavaScript packages for one project.", consequence: "Run npm install in that project to bring them back."),
        make("Simulators", "Installed apps and their data", .simulators, .review, gb: 4.8, files: 61_400,
             path: "/Users/demo/Library/Developer/CoreSimulator/Devices",
             what: "Every iOS, watchOS and visionOS simulator, with the apps and data installed in each.",
             consequence: "Apps and data inside the simulators are erased. The simulators themselves stay.",
             inside: [BreakdownItem(id: "a", title: "iPhone 17 Pro", detail: "iOS 27.2", bytes: 2_400_000_000),
                      BreakdownItem(id: "b", title: "Apple Vision Pro", detail: "xrOS 27.2", bytes: 1_600_000_000),
                      BreakdownItem(id: "c", title: "iPad Pro 13-inch", detail: "iOS 27.2", bytes: 800_000_000)]),
        make("ui-tests-run.xcresult", "Xcode test results · Last changed 1 day ago", .projects, .review, gb: 0.11, files: 1_204,
             path: "/Users/demo/Development/verification/ui-tests.xcresult",
             what: "Saved results from an Xcode test run, with logs and screenshots.", consequence: "Gone for good. Keep any you still want to look at."),
    ]
}
#endif
