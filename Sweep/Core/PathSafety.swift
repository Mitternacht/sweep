import Foundation
import Darwin

// MARK: - Path helpers

nonisolated enum PathUtil {
    /// On the startup disk, `/Users` and friends are firmlinks into this folder.
    static let dataPrefix = "/System/Volumes/Data"

    static func realPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard realpath(path, &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    /// The one form of a path used for every safety comparison.
    /// Symlinks in the parent folders are resolved. The last component is left alone, so a symlink is
    /// judged as the link itself and never as whatever it points at. The firmlink prefix is folded away.
    static func canonical(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        let last = standardized.lastPathComponent
        let parent = standardized.deletingLastPathComponent().path
        let resolvedParent = realPath(parent) ?? parent
        let joined: String
        if last.isEmpty || last == "/" {
            joined = resolvedParent
        } else if resolvedParent == "/" {
            joined = "/" + last
        } else {
            joined = resolvedParent + "/" + last
        }
        return foldFirmlink(joined)
    }

    static func foldFirmlink(_ path: String) -> String {
        if path.hasPrefix(dataPrefix + "/") { return String(path.dropFirst(dataPrefix.count)) }
        return path
    }

    /// True when `child` is `parent` or lives anywhere below it. Case-insensitive, like APFS by default.
    static func isInside(_ child: String, of parent: String) -> Bool {
        let c = child.lowercased()
        let p = parent.lowercased()
        if c == p { return true }
        return c.hasPrefix(p.hasSuffix("/") ? p : p + "/")
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    static func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// `/Users/me/Library` -> `~/Library`
    static func abbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        let folded = foldFirmlink(path)
        if folded == home { return "~" }
        if folded.hasPrefix(home + "/") { return "~" + folded.dropFirst(home.count) }
        return folded
    }
}

// MARK: - Protected paths

nonisolated struct ProtectedEntry: Hashable, Sendable, Identifiable {
    var id: String { path + (namePrefix ?? "") }
    var path: String
    /// When set, only children of `path` whose name starts with this are protected.
    var namePrefix: String?
    var reason: String
}

/// Things Sweep refuses to touch, whatever any rule says.
nonisolated enum ProtectedPaths {
    static func entries(home: String = NSHomeDirectory()) -> [ProtectedEntry] {
        func inHome(_ relative: String, _ reason: String, prefix: String? = nil) -> ProtectedEntry {
            ProtectedEntry(path: PathUtil.canonical(home + "/" + relative), namePrefix: prefix, reason: reason)
        }
        func system(_ path: String, _ reason: String) -> ProtectedEntry {
            ProtectedEntry(path: PathUtil.canonical(path), namePrefix: nil, reason: reason)
        }

        let xcodeUser = "Library/Developer/Xcode/UserData"
        return [
            // Conversation history and session state
            inHome(".claude/projects", "Claude Code conversation history"),
            inHome(".claude/history.jsonl", "Claude prompt history"),
            inHome(".codex/sessions", "Codex conversation history"),
            inHome(".codex/archived_sessions", "Codex conversation history"),
            inHome(".codex", "Codex conversation history", prefix: "thread_history"),
            inHome("Library/Application Support/Claude", "Claude Code session state", prefix: "claude-code"),

            // Signing and Xcode settings
            inHome("\(xcodeUser)/Provisioning Profiles", "Signing profiles are painful to fetch again"),
            inHome("\(xcodeUser)/FontAndColorThemes", "Your Xcode themes"),
            inHome("\(xcodeUser)/KeyBindings", "Your Xcode key bindings"),

            // Your files
            inHome("Documents", "Your documents"),
            inHome("Desktop", "Your desktop"),
            inHome("Pictures", "Your photos and pictures"),
            inHome("Movies", "Your movies"),
            inHome("Music", "Your music"),
            inHome("Library/Mobile Documents", "iCloud Drive is managed by iCloud"),
            inHome("Library/Messages", "Your messages"),
            inHome("Library/Mail", "Your mail"),
            inHome("Library/Safari", "Safari data"),
            inHome("Library/Keychains", "Your keychains"),
            inHome("Library/Calendars", "Your calendars"),
            inHome("Library/Application Support/AddressBook", "Your contacts"),

            // Credentials and configuration
            inHome(".ssh", "Your SSH keys"),
            inHome(".gnupg", "Your GPG keys"),
            inHome(".aws", "Cloud credentials"),
            inHome(".config", "App settings"),

            // The system itself
            system("/System", "macOS itself"),
            system("/Applications", "Installed apps"),
            system("/Library", "System-wide support files"),
            system("/usr", "macOS itself"),
            system("/bin", "macOS itself"),
            system("/sbin", "macOS itself"),
            system("/private/etc", "System configuration"),
            system("/private/var/db", "System databases"),
            system("/opt/homebrew", "Homebrew installs"),
        ]
    }

    /// The reason a path is protected, or nil. Used by Explore to show a lock.
    static func reason(forPath path: String, in entries: [ProtectedEntry]) -> String? {
        let target = PathUtil.canonical(path)
        for entry in entries {
            if let prefix = entry.namePrefix {
                guard PathUtil.isInside(target, of: entry.path), target.lowercased() != entry.path.lowercased() else { continue }
                let rest = target.dropFirst(entry.path.count + 1)
                let first = rest.split(separator: "/").first.map(String.init) ?? ""
                if first.lowercased().hasPrefix(prefix.lowercased()) { return entry.reason }
            } else if PathUtil.isInside(target, of: entry.path) {
                return entry.reason
            }
        }
        return nil
    }
}

// MARK: - Deletion guard

nonisolated enum GuardViolation: Error, Hashable, Sendable, LocalizedError {
    case missing
    case tooShallow
    case volumeRoot
    case outsideAllowedFolder
    case notDirectChild
    case unexpectedName
    case protected(String)
    case gitRepository

    var errorDescription: String? {
        switch self {
        case .missing: "It's already gone."
        case .tooShallow: "That folder is too close to the top of the disk."
        case .volumeRoot: "That's a whole drive."
        case .outsideAllowedFolder: "That's outside the folder this cleanup is allowed to touch."
        case .notDirectChild: "That isn't directly inside the folder this cleanup is allowed to touch."
        case .unexpectedName: "That doesn't have the name this cleanup expects."
        case .protected(let reason): "Protected: \(reason)."
        case .gitRepository: "That folder is a Git repository."
        }
    }
}

/// The last line of defense. Every delete goes through `validate`, and a violation means nothing is removed.
nonisolated struct DeletionGuard: Sendable {
    var protected: [ProtectedEntry]
    var volumeRoots: Set<String>

    init(protected: [ProtectedEntry] = ProtectedPaths.entries(), volumeRoots: [String] = DeletionGuard.mountedVolumeRoots()) {
        self.protected = protected
        self.volumeRoots = Set(volumeRoots.map { PathUtil.canonical($0).lowercased() })
    }

    static func mountedVolumeRoots() -> [String] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return urls.map(\.path)
    }

    /// Returns the canonical path that is safe to remove, or throws the reason it isn't.
    /// - Parameters:
    ///   - contents: true when only the *contents* of `url` will be removed, so `url` may equal `root`.
    func validate(
        url: URL,
        root: URL,
        leafNames: Set<String>? = nil,
        leafSuffix: String? = nil,
        directChildOnly: Bool = false,
        contents: Bool = false
    ) throws -> String {
        let target = PathUtil.canonical(url.path)
        let rootPath = PathUtil.canonical(root.path)

        var info = stat()
        guard lstat(target, &info) == 0 else { throw GuardViolation.missing }

        guard PathUtil.components(target).count >= 3 else { throw GuardViolation.tooShallow }
        guard !volumeRoots.contains(target.lowercased()) else { throw GuardViolation.volumeRoot }

        guard PathUtil.isInside(target, of: rootPath) else { throw GuardViolation.outsideAllowedFolder }
        if !contents, target.lowercased() == rootPath.lowercased() { throw GuardViolation.outsideAllowedFolder }
        if directChildOnly, !contents, PathUtil.parent(of: target).lowercased() != rootPath.lowercased() {
            throw GuardViolation.notDirectChild
        }
        if let leafNames, !contents, !leafNames.contains(PathUtil.lastComponent(target)) {
            throw GuardViolation.unexpectedName
        }
        if let leafSuffix, !contents, !PathUtil.lastComponent(target).hasSuffix(leafSuffix) {
            throw GuardViolation.unexpectedName
        }

        for entry in protected {
            let entryPath = entry.path
            // Removing the target would remove (or empty) a protected thing that lives inside it.
            if PathUtil.isInside(entryPath, of: target) { throw GuardViolation.protected(entry.reason) }
            // The target sits inside a protected thing.
            if PathUtil.isInside(target, of: entryPath) {
                if let prefix = entry.namePrefix {
                    let rest = target.dropFirst(entryPath.count + 1)
                    let first = rest.split(separator: "/").first.map(String.init) ?? ""
                    if first.lowercased().hasPrefix(prefix.lowercased()) { throw GuardViolation.protected(entry.reason) }
                } else {
                    throw GuardViolation.protected(entry.reason)
                }
            }
        }

        // A repository root is somebody's work, whatever its name.
        var gitInfo = stat()
        if lstat(target + "/.git", &gitInfo) == 0 { throw GuardViolation.gitRepository }

        return target
    }
}
