import Foundation
import CoreGraphics
import Darwin

// MARK: - Finding things inside a tree

nonisolated extension TreeNode {
    /// The node at `target`, if this tree has listed that far down.
    func node(at target: String) -> TreeNode? {
        if path == target { return self }
        guard let children else { return nil }
        for child in children where target == child.path || target.hasPrefix(child.path + "/") {
            return child.node(at: target)
        }
        return nil
    }

    /// Swaps in a freshly measured node and fixes the sizes of everything above it.
    @discardableResult
    mutating func replace(at target: String, with node: TreeNode) -> Bool {
        if path == target {
            self = node
            return true
        }
        guard var kids = children else { return false }
        for index in kids.indices where target == kids[index].path || target.hasPrefix(kids[index].path + "/") {
            let before = kids[index]
            guard kids[index].replace(at: target, with: node) else { return false }
            bytes += kids[index].bytes - before.bytes
            files += kids[index].files - before.files
            if let theirs = kids[index].newest, theirs > (newest ?? .distantPast) { newest = theirs }
            kids.sort { $0.bytes > $1.bytes }
            children = kids
            return true
        }
        return false
    }
}

// MARK: - Quick listings

nonisolated enum DirectoryListing {
    struct Entry: Sendable {
        var path: String
        var name: String
        var isDirectory: Bool
    }

    /// Folders and regular files directly inside `path`, without sizes. Symlinks and other drives are skipped.
    static func entries(at path: String) -> [Entry] {
        var rootInfo = stat()
        guard stat(path, &rootInfo) == 0, let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        var result: [Entry] = []
        for name in names {
            let childPath = (path == "/" ? "" : path) + "/" + name
            var info = stat()
            guard lstat(childPath, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                if info.st_dev == rootInfo.st_dev { result.append(Entry(path: childPath, name: name, isDirectory: true)) }
            case S_IFREG:
                result.append(Entry(path: childPath, name: name, isDirectory: false))
            default:
                continue
            }
        }
        return result
    }
}

// MARK: - What a folder is

/// Plain-language notes for folders people wonder about.
nonisolated enum PathContext {
    private static let homeNotes: [String: String] = [
        "Library": "App data, caches and settings for everything on your Mac.",
        "Library/Developer": "Xcode, simulators and build data.",
        "Library/Developer/Xcode": "Xcode's build output, device symbols and archives.",
        "Library/Developer/CoreSimulator": "Simulators and everything installed in them.",
        "Library/Caches": "Temporary files apps saved to run faster.",
        "Library/Application Support": "Saved data for your apps.",
        "Library/Mobile Documents": "iCloud Drive and app data synced with iCloud. Managed by iCloud.",
        "Library/Containers": "Data for sandboxed apps.",
        "Library/Group Containers": "Data shared between an app and its extensions.",
        "Library/Logs": "Log files apps wrote while running.",
        "Library/Messages": "Your messages and attachments.",
        "Library/Mail": "Your mail.",
        "Library/Safari": "Safari history and data.",
        "Library/Application Support/MobileSync": "iPhone and iPad backups.",
        "Library/Application Support/Claude": "The Claude app's data and caches.",
        "Library/Application Support/Google": "Chrome profile data.",
        "Library/Application Support/Cursor": "Cursor's settings and extensions.",
        ".claude": "Claude Code: settings, history and sessions.",
        ".codex": "Codex: settings, history and sessions.",
        ".cache": "Caches from developer tools.",
        ".local": "Tools and data installed for just you.",
        ".npm": "npm's package cache.",
        ".gradle": "Gradle's downloads and build cache.",
        ".cargo": "Rust's toolchain and downloaded crates.",
        ".Trash": "Files you moved to the Trash.",
        "Downloads": "Things you downloaded.",
        "Documents": "Your documents.",
        "Desktop": "Your desktop.",
        "Pictures": "Your pictures and Photos library.",
        "Movies": "Your movies.",
        "Music": "Your music.",
        "Applications": "Apps installed for just you.",
        "Development": "Your projects.",
    ]

    private static let systemNotes: [String: String] = [
        "/Applications": "Installed apps.",
        "/Library": "Support files shared by everyone on this Mac.",
        "/Users": "Home folders for each person on this Mac.",
        "/System": "macOS itself.",
        "/System/Library": "Core system files.",
        "/System/Library/AssetsV2": "Assets macOS downloaded: Apple Intelligence models, simulator runtimes and documentation. Managed by macOS.",
        "/private": "System files, temp folders and databases.",
        "/private/var": "Changing system data: databases, logs and per-user caches.",
        "/private/var/folders": "Per-user temporary files and caches. macOS and apps manage these.",
        "/private/var/db": "System databases.",
        "/private/tmp": "Temporary files from apps and build tools.",
        "/private/var/tmp": "Temporary files that survive a restart.",
        "/opt": "Software installed outside macOS, like Homebrew.",
        "/opt/homebrew": "Homebrew and the packages installed with it.",
        "/Volumes": "Other drives.",
    ]

    /// Hidden folders macOS keeps at the top of every drive.
    private static let hiddenNotes: [String: String] = [
        ".Spotlight-V100": "Spotlight's search index for this drive. macOS rebuilds it if needed.",
        ".fseventsd": "A log of file changes macOS keeps for this drive.",
        ".Trashes": "The Trash for this drive.",
        ".DocumentRevisions-V100": "Saved versions of documents. Managed by macOS.",
        ".TemporaryItems": "Scratch files apps leave behind. Usually empty.",
        ".PKInstallSandboxManager": "Scratch space the macOS installer used.",
        ".DS_Store": "Finder's folder view settings.",
    ]

    static func note(for path: String, home: String = NSHomeDirectory()) -> String? {
        let folded = PathUtil.foldFirmlink(path)
        if folded.hasPrefix(home + "/") {
            let relative = String(folded.dropFirst(home.count + 1))
            if let note = homeNotes[relative] { return note }
        }
        return systemNotes[folded] ?? hiddenNotes[PathUtil.lastComponent(folded)]
    }
}

// MARK: - Treemap layout

nonisolated enum Squarify {
    /// Lays out rectangles for `values` (largest first) inside `bounds` with the squarified treemap algorithm.
    static func layout(values: [Double], in bounds: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, bounds.width > 1, bounds.height > 1 else { return [] }
        let scale = Double(bounds.width * bounds.height) / total
        let areas = values.map { max($0, 0) * scale }
        var rects = [CGRect](repeating: .zero, count: areas.count)
        var remaining = bounds
        var start = 0

        while start < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            guard side > 0 else { break }
            var end = start + 1
            var best = worstRatio(areas[start..<end], side: side)
            while end < areas.count {
                let candidate = worstRatio(areas[start..<(end + 1)], side: side)
                if candidate > best { break }
                best = candidate
                end += 1
            }

            let rowArea = areas[start..<end].reduce(0, +)
            if remaining.width >= remaining.height {
                // A column down the left edge.
                let width = CGFloat(rowArea / Double(remaining.height))
                var y = remaining.minY
                for index in start..<end {
                    let height = width > 0 ? CGFloat(areas[index]) / width : 0
                    rects[index] = CGRect(x: remaining.minX, y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY, width: max(0, remaining.width - width), height: remaining.height)
            } else {
                // A row along the top edge.
                let height = CGFloat(rowArea / Double(remaining.width))
                var x = remaining.minX
                for index in start..<end {
                    let width = height > 0 ? CGFloat(areas[index]) / height : 0
                    rects[index] = CGRect(x: x, y: remaining.minY, width: width, height: height)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height, width: remaining.width, height: max(0, remaining.height - height))
            }
            start = end
        }
        return rects
    }

    private static func worstRatio(_ row: ArraySlice<Double>, side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard sum > 0, let smallest = row.min(), let largest = row.max(), smallest > 0 else { return .infinity }
        return max(side * side * largest / (sum * sum), sum * sum / (side * side * smallest))
    }
}
