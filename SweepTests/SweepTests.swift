import Foundation
import Testing
@testable import Sweep

// MARK: - Test fixtures

/// A throwaway folder that cleans up after itself. Paths are canonical so they match what the guard sees.
private final class Sandbox {
    let root: URL

    init() throws {
        let base = URL(fileURLWithPath: PathUtil.realPath(NSTemporaryDirectory()) ?? NSTemporaryDirectory())
        root = base.appendingPathComponent("sweep-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        _ = try? run("/bin/chmod", ["-R", "u+w", root.path])
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func folder(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ relative: String, bytes: Int = 4096) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    func exists(_ relative: String) -> Bool {
        var info = stat()
        return lstat(root.appendingPathComponent(relative).path, &info) == 0
    }

    /// A guard whose "home" is inside the sandbox, with no mounted volumes in the way.
    func guardrail() -> DeletionGuard {
        DeletionGuard(protected: ProtectedPaths.entries(home: root.appendingPathComponent("home").path), volumeRoots: [])
    }

    var home: URL { root.appendingPathComponent("home") }
}

private func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

private func finding(
    at url: URL, root: URL, action: CleanAction = .deleteItem, safety: Safety = .safe,
    leafNames: Set<String>? = nil, leafSuffix: String? = nil, directChildOnly: Bool = false, blockedBy: [Blocker] = []
) -> Finding {
    Finding(
        id: "test|\(url.path)", ruleID: "test", title: url.lastPathComponent, subtitle: "", what: "", consequence: "",
        category: .projects, safety: safety, url: url, volumeID: "/", bytes: 0, fileCount: 0, lastChanged: nil,
        action: action, guardRoot: root, leafNames: leafNames, leafSuffix: leafSuffix, directChildOnly: directChildOnly,
        blockedBy: blockedBy, breakdown: []
    )
}

// MARK: - Deletion guard

struct DeletionGuardTests {
    @Test func acceptsADirectChildInsideItsFolder() throws {
        let sandbox = try Sandbox()
        let derived = try sandbox.folder("DerivedData")
        let project = try sandbox.folder("DerivedData/App-abc")
        let path = try sandbox.guardrail().validate(url: project, root: derived, directChildOnly: true)
        #expect(path == PathUtil.canonical(project.path))
    }

    @Test func refusesAnythingOutsideItsFolder() throws {
        let sandbox = try Sandbox()
        let allowed = try sandbox.folder("allowed")
        let elsewhere = try sandbox.folder("elsewhere/thing")
        #expect(throws: GuardViolation.outsideAllowedFolder) {
            try sandbox.guardrail().validate(url: elsewhere, root: allowed)
        }
    }

    @Test func refusesTheFolderItselfUnlessOnlyEmptyingIt() throws {
        let sandbox = try Sandbox()
        let folder = try sandbox.folder("cache")
        #expect(throws: GuardViolation.outsideAllowedFolder) {
            try sandbox.guardrail().validate(url: folder, root: folder)
        }
        #expect((try? sandbox.guardrail().validate(url: folder, root: folder, contents: true)) != nil)
    }

    @Test func refusesGrandchildrenWhenOnlyDirectChildrenAreAllowed() throws {
        let sandbox = try Sandbox()
        let root = try sandbox.folder("root")
        let deep = try sandbox.folder("root/a/b")
        #expect(throws: GuardViolation.notDirectChild) {
            try sandbox.guardrail().validate(url: deep, root: root, directChildOnly: true)
        }
    }

    @Test func refusesTheWrongName() throws {
        let sandbox = try Sandbox()
        let root = try sandbox.folder("projects")
        let src = try sandbox.folder("projects/app/src")
        #expect(throws: GuardViolation.unexpectedName) {
            try sandbox.guardrail().validate(url: src, root: root, leafNames: ["node_modules"])
        }
        #expect(throws: GuardViolation.unexpectedName) {
            try sandbox.guardrail().validate(url: src, root: root, leafSuffix: ".xcresult")
        }
        let modules = try sandbox.folder("projects/app/node_modules")
        #expect((try? sandbox.guardrail().validate(url: modules, root: root, leafNames: ["node_modules"])) != nil)
    }

    @Test func refusesProtectedFoldersAndEverythingInsideThem() throws {
        let sandbox = try Sandbox()
        let history = try sandbox.folder("home/.claude/projects/some-session")
        let root = sandbox.home
        #expect(throws: GuardViolation.protected("Claude Code conversation history")) {
            try sandbox.guardrail().validate(url: history, root: root)
        }
        #expect(throws: GuardViolation.protected("Claude Code conversation history")) {
            try sandbox.guardrail().validate(url: history.deletingLastPathComponent(), root: root)
        }
    }

    @Test func refusesAFolderThatContainsSomethingProtected() throws {
        let sandbox = try Sandbox()
        try sandbox.folder("home/.codex/sessions")
        let parent = sandbox.home.appendingPathComponent(".codex")
        #expect(throws: GuardViolation.protected("Codex conversation history")) {
            try sandbox.guardrail().validate(url: parent, root: parent, contents: true)
        }
    }

    @Test func protectsFilesByNamePrefix() throws {
        let sandbox = try Sandbox()
        let support = try sandbox.folder("home/Library/Application Support/Claude")
        let vm = try sandbox.folder("home/Library/Application Support/Claude/claude-code-vm")
        let cache = try sandbox.folder("home/Library/Application Support/Claude/Cache")
        #expect(throws: GuardViolation.protected("Claude Code session state")) {
            try sandbox.guardrail().validate(url: vm, root: support, directChildOnly: true)
        }
        #expect((try? sandbox.guardrail().validate(url: cache, root: support, directChildOnly: true)) != nil)
    }

    @Test func refusesAGitRepository() throws {
        let sandbox = try Sandbox()
        let root = try sandbox.folder("projects")
        let repo = try sandbox.folder("projects/app")
        try sandbox.folder("projects/app/.git")
        #expect(throws: GuardViolation.gitRepository) {
            try sandbox.guardrail().validate(url: repo, root: root, directChildOnly: true)
        }
    }

    @Test func refusesTheTopOfTheDiskAndHomeItself() throws {
        let guardrail = DeletionGuard()
        #expect(throws: GuardViolation.tooShallow) {
            try guardrail.validate(url: URL(fileURLWithPath: NSHomeDirectory()), root: URL(fileURLWithPath: "/Users"), contents: true)
        }
    }

    @Test func refusesAWholeVolume() throws {
        let sandbox = try Sandbox()
        let guardrail = DeletionGuard(protected: [], volumeRoots: [sandbox.root.path])
        #expect(throws: GuardViolation.volumeRoot) {
            try guardrail.validate(url: sandbox.root, root: sandbox.root, contents: true)
        }
    }

    @Test func missingThingsAreReportedAsGone() throws {
        let sandbox = try Sandbox()
        let root = try sandbox.folder("root")
        #expect(throws: GuardViolation.missing) {
            try sandbox.guardrail().validate(url: root.appendingPathComponent("nope"), root: root)
        }
    }

    @Test func realWorldProtectedListCoversTheBasics() {
        let entries = ProtectedPaths.entries(home: "/Users/someone")
        func protects(_ path: String) -> Bool { ProtectedPaths.reason(forPath: path, in: entries) != nil }
        #expect(protects("/Users/someone/.claude/projects/abc"))
        #expect(protects("/Users/someone/.codex/thread_history_1.sqlite"))
        #expect(protects("/Users/someone/Documents/Taxes.pdf"))
        #expect(protects("/Users/someone/Library/Developer/Xcode/UserData/Provisioning Profiles/x.mobileprovision"))
        #expect(protects("/Applications/Xcode.app"))
        #expect(!protects("/Users/someone/Library/Developer/Xcode/DerivedData/App-abc"))
        #expect(!protects("/Users/someone/Library/Caches/com.example.app"))
    }
}

// MARK: - Paths

struct PathTests {
    @Test func foldsTheFirmlinkPrefix() {
        #expect(PathUtil.foldFirmlink("/System/Volumes/Data/Users/me") == "/Users/me")
        #expect(PathUtil.foldFirmlink("/System/Volumes/Data") == "/System/Volumes/Data")
        #expect(PathUtil.foldFirmlink("/Users/me") == "/Users/me")
    }

    @Test func insideMeansEqualOrBelowAndIgnoresCase() {
        #expect(PathUtil.isInside("/a/b", of: "/a/b"))
        #expect(PathUtil.isInside("/a/b/c", of: "/a/B"))
        #expect(!PathUtil.isInside("/a/bc", of: "/a/b"))
    }

    @Test func abbreviatesTheHomeFolder() {
        #expect(PathUtil.abbreviated("/Users/me/Library", home: "/Users/me") == "~/Library")
        #expect(PathUtil.abbreviated("/Users/me", home: "/Users/me") == "~")
        #expect(PathUtil.abbreviated("/Volumes/X/y", home: "/Users/me") == "/Volumes/X/y")
    }

    @Test func aSymlinkIsJudgedAsTheLinkNotItsTarget() throws {
        let sandbox = try Sandbox()
        let target = try sandbox.folder("real")
        let link = sandbox.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(PathUtil.canonical(link.path) == link.path)
    }

    @Test func prettyRuntimeNames() {
        #expect(Catalog.prettyRuntime("com.apple.CoreSimulator.SimRuntime.iOS-27-2") == "iOS 27.2")
        #expect(Catalog.prettyRuntime("com.apple.CoreSimulator.SimRuntime.xrOS-27-2") == "xrOS 27.2")
    }
}

// MARK: - Measuring

struct DiskWalkerTests {
    @Test func sumsFilesAndCountsThem() throws {
        let sandbox = try Sandbox()
        try sandbox.file("a/one.bin", bytes: 100_000)
        try sandbox.file("a/b/two.bin", bytes: 200_000)
        let node = try #require(DiskWalker(retainDepth: 1).walk(path: sandbox.root.path))
        #expect(node.files == 2)
        #expect(node.bytes >= 300_000)
        #expect(node.bytes < 400_000)
        #expect(node.children?.first?.name == "a")
    }

    @Test func countsAHardLinkOnce() throws {
        let sandbox = try Sandbox()
        let original = try sandbox.file("big.bin", bytes: 500_000)
        try FileManager.default.linkItem(at: original, to: sandbox.root.appendingPathComponent("alias.bin"))
        let node = try #require(DiskWalker().walk(path: sandbox.root.path))
        #expect(node.bytes < 600_000)
        #expect(node.files == 1)
    }

    @Test func neverFollowsSymlinks() throws {
        let sandbox = try Sandbox()
        let outside = try sandbox.folder("outside")
        try sandbox.file("outside/huge.bin", bytes: 800_000)
        let inside = try sandbox.folder("inside")
        try FileManager.default.createSymbolicLink(at: inside.appendingPathComponent("link"), withDestinationURL: outside)
        let node = try #require(DiskWalker().walk(path: inside.path))
        #expect(node.bytes < 100_000)
    }

    @Test func foldsTinyChildrenBeyondTheLimit() throws {
        let sandbox = try Sandbox()
        for index in 0..<6 { try sandbox.file("many/f\(index).bin", bytes: 1000 * (index + 1)) }
        let node = try #require(DiskWalker(retainDepth: 2, maxChildren: 4).walk(path: sandbox.root.path))
        let many = try #require(node.children?.first)
        #expect(many.children?.count == 4)
        #expect(many.hiddenCount == 2)
    }

    @Test func reportsNewestChange() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file("old.bin")
        let old = Date(timeIntervalSinceNow: -86_400 * 90)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        let node = try #require(DiskWalker().walk(path: sandbox.root.path))
        let newest = try #require(node.newest)
        #expect(abs(newest.timeIntervalSince(old)) < 5)
    }
}

// MARK: - Finding artifacts

struct ArtifactFinderTests {
    private func kinds() -> [ArtifactKind] { Catalog.artifactKinds }

    @Test func findsNodeModulesOnlyNextToAPackageFile() throws {
        let sandbox = try Sandbox()
        try sandbox.file("web/package.json", bytes: 10)
        try sandbox.folder("web/node_modules/left-pad")
        try sandbox.folder("other/node_modules/thing")   // no package.json beside it
        let found = ArtifactFinder.find(in: sandbox.root.path, kinds: kinds(), maxDepth: 6, limit: 100)
        #expect(found.count == 1)
        #expect(found.first?.path.hasSuffix("web/node_modules") == true)
        #expect(found.first?.parentName == "web")
    }

    @Test func neverLooksInsideWhatItFound() throws {
        let sandbox = try Sandbox()
        try sandbox.file("web/package.json", bytes: 10)
        try sandbox.file("web/node_modules/dep/package.json", bytes: 10)
        try sandbox.folder("web/node_modules/dep/node_modules/inner")
        let found = ArtifactFinder.find(in: sandbox.root.path, kinds: kinds(), maxDepth: 8, limit: 100)
        #expect(found.count == 1)
    }

    @Test func findsTestResultBundlesAnywhere() throws {
        let sandbox = try Sandbox()
        try sandbox.folder("evidence/run1.xcresult/Data")
        let found = ArtifactFinder.find(in: sandbox.root.path, kinds: kinds(), maxDepth: 6, limit: 100)
        #expect(found.map { PathUtil.lastComponent($0.path) } == ["run1.xcresult"])
    }

    @Test func skipsGitFolders() throws {
        let sandbox = try Sandbox()
        try sandbox.file("app/package.json", bytes: 10)
        try sandbox.folder("app/.git/hooks/node_modules")
        let found = ArtifactFinder.find(in: sandbox.root.path, kinds: kinds(), maxDepth: 6, limit: 100)
        #expect(found.isEmpty)
    }
}

// MARK: - Cleaning

struct CleanerTests {
    @Test func deletesAnItemInsideItsFolder() async throws {
        let sandbox = try Sandbox()
        let root = try sandbox.folder("DerivedData")
        let project = try sandbox.file("DerivedData/App-abc/Build/out.o", bytes: 10_000).deletingLastPathComponent().deletingLastPathComponent()
        let result = await Cleaner.perform(
            CleanItem(finding: finding(at: project, root: root, directChildOnly: true), method: .deletePermanently),
            guardrail: sandbox.guardrail()
        )
        #expect(result.outcome == .removed)
        #expect(!sandbox.exists("DerivedData/App-abc"))
        #expect(sandbox.exists("DerivedData"))
    }

    @Test func emptyingAFolderKeepsTheFolder() async throws {
        let sandbox = try Sandbox()
        let cache = try sandbox.folder("cache")
        try sandbox.file("cache/a.bin")
        try sandbox.file("cache/sub/b.bin")
        let result = await Cleaner.perform(
            CleanItem(finding: finding(at: cache, root: cache, action: .deleteContents), method: .deletePermanently),
            guardrail: sandbox.guardrail()
        )
        #expect(result.outcome == .removed)
        #expect(sandbox.exists("cache"))
        #expect(!sandbox.exists("cache/a.bin"))
        #expect(!sandbox.exists("cache/sub"))
    }

    @Test func refusesAndLeavesFilesAloneOutsideTheFolder() async throws {
        let sandbox = try Sandbox()
        let allowed = try sandbox.folder("allowed")
        let victim = try sandbox.file("elsewhere/precious.txt")
        let result = await Cleaner.perform(
            CleanItem(finding: finding(at: victim, root: allowed), method: .deletePermanently),
            guardrail: sandbox.guardrail()
        )
        #expect(!result.outcome.isSuccess)
        #expect(sandbox.exists("elsewhere/precious.txt"))
    }

    @Test func refusesProtectedFindings() async throws {
        let sandbox = try Sandbox()
        let root = try sandbox.folder("root")
        let thing = try sandbox.file("root/x.bin")
        let result = await Cleaner.perform(
            CleanItem(finding: finding(at: thing, root: root, safety: .protected), method: .deletePermanently),
            guardrail: sandbox.guardrail()
        )
        #expect(result.outcome == .refused("Protected."))
        #expect(sandbox.exists("root/x.bin"))
    }

    @Test func emptyingAFolderSkipsAGitRepositoryInside() async throws {
        let sandbox = try Sandbox()
        let cache = try sandbox.folder("cache")
        try sandbox.file("cache/junk.bin")
        try sandbox.folder("cache/repo/.git")
        try sandbox.file("cache/repo/work.txt")
        let result = await Cleaner.perform(
            CleanItem(finding: finding(at: cache, root: cache, action: .deleteContents), method: .deletePermanently),
            guardrail: sandbox.guardrail()
        )
        #expect(!result.outcome.isSuccess)          // it reports the repository it left alone
        #expect(!sandbox.exists("cache/junk.bin"))
        #expect(sandbox.exists("cache/repo/work.txt"))
    }

    @Test func removesReadOnlyFolders() async throws {
        let sandbox = try Sandbox()
        let root = try sandbox.folder("root")
        let locked = try sandbox.folder("root/locked")
        try sandbox.file("root/locked/stl/one.stl")
        _ = try run("/bin/chmod", ["-R", "a-w", locked.path])
        let result = await Cleaner.perform(
            CleanItem(finding: finding(at: locked, root: root, directChildOnly: true), method: .deletePermanently),
            guardrail: sandbox.guardrail()
        )
        #expect(result.outcome == .removed)
        #expect(!sandbox.exists("root/locked"))
    }

    @Test func deletingASymlinkRemovesOnlyTheLink() async throws {
        let sandbox = try Sandbox()
        let root = try sandbox.folder("root")
        let precious = try sandbox.file("precious/keep.txt")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: precious.deletingLastPathComponent())
        let result = await Cleaner.perform(
            CleanItem(finding: finding(at: link, root: root, directChildOnly: true), method: .deletePermanently),
            guardrail: sandbox.guardrail()
        )
        #expect(result.outcome == .removed)
        #expect(!sandbox.exists("root/link"))
        #expect(sandbox.exists("precious/keep.txt"))
    }

    @Test func missingItemsCountAsAlreadyGone() async throws {
        let sandbox = try Sandbox()
        let root = try sandbox.folder("root")
        let result = await Cleaner.perform(
            CleanItem(finding: finding(at: root.appendingPathComponent("ghost"), root: root), method: .deletePermanently),
            guardrail: sandbox.guardrail()
        )
        #expect(result.outcome == .alreadyGone)
    }

    @Test func streamsOneResultPerItem() async throws {
        let sandbox = try Sandbox()
        let root = try sandbox.folder("root")
        let one = try sandbox.file("root/one.bin")
        let two = try sandbox.file("root/two.bin")
        let items = [one, two].map { CleanItem(finding: finding(at: $0, root: root, directChildOnly: true), method: .deletePermanently) }
        var finished: [CleanResult] = []
        for await event in Cleaner.run(items: items, guardrail: sandbox.guardrail()) {
            if case .finished(let result) = event { finished.append(result) }
        }
        #expect(finished.count == 2)
        #expect(finished.allSatisfy { $0.outcome == .removed })
    }
}

// MARK: - Scanning

struct CleanupScannerTests {
    private func environment(_ sandbox: Sandbox, running: [RunningApp] = []) -> ScanEnvironment {
        ScanEnvironment(
            home: sandbox.home, volumes: [Volume(id: "/", name: "Test", mountURL: URL(fileURLWithPath: "/"), scanRoot: sandbox.root, totalBytes: 1, freeBytes: 1, isInternal: true)],
            derivedDataFolders: [], runningApps: running, appNames: [:], projectRoots: [sandbox.root]
        )
    }

    private func collect(_ stream: AsyncStream<ScanEvent>) async -> [Finding] {
        var found: [Finding] = []
        for await event in stream { if case .found(let finding) = event { found.append(finding) } }
        return found
    }

    @Test func measuresAndDescribesWhatARuleFinds() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("web/package.json", bytes: 10)
        try sandbox.file("web/node_modules/dep/index.js", bytes: 300_000)
        let rule = Catalog.rules().first { $0.id == "project.node-modules" }!
        var tuned = rule
        tuned.minBytes = 1000
        let findings = await collect(CleanupScanner.scan(environment: environment(sandbox), rules: [tuned]))
        let one = try #require(findings.first)
        #expect(findings.count == 1)
        #expect(one.title == "web")
        #expect(one.subtitle.hasPrefix("node_modules"))
        #expect(one.bytes >= 300_000)
        #expect(one.safety == .safe)
        #expect(one.leafNames == ["node_modules"])
        #expect(one.canClean)
    }

    @Test func dropsThingsSmallerThanTheMinimum() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("web/package.json", bytes: 10)
        try sandbox.file("web/node_modules/dep/index.js", bytes: 5000)
        let rule = Catalog.rules().first { $0.id == "project.node-modules" }!   // minimum is 20 MB
        let findings = await collect(CleanupScanner.scan(environment: environment(sandbox), rules: [rule]))
        #expect(findings.isEmpty)
    }

    @Test func blocksWhenTheOwnerIsRunning() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("web/package.json", bytes: 10)
        let modules = try sandbox.file("web/node_modules/dep/index.js", bytes: 300_000)
        var rule = Catalog.rules().first { $0.id == "project.node-modules" }!
        rule.minBytes = 1000
        let running = RunningApp(name: "Cursor", bundleID: "com.example.cursor", paths: [PathUtil.canonical(modules.path)])
        let findings = await collect(CleanupScanner.scan(environment: environment(sandbox, running: [running]), rules: [rule]))
        let one = try #require(findings.first)
        #expect(one.blockedBy.map(\.message) == ["In use by Cursor"])
        #expect(!one.canClean)
    }

    @Test func blocksRulesThatNeedAnAppClosed() throws {
        var rule = Catalog.derivedData
        rule.blockedByBundleIDs = ["com.apple.dt.Xcode"]
        let candidate = Candidate(url: URL(fileURLWithPath: "/tmp/x"), title: "x")
        let blockers = CleanupScanner.blockers(
            for: rule, candidate: candidate, canonicalPath: "/private/tmp/x",
            running: [RunningApp(name: "Xcode", bundleID: "com.apple.dt.Xcode", paths: [])]
        )
        #expect(blockers.map(\.message) == ["Quit Xcode first"])
    }

    @Test func picksTheExternalDriveForFilesOnIt() {
        let internalDisk = Volume(id: "/", name: "Mac", mountURL: URL(fileURLWithPath: "/"), scanRoot: URL(fileURLWithPath: "/System/Volumes/Data"), totalBytes: 1, freeBytes: 1, isInternal: true)
        let external = Volume(id: "/Volumes/XT", name: "XT", mountURL: URL(fileURLWithPath: "/Volumes/XT"), scanRoot: URL(fileURLWithPath: "/Volumes/XT"), totalBytes: 1, freeBytes: 1, isInternal: false)
        let volumes = [internalDisk, external]
        #expect(CleanupScanner.volumeID(for: URL(fileURLWithPath: "/Volumes/XT/Dev/DerivedData"), in: volumes) == "/Volumes/XT")
        #expect(CleanupScanner.volumeID(for: URL(fileURLWithPath: "/Users/me/Library/Caches"), in: volumes) == "/")
    }

    @Test func everyRuleHasWordsForItsRow() {
        for rule in Catalog.rules() {
            #expect(!rule.what.isEmpty, "\(rule.id) needs a description")
            #expect(!rule.consequence.isEmpty, "\(rule.id) needs a consequence")
        }
        let ids = Catalog.rules().map(\.id)
        #expect(Set(ids).count == ids.count, "rule ids must be unique")
    }
}
