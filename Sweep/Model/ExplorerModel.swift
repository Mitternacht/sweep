import SwiftUI
import AppKit

/// What the Explore screen shows: one folder at a time, with sizes, context and a lock on anything protected.
@Observable
final class ExplorerModel {
    struct Row: Identifiable {
        var node: TreeNode
        /// Why Sweep won't touch it, if it won't.
        var lockReason: String?
        /// The cleanup finding for exactly this path, if there is one.
        var finding: Finding?
        var note: String?
        var fraction: Double
        var id: String { node.path }
    }

    enum Style: String, CaseIterable, Identifiable {
        case list, map
        var id: String { rawValue }
    }

    private(set) var volume: Volume?
    private(set) var path = ""
    private(set) var root: TreeNode?
    private(set) var rows: [Row] = []
    /// Folders still being measured.
    private(set) var measuring: Set<String> = []
    private(set) var trashError: String?
    var selectedID: String?
    var style: Style = .list

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var findingsByPath: [String: Finding] = [:]
    @ObservationIgnored private let protectedEntries = ProtectedPaths.entries()
    @ObservationIgnored private var contextCache: [String: (lockReason: String?, finding: Finding?)] = [:]

    // MARK: Derived

    var current: TreeNode? { root?.node(at: path) }
    var isMeasuringRoot: Bool { !measuring.isEmpty }
    var selectedRow: Row? { selectedID.flatMap { id in rows.first { $0.id == id } } }

    struct Crumb: Identifiable {
        var name: String
        var path: String
        var id: String { path }
    }

    /// Folders from the drive's top down to where we are, for the path bar.
    var breadcrumbs: [Crumb] {
        guard let volume else { return [] }
        let rootPath = volume.scanRoot.path
        var result = [Crumb(name: volume.name, path: rootPath)]
        guard path.count > rootPath.count else { return result }
        var built = rootPath
        for part in path.dropFirst(rootPath.count).split(separator: "/") {
            built += "/" + part
            result.append(Crumb(name: String(part), path: built))
        }
        return result
    }

    // MARK: Opening a drive

    func open(_ volume: Volume) {
        if self.volume?.id == volume.id, root != nil { return }
        task?.cancel()
        self.volume = volume
        path = volume.scanRoot.path
        selectedID = nil
        trashError = nil

        let entries = DirectoryListing.entries(at: path)
        measuring = Set(entries.map(\.path))
        root = TreeNode(
            path: path, name: volume.name, isDirectory: true, bytes: 0, files: 0, newest: nil, unreadable: 0,
            children: entries.map {
                TreeNode(path: $0.path, name: $0.name, isDirectory: $0.isDirectory, bytes: 0, files: 0, newest: nil, unreadable: 0, children: nil)
            }
        )
        refreshRows()

        let paths = entries.map(\.path)
        task = Task {
            await withTaskGroup(of: TreeNode?.self) { group in
                var next = 0
                var inFlight = 0
                let limit = 4
                while next < paths.count || inFlight > 0 {
                    if Task.isCancelled { group.cancelAll(); break }
                    while inFlight < limit, next < paths.count {
                        let target = paths[next]
                        group.addTask { await DiskScanner.tree(path: target, retainDepth: 2) }
                        next += 1
                        inFlight += 1
                    }
                    guard let measured = await group.next() else { break }
                    inFlight -= 1
                    if let measured { apply(measured) }
                }
            }
            measuring = []
            refreshRows()
        }
    }

    private func apply(_ node: TreeNode) {
        root?.replace(at: node.path, with: node)
        measuring.remove(node.path)
        refreshRows()
    }

    // MARK: Moving around

    func navigate(to target: String) {
        guard let node = root?.node(at: target), node.isDirectory else { return }
        path = target
        selectedID = nil
        trashError = nil
        if node.children == nil, node.bytes > 0 { expand(target) }
        refreshRows()
    }

    func goUp() {
        guard let volume, path != volume.scanRoot.path else { return }
        navigate(to: PathUtil.parent(of: path))
    }

    func open(row: Row) {
        guard row.node.isDirectory else { return }
        navigate(to: row.node.path)
    }

    /// Measures a folder that was deeper than the first scan listed.
    private func expand(_ target: String) {
        measuring.insert(target)
        Task {
            if let node = await DiskScanner.tree(path: target, retainDepth: 2) { root?.replace(at: target, with: node) }
            measuring.remove(target)
            refreshRows()
        }
    }

    /// Measures the current folder again, e.g. after something inside it was removed.
    func reloadCurrent() {
        expand(path)
    }

    // MARK: Context

    func setContext(findings: [Finding]) {
        contextCache = [:]
        findingsByPath = Dictionary(findings.map { (PathUtil.canonical($0.url.path), $0) }, uniquingKeysWith: { first, _ in first })
        refreshRows()
    }

    private func refreshRows() {
        guard let node = current else {
            rows = []
            return
        }
        let total = Double(max(node.bytes, 1))
        rows = (node.children ?? []).map { child in
            Row(
                node: child,
                lockReason: ProtectedPaths.reason(forPath: child.path, in: protectedEntries),
                finding: findingsByPath[PathUtil.canonical(child.path)],
                note: PathContext.note(for: child.path),
                fraction: Double(child.bytes) / total
            )
        }
    }

    #if DEBUG
    /// Fills the explorer with a believable tree so previews don't need a real scan.
    func loadSample(volume: Volume) {
        func node(_ name: String, _ path: String, gb: Double, files: Int, dir: Bool = true, kids: [TreeNode]? = nil) -> TreeNode {
            TreeNode(path: path, name: name, isDirectory: dir, bytes: Int64(gb * 1_000_000_000), files: files, newest: .now.addingTimeInterval(-86_400 * 3),
                     unreadable: 0, children: kids)
        }
        let rootPath = volume.scanRoot.path
        let library = node("Library", "\(rootPath)/Users/demo/Library", gb: 74, files: 410_000, kids: [
            node("Mobile Documents", "\(rootPath)/Users/demo/Library/Mobile Documents", gb: 38, files: 12_000),
            node("Application Support", "\(rootPath)/Users/demo/Library/Application Support", gb: 25, files: 210_000),
            node("Caches", "\(rootPath)/Users/demo/Library/Caches", gb: 6, files: 90_000),
        ])
        let demo = node("demo", "\(rootPath)/Users/demo", gb: 109, files: 900_000, kids: [
            library,
            node("Development", "\(rootPath)/Users/demo/Development", gb: 16, files: 180_000),
            node(".claude", "\(rootPath)/Users/demo/.claude", gb: 4.7, files: 5_000),
            node("Pictures", "\(rootPath)/Users/demo/Pictures", gb: 3.1, files: 2_000),
        ])
        root = node(volume.name, rootPath, gb: 232, files: 3_000_000, kids: [
            node("Users", "\(rootPath)/Users", gb: 109, files: 900_000, kids: [demo]),
            node("System", "\(rootPath)/System", gb: 65, files: 40_000),
            node("private", "\(rootPath)/private", gb: 33, files: 300_000),
            node("Applications", "\(rootPath)/Applications", gb: 15, files: 120_000),
            node("Library", "\(rootPath)/Library", gb: 6.7, files: 30_000),
            node("opt", "\(rootPath)/opt", gb: 1.1, files: 60_000),
        ])
        self.volume = volume
        path = "\(rootPath)/Users/demo"
        refreshRows()
    }
    #endif

    /// Lock and cleanup context for any path in the tree. The map uses it to tint the tiles inside a folder.
    func context(forPath path: String) -> (lockReason: String?, finding: Finding?) {
        if let cached = contextCache[path] { return cached }
        let value = (lockReason: ProtectedPaths.reason(forPath: path, in: protectedEntries), finding: findingsByPath[PathUtil.canonical(path)])
        contextCache[path] = value
        return value
    }

    // MARK: Trash

    func canTrash(_ row: Row) -> Bool {
        row.lockReason == nil && (row.finding?.blockedBy.isEmpty ?? true) && !measuring.contains(row.node.path)
    }

    /// Moves one item to the Trash. The delete guard still checks it first.
    func moveToTrash(_ row: Row) async {
        guard let volume, canTrash(row) else { return }
        let node = row.node
        let item = CleanItem(
            finding: Finding(
                id: "explore|\(node.path)", ruleID: "explore.manual", title: node.name, subtitle: "", what: "", consequence: "",
                category: .projects, safety: .review, url: URL(fileURLWithPath: node.path), volumeID: volume.id,
                bytes: node.bytes, fileCount: node.files, lastChanged: node.newest, action: .deleteItem,
                guardRoot: URL(fileURLWithPath: PathUtil.parent(of: node.path)), leafNames: nil, leafSuffix: nil,
                directChildOnly: true, blockedBy: [], breakdown: []
            ),
            method: .moveToTrash
        )
        let result = await Cleaner.perform(item, guardrail: DeletionGuard())
        if result.outcome.isSuccess {
            trashError = nil
            selectedID = nil
            reloadCurrent()
        } else if case .refused(let message) = result.outcome {
            trashError = message
        } else if case .failed(let message) = result.outcome {
            trashError = message
        }
    }
}
