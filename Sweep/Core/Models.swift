import Foundation

// The Core folder is plain value types and file-system work. Nothing here touches the UI, so
// everything is `nonisolated` (the project defaults to the main actor) and safe to run in the background.

// MARK: - Safety

/// How sure Sweep is that removing something does no harm.
nonisolated enum Safety: Int, Comparable, Hashable, Sendable, CaseIterable {
    /// Rebuilt or downloaded again on its own. Nothing of yours is lost.
    case safe
    /// Probably stale, but only you can say. Moved to the Trash by default.
    case review
    /// Sweep never touches these.
    case protected

    static func < (lhs: Safety, rhs: Safety) -> Bool { lhs.rawValue < rhs.rawValue }
}

nonisolated enum Category: String, CaseIterable, Hashable, Sendable, Identifiable {
    case xcode, simulators, packages, projects, appCaches, temp, downloads, backups, trash
    var id: String { rawValue }
}

// MARK: - Actions

/// What "clean this up" means for one finding.
nonisolated enum CleanAction: Hashable, Sendable {
    /// Remove the file or folder itself.
    case deleteItem
    /// Empty the folder but keep the folder.
    case deleteContents
    /// Ask `simctl` to shut down, prune and erase every simulator.
    case resetSimulators
}

nonisolated enum CleanMethod: String, Hashable, Sendable, CaseIterable {
    case deletePermanently
    case moveToTrash
}

// MARK: - Findings

nonisolated struct Blocker: Hashable, Sendable {
    var appName: String
    /// "Quit Xcode first", "In use by Cursor", ...
    var message: String
}

nonisolated struct BreakdownItem: Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var detail: String?
    var bytes: Int64
}

/// One thing taking space that Sweep understands: what it is, where it is and what happens if it goes.
nonisolated struct Finding: Identifiable, Hashable, Sendable {
    var id: String
    var ruleID: String
    var title: String
    /// One line of context shown under the title: who owns it and how old it is.
    var subtitle: String
    var what: String
    var consequence: String
    var category: Category
    var safety: Safety
    var url: URL
    var volumeID: String
    var bytes: Int64
    var fileCount: Int
    var lastChanged: Date?
    var action: CleanAction
    /// The folder this finding is allowed to live in. The delete guard refuses anything outside it.
    var guardRoot: URL
    /// When set, the item's own name must be one of these (e.g. `node_modules`).
    var leafNames: Set<String>?
    /// When set, the item's own name must end with this (e.g. `.xcresult`).
    var leafSuffix: String?
    /// When true the item must sit directly inside `guardRoot`.
    var directChildOnly: Bool
    var blockedBy: [Blocker]
    var breakdown: [BreakdownItem]

    var canClean: Bool { safety != .protected && blockedBy.isEmpty }
}

// MARK: - Volumes

nonisolated struct Volume: Identifiable, Hashable, Sendable {
    /// Mount path, e.g. `/` or `/Volumes/Backup`.
    var id: String
    var name: String
    var mountURL: URL
    /// The folder Explore walks. For the startup disk that's the Data volume.
    var scanRoot: URL
    var totalBytes: Int64
    var freeBytes: Int64
    var isInternal: Bool

    var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
    var freeFraction: Double { totalBytes > 0 ? Double(freeBytes) / Double(totalBytes) : 0 }
}

// MARK: - Cleaning results

nonisolated struct CleanItem: Hashable, Sendable {
    var finding: Finding
    var method: CleanMethod
}

nonisolated enum CleanOutcome: Hashable, Sendable {
    case removed
    case trashed
    case alreadyGone
    case refused(String)
    case failed(String)

    var isSuccess: Bool {
        switch self {
        case .removed, .trashed, .alreadyGone: true
        case .refused, .failed: false
        }
    }
}

nonisolated struct CleanResult: Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var bytes: Int64
    var outcome: CleanOutcome
}

nonisolated enum CleanEvent: Sendable {
    case started(total: Int)
    case began(title: String, index: Int)
    case finished(CleanResult)
    case done
}
