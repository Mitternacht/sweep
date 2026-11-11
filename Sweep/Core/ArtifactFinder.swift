import Foundation
import Darwin

/// A kind of build junk that lives inside project folders and is safe to find by name.
nonisolated struct ArtifactKind: Sendable {
    var ruleID: String
    /// Short name shown as the row's context, e.g. `node_modules`.
    var label: String
    var category: Category
    var safety: Safety
    var what: String
    var consequence: String
    var minBytes: Int64
    var matches: @Sendable (String) -> Bool
    /// A match only counts when the folder next to it has one of these. `*.xcodeproj` means "any name ending in .xcodeproj".
    /// Empty means no neighbour is needed.
    var manifests: [String]
    var leafNames: Set<String>?
    var leafSuffix: String?
}

/// Walks project folders looking for things like `node_modules` or `.build` that sit next to the file proving they are what they claim.
nonisolated enum ArtifactFinder {
    struct Found: Sendable {
        var path: String
        var kindIndex: Int
        var parentName: String
        var root: String
    }

    private static let skipNames: Set<String> = [
        ".git", ".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd", ".TemporaryItems", ".DocumentRevisions-V100",
        "node_modules", ".build", "Pods", "DerivedData", "Library", ".venv", "venv", ".next",
    ]
    private static let skipSuffixes = [
        ".app", ".photoslibrary", ".xcodeproj", ".xcworkspace", ".xcassets", ".framework", ".lproj", ".bundle",
        ".noindex", ".appiconset", ".imageset", ".playground", ".plugin", ".sparsebundle", ".dSYM",
    ]

    /// Finds artifacts under each root and groups them as candidates by rule id.
    @concurrent
    static func discover(roots: [URL], kinds: [ArtifactKind]) async -> [String: [Candidate]] {
        var seen = Set<String>()
        var result: [String: [Candidate]] = [:]
        var budget = 4000
        for root in roots {
            if Task.isCancelled || budget <= 0 { break }
            for item in find(in: root.path, kinds: kinds, maxDepth: 7, limit: budget) where seen.insert(item.path).inserted {
                let kind = kinds[item.kindIndex]
                result[kind.ruleID, default: []].append(Candidate(
                    url: URL(fileURLWithPath: item.path),
                    title: item.parentName,
                    subtitle: kind.label,
                    guardRoot: URL(fileURLWithPath: item.root),
                    leafNames: kind.leafNames,
                    leafSuffix: kind.leafSuffix
                ))
                budget -= 1
            }
        }
        return result
    }

    static func find(in root: String, kinds: [ArtifactKind], maxDepth: Int, limit: Int) -> [Found] {
        var out: [Found] = []

        func visit(_ path: String, depth: Int) {
            if out.count >= limit || Task.isCancelled { return }
            guard let entries = list(path) else { return }
            let names = Set(entries.map(\.name))

            for entry in entries where entry.isDirectory {
                let name = entry.name
                if let index = kinds.firstIndex(where: { $0.matches(name) && hasManifest($0, among: names) }) {
                    out.append(Found(path: path + "/" + name, kindIndex: index, parentName: PathUtil.lastComponent(path), root: root))
                    continue   // never look inside the thing we found
                }
                if skipNames.contains(name) || skipSuffixes.contains(where: { name.hasSuffix($0) }) { continue }
                if depth < maxDepth { visit(path + "/" + name, depth: depth + 1) }
            }
        }

        visit(root, depth: 0)
        return out
    }

    private static func hasManifest(_ kind: ArtifactKind, among names: Set<String>) -> Bool {
        if kind.manifests.isEmpty { return true }
        return kind.manifests.contains { manifest in
            if manifest.hasPrefix("*") {
                let suffix = String(manifest.dropFirst())
                return names.contains { $0.hasSuffix(suffix) }
            }
            return names.contains(manifest)
        }
    }

    /// Lists a folder without touching file contents. Symlinks are never followed.
    private static func list(_ path: String) -> [(name: String, isDirectory: Bool)]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        var items: [(name: String, isDirectory: Bool)] = []
        while let entry = readdir(dir) {
            let namePointer = UnsafeRawPointer(entry)
                .advanced(by: MemoryLayout<dirent>.offset(of: \.d_name)!)
                .assumingMemoryBound(to: CChar.self)
            let name = String(cString: namePointer)
            if name == "." || name == ".." { continue }
            var isDirectory = entry.pointee.d_type == UInt8(DT_DIR)
            if entry.pointee.d_type == UInt8(DT_UNKNOWN) {
                var info = stat()
                if lstat(path + "/" + name, &info) == 0 { isDirectory = (info.st_mode & S_IFMT) == S_IFDIR }
            }
            items.append((name, isDirectory))
        }
        return items
    }
}
