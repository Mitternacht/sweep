import AppKit
import Darwin

// MARK: - Disk space

nonisolated enum DiskSpace {
    /// Real free blocks, the same number `df` shows.
    static func stats(at path: String) -> (total: Int64, free: Int64)? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let blockSize = Int64(info.f_bsize)
        return (Int64(info.f_blocks) * blockSize, Int64(info.f_bavail) * blockSize)
    }
}

nonisolated enum VolumeProvider {
    /// The startup disk first, then every browsable local drive under /Volumes.
    static func volumes() -> [Volume] {
        var result: [Volume] = []
        let boot = URL(fileURLWithPath: "/")
        let bootName = (try? boot.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
        if let stats = DiskSpace.stats(at: PathUtil.dataPrefix) {
            result.append(Volume(
                id: "/", name: bootName, mountURL: boot, scanRoot: URL(fileURLWithPath: PathUtil.dataPrefix),
                totalBytes: stats.total, freeBytes: stats.free, isInternal: true
            ))
        }

        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeIsBrowsableKey]
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        for url in mounted where url.path.hasPrefix("/Volumes/") {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsLocal ?? true, values?.volumeIsBrowsable ?? true else { continue }
            if PathUtil.realPath(url.path) == "/" { continue }   // the startup disk's alias
            guard let stats = DiskSpace.stats(at: url.path) else { continue }
            result.append(Volume(
                id: url.path, name: values?.volumeName ?? url.lastPathComponent, mountURL: url, scanRoot: url,
                totalBytes: stats.total, freeBytes: stats.free, isInternal: false
            ))
        }
        return result
    }
}

// MARK: - Permissions

nonisolated enum Permissions {
    /// The system TCC database can only be opened with Full Disk Access.
    static func hasFullDiskAccess() -> Bool {
        let probe = "/Library/Application Support/com.apple.TCC/TCC.db"
        let descriptor = open(probe, O_RDONLY)
        if descriptor >= 0 {
            close(descriptor)
            return true
        }
        return errno != EPERM && errno != EACCES
    }
}

// MARK: - Running apps

/// Reads what's running. Lives on the main actor because it uses AppKit.
enum RunningApps {
    static func snapshot() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.bundleIdentifier != nil || app.executableURL != nil else { return nil }
            var paths: [String] = []
            if let bundle = app.bundleURL { paths.append(PathUtil.canonical(bundle.path)) }
            if let executable = app.executableURL { paths.append(PathUtil.canonical(executable.path)) }
            let name = app.localizedName ?? app.bundleIdentifier ?? "Another app"
            return RunningApp(name: name, bundleID: app.bundleIdentifier, paths: paths)
        }
    }

    /// Display names for bundle ids that are installed, for labelling cache folders.
    static func appNames(forBundleIDs identifiers: [String]) -> [String: String] {
        var names: [String: String] = [:]
        for identifier in identifiers where identifier.contains(".") {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { continue }
            names[identifier] = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return names
    }
}

// MARK: - Xcode settings

nonisolated enum XcodePreferences {
    /// Where Xcode puts build output: its default folder plus a custom location if one is set.
    static func derivedDataFolders(home: URL) -> [URL] {
        var folders = [home.appendingPathComponent("Library/Developer/Xcode/DerivedData")]
        let custom = CFPreferencesCopyAppValue("IDECustomDerivedDataLocation" as CFString, "com.apple.dt.Xcode" as CFString) as? String
        if let custom, !custom.isEmpty { folders.append(URL(fileURLWithPath: custom)) }

        var seen = Set<String>()
        return folders.filter { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
            return seen.insert(PathUtil.canonical(url.path)).inserted
        }
    }
}
