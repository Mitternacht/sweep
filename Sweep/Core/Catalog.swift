import Foundation

// MARK: - Scan inputs

nonisolated struct RunningApp: Hashable, Sendable {
    var name: String
    var bundleID: String?
    /// Canonical paths of the app bundle and its executable.
    var paths: [String]
}

nonisolated struct ScanEnvironment: Sendable {
    var home: URL
    var volumes: [Volume]
    /// Where Xcode keeps build output. Can be on an external drive.
    var derivedDataFolders: [URL]
    var runningApps: [RunningApp]
    /// Bundle id -> app name, for the folders in ~/Library/Caches.
    var appNames: [String: String]
    /// Folders searched for build junk next to project files.
    var projectRoots: [URL]
    var discoveries: [String: [Candidate]] = [:]
    var now: Date = .now
}

/// One concrete thing a rule found, before it is measured.
nonisolated struct Candidate: Sendable {
    var url: URL
    var title: String
    var subtitle: String? = nil
    var guardRoot: URL? = nil
    var leafNames: Set<String>? = nil
    var leafSuffix: String? = nil
    var directChildOnly: Bool = false
    var safetyOverride: Safety? = nil
    var actionOverride: CleanAction? = nil
    var ownerBundleID: String? = nil
    /// Turns a child's raw name (a UUID, say) into something a person can read.
    var childLabel: (@Sendable (String) -> (title: String, detail: String?)?)? = nil
}

/// A kind of space Sweep knows about: what it is, how safe it is, and how to find it.
nonisolated struct Rule: Sendable {
    var id: String
    var category: Category
    var safety: Safety
    var what: String
    var consequence: String
    var action: CleanAction
    var blockedByBundleIDs: [String] = []
    var minBytes: Int64 = 8_000_000
    var minAge: TimeInterval? = nil
    var locate: @Sendable (ScanEnvironment) -> [Candidate]
}

// MARK: - The catalog

nonisolated enum Catalog {
    private static let xcodeID = "com.apple.dt.Xcode"
    private static let simulatorID = "com.apple.iphonesimulator"
    private static let day: TimeInterval = 86_400

    static func rules() -> [Rule] {
        [derivedData, previews, testDevices, deviceSupport, archives, documentationCache, coreDeviceDeltas, simulators]
        + packageCaches
        + [appCaches, appLogs, trash, tempFiles, installers, deviceBackups]
        + artifactKinds.map(artifactRule)
    }

    // MARK: Xcode

    static let derivedData = Rule(
        id: "xcode.derived-data", category: .xcode, safety: .safe,
        what: "Build output Xcode keeps for each project: compiled code, search indexes and test results.",
        consequence: "The next build of that project starts from scratch, so it takes longer once.",
        action: .deleteItem, blockedByBundleIDs: [xcodeID], minBytes: 20_000_000,
        locate: { env in
            env.derivedDataFolders.flatMap { folder in
                subdirectories(of: folder).map { derivedDataCandidate($0, in: folder) }
            }
        }
    )

    static let previews = Rule(
        id: "xcode.previews", category: .xcode, safety: .safe,
        what: "Cached builds Xcode uses to show SwiftUI previews.",
        consequence: "The first preview afterwards is a little slower.",
        action: .deleteContents, blockedByBundleIDs: [xcodeID],
        locate: { env in
            whole(env.home.appendingPathComponent("Library/Developer/Xcode/UserData/Previews"), title: "Xcode previews", subtitle: "Preview simulators")
        }
    )

    static let testDevices = Rule(
        id: "xcode.test-devices", category: .xcode, safety: .safe,
        what: "Throwaway simulators Xcode creates for tests and previews.",
        consequence: "Xcode makes new ones whenever it needs them.",
        action: .deleteContents, blockedByBundleIDs: [xcodeID, simulatorID],
        locate: { env in
            whole(env.home.appendingPathComponent("Library/Developer/XCTestDevices"), title: "Test simulators", subtitle: "Created by Xcode for tests")
        }
    )

    static let deviceSupport = Rule(
        id: "xcode.device-support", category: .xcode, safety: .safe,
        what: "Debug symbols Xcode downloaded for one device and one OS version.",
        consequence: "Xcode downloads them again the next time you connect that device. That takes a few minutes.",
        action: .deleteItem, blockedByBundleIDs: [xcodeID], minBytes: 100_000_000,
        locate: { env in
            ["iOS", "watchOS", "macOS", "tvOS", "visionOS", "xrOS"].flatMap { platform -> [Candidate] in
                let folder = env.home.appendingPathComponent("Library/Developer/Xcode/\(platform) DeviceSupport")
                return subdirectories(of: folder).map {
                    Candidate(url: $0, title: $0.lastPathComponent, subtitle: "\(platform) debug symbols", guardRoot: folder, directChildOnly: true)
                }
            }
        }
    )

    static let archives = Rule(
        id: "xcode.archives", category: .xcode, safety: .review,
        what: "Archived app builds you made to share or ship. They also hold the debug symbols for those releases.",
        consequence: "Gone for good. Keep any you might need to read a crash report.",
        action: .deleteItem, blockedByBundleIDs: [xcodeID], minBytes: 50_000_000,
        locate: { env in
            let folder = env.home.appendingPathComponent("Library/Developer/Xcode/Archives")
            return subdirectories(of: folder).map {
                Candidate(url: $0, title: "Archives from \($0.lastPathComponent)", subtitle: "Xcode archives", guardRoot: folder, directChildOnly: true)
            }
        }
    )

    static let documentationCache = Rule(
        id: "xcode.documentation", category: .xcode, safety: .safe,
        what: "Offline documentation and simulator caches Xcode saved.",
        consequence: "Xcode fetches what it needs again.",
        action: .deleteContents,
        locate: { env in
            whole(env.home.appendingPathComponent("Library/Developer/Xcode/DocumentationCache"), title: "Xcode documentation cache")
            + whole(env.home.appendingPathComponent("Library/Developer/CoreSimulator/Caches"), title: "Simulator caches")
        }
    )

    static let coreDeviceDeltas = Rule(
        id: "xcode.install-deltas", category: .xcode, safety: .safe,
        what: "Update files Xcode keeps for installing apps on a connected iPhone or iPad.",
        consequence: "The next install to a device is slower once.",
        action: .deleteContents, blockedByBundleIDs: [xcodeID],
        locate: { env in
            whole(
                env.home.appendingPathComponent("Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/Library/Caches/AppInstallationBinaryDeltas"),
                title: "Device install cache", subtitle: "Used when installing to an iPhone or iPad"
            )
        }
    )

    static let simulators = Rule(
        id: "simulators.devices", category: .simulators, safety: .review,
        what: "Every iOS, watchOS and visionOS simulator, with the apps and data installed in each.",
        consequence: "Apps and data inside the simulators are erased. The simulators themselves stay.",
        action: .resetSimulators, blockedByBundleIDs: [xcodeID, simulatorID], minBytes: 100_000_000,
        locate: { env in
            let devices = env.home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
            guard isDirectory(devices) else { return [] }
            return [Candidate(
                url: devices, title: "Simulators", subtitle: "Installed apps and their data",
                guardRoot: devices, actionOverride: .resetSimulators, childLabel: simulatorLabel(devices: devices)
            )]
        }
    )

    // MARK: Package manager caches

    private struct CacheSpec {
        var id: String
        var path: String
        var title: String
        var what: String
        var consequence: String
        var safety: Safety = .safe
    }

    private static let packageCacheSpecs: [CacheSpec] = [
        CacheSpec(id: "cache.homebrew", path: "Library/Caches/Homebrew", title: "Homebrew downloads",
                  what: "Installers Homebrew keeps after it installs a package.", consequence: "Homebrew downloads them again if it needs them."),
        CacheSpec(id: "cache.npm", path: ".npm/_cacache", title: "npm cache",
                  what: "Packages npm downloaded before.", consequence: "npm fetches them again when a project needs them."),
        CacheSpec(id: "cache.yarn", path: "Library/Caches/Yarn", title: "Yarn cache",
                  what: "Packages Yarn downloaded before.", consequence: "Yarn fetches them again when a project needs them."),
        CacheSpec(id: "cache.pip", path: "Library/Caches/pip", title: "pip cache",
                  what: "Python packages pip downloaded before.", consequence: "pip fetches them again when needed."),
        CacheSpec(id: "cache.uv", path: ".cache/uv", title: "uv cache",
                  what: "Python packages and builds uv saved.", consequence: "uv fetches them again when needed."),
        CacheSpec(id: "cache.swiftpm", path: "Library/Caches/org.swift.swiftpm", title: "Swift Package Manager cache",
                  what: "Package sources and manifests Swift downloaded.", consequence: "The next package resolve is slower once."),
        CacheSpec(id: "cache.cocoapods", path: "Library/Caches/CocoaPods", title: "CocoaPods cache",
                  what: "Pods CocoaPods downloaded before.", consequence: "CocoaPods fetches them again when needed."),
        CacheSpec(id: "cache.gradle", path: ".gradle/caches", title: "Gradle cache",
                  what: "Libraries and build data Gradle saved.", consequence: "Gradle downloads them again on the next build."),
        CacheSpec(id: "cache.cargo", path: ".cargo/registry/cache", title: "Cargo downloads",
                  what: "Rust crates Cargo downloaded before.", consequence: "Cargo downloads them again when needed."),
        CacheSpec(id: "cache.go", path: "Library/Caches/go-build", title: "Go build cache",
                  what: "Compiled Go packages.", consequence: "The next Go build is slower once."),
        CacheSpec(id: "cache.huggingface", path: ".cache/huggingface", title: "Hugging Face models",
                  what: "AI models and datasets you downloaded from Hugging Face.",
                  consequence: "They download again the next time a script needs them. Some are very large.", safety: .review),
    ]

    /// Cache folders that have their own rule, so the generic app-cache rule skips them.
    private static let ownedCacheFolders: Set<String> = ["Homebrew", "Yarn", "pip", "org.swift.swiftpm", "CocoaPods", "go-build"]

    static let packageCaches: [Rule] = packageCacheSpecs.map { spec in
        Rule(id: spec.id, category: .packages, safety: spec.safety, what: spec.what, consequence: spec.consequence,
             action: .deleteContents, locate: { env in
            whole(env.home.appendingPathComponent(spec.path), title: spec.title, subtitle: "Package cache")
        })
    }

    // MARK: Apps

    private static let sensitiveCacheNames: Set<String> = ["CloudKit", "GeoServices", "FamilyCircle", "Metadata"]

    static let appCaches = Rule(
        id: "apps.caches", category: .appCaches, safety: .safe,
        what: "Temporary files an app saved so it can run faster.",
        consequence: "The app makes them again. It can feel slower the first time you open it.",
        action: .deleteItem, minBytes: 50_000_000,
        locate: { env in
            let caches = env.home.appendingPathComponent("Library/Caches")
            return subdirectories(of: caches).compactMap { folder in
                let name = folder.lastPathComponent
                if ownedCacheFolders.contains(name) { return nil }
                let owner = ownerBundleID(fromCacheFolder: name)
                let appName = env.appNames[owner]
                let needsReview = name.hasPrefix("com.apple.") || sensitiveCacheNames.contains(name)
                let friendly = friendlyName(forCacheFolder: name)
                return Candidate(
                    url: folder,
                    title: appName ?? friendly,
                    subtitle: appName == nil && friendly != name ? "App cache · \(name)" : "App cache",
                    guardRoot: caches, directChildOnly: true,
                    safetyOverride: needsReview ? .review : nil,
                    ownerBundleID: owner
                )
            }
        }
    )

    static let appLogs = Rule(
        id: "apps.logs", category: .appCaches, safety: .safe,
        what: "Log files apps and Xcode wrote while running.",
        consequence: "Nothing breaks. You lose old logs.",
        action: .deleteContents, minBytes: 20_000_000,
        locate: { env in whole(env.home.appendingPathComponent("Library/Logs"), title: "App logs") }
    )

    static let trash = Rule(
        id: "system.trash", category: .trash, safety: .safe,
        what: "Files you already moved to the Trash.",
        consequence: "They're gone for good.",
        action: .deleteContents, minBytes: 1_000_000,
        locate: { env in
            var found = whole(env.home.appendingPathComponent(".Trash"), title: "Trash", subtitle: "On this Mac")
            let uid = String(getuid())
            for volume in env.volumes where !volume.isInternal {
                found += whole(volume.mountURL.appendingPathComponent(".Trashes/\(uid)"), title: "Trash", subtitle: "On \(volume.name)")
            }
            return found
        }
    )

    static let tempFiles = Rule(
        id: "system.temp", category: .temp, safety: .review,
        what: "Leftovers from builds and test runs in the system temp folders.",
        consequence: "Anything still using them could break. Sweep skips folders an open app is using.",
        action: .deleteItem, minBytes: 50_000_000, minAge: day,
        locate: { _ in
            ["/private/tmp", "/private/var/tmp"].flatMap { path -> [Candidate] in
                let folder = URL(fileURLWithPath: path)
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
                return names
                    .filter { !$0.hasPrefix("claude-") && !$0.hasPrefix("com.apple.") && !$0.hasPrefix(".") }
                    .map { Candidate(url: folder.appendingPathComponent($0), title: $0, subtitle: "Temporary files in \(path)", guardRoot: folder, directChildOnly: true) }
            }
        }
    )

    static let installers = Rule(
        id: "downloads.installers", category: .downloads, safety: .review,
        what: "Installer files (.dmg, .pkg, .iso) sitting in your Downloads folder.",
        consequence: "Gone for good. You can download them again.",
        action: .deleteItem, minBytes: 50_000_000, minAge: 14 * day,
        locate: { env in
            let folder = env.home.appendingPathComponent("Downloads")
            let wanted: Set<String> = ["dmg", "pkg", "iso", "xip"]
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
            return names.filter { wanted.contains(($0 as NSString).pathExtension.lowercased()) }.map {
                Candidate(url: folder.appendingPathComponent($0), title: $0, subtitle: "Installer in Downloads", guardRoot: folder, directChildOnly: true)
            }
        }
    )

    static let deviceBackups = Rule(
        id: "backups.ios", category: .backups, safety: .review,
        what: "A full backup of an iPhone or iPad made through Finder.",
        consequence: "Gone for good. You can't restore that device from it afterwards.",
        action: .deleteItem, minBytes: 100_000_000,
        locate: { env in
            let folder = env.home.appendingPathComponent("Library/Application Support/MobileSync/Backup")
            return subdirectories(of: folder).map { backup in
                let info = readPlist(backup.appendingPathComponent("Info.plist"))
                let device = info?["Device Name"] as? String
                let version = (info?["Product Version"] as? String).map { "iOS \($0)" }
                let date = (info?["Last Backup Date"] as? Date).map { "Backed up \($0.formatted(date: .abbreviated, time: .omitted))" }
                return Candidate(
                    url: backup, title: device ?? "Device backup",
                    subtitle: ["Device backup", version, date].compactMap { $0 }.joined(separator: " · "),
                    guardRoot: folder, directChildOnly: true
                )
            }
        }
    )

    // MARK: Build junk inside project folders

    static let artifactKinds: [ArtifactKind] = [
        ArtifactKind(
            ruleID: "project.node-modules", label: "node_modules", category: .projects, safety: .safe,
            what: "JavaScript packages for one project.", consequence: "Run npm install in that project to bring them back.",
            minBytes: 20_000_000, matches: { $0 == "node_modules" }, manifests: ["package.json"], leafNames: ["node_modules"], leafSuffix: nil),
        ArtifactKind(
            ruleID: "project.swiftpm-build", label: ".build", category: .projects, safety: .safe,
            what: "Swift Package Manager build output for one project.", consequence: "It rebuilds the next time you build that package.",
            minBytes: 20_000_000, matches: { $0 == ".build" }, manifests: ["Package.swift"], leafNames: [".build"], leafSuffix: nil),
        ArtifactKind(
            ruleID: "project.pods", label: "Pods", category: .projects, safety: .safe,
            what: "CocoaPods dependencies for one project.", consequence: "Run pod install in that project to restore them.",
            minBytes: 20_000_000, matches: { $0 == "Pods" }, manifests: ["Podfile"], leafNames: ["Pods"], leafSuffix: nil),
        ArtifactKind(
            ruleID: "project.derived-data", label: "DerivedData inside the project", category: .projects, safety: .safe,
            what: "Xcode build output stored inside a project folder.", consequence: "The next build of that project starts from scratch.",
            minBytes: 20_000_000, matches: { $0 == "DerivedData" }, manifests: ["*.xcodeproj", "*.xcworkspace"], leafNames: ["DerivedData"], leafSuffix: nil),
        ArtifactKind(
            ruleID: "project.cargo-target", label: "Rust target folder", category: .projects, safety: .safe,
            what: "Rust build output for one project.", consequence: "cargo build creates it again.",
            minBytes: 20_000_000, matches: { $0 == "target" }, manifests: ["Cargo.toml"], leafNames: ["target"], leafSuffix: nil),
        ArtifactKind(
            ruleID: "project.next", label: "Next.js build cache", category: .projects, safety: .safe,
            what: "Next.js build output for one project.", consequence: "It rebuilds the next time you run the project.",
            minBytes: 20_000_000, matches: { $0 == ".next" }, manifests: ["package.json"], leafNames: [".next"], leafSuffix: nil),
        ArtifactKind(
            ruleID: "project.python-venv", label: "Python virtual environment", category: .projects, safety: .review,
            what: "The Python packages installed for one project.", consequence: "Recreate it from your requirements file.",
            minBytes: 50_000_000, matches: { $0 == ".venv" || $0 == "venv" }, manifests: ["pyproject.toml", "requirements.txt"], leafNames: [".venv", "venv"], leafSuffix: nil),
        ArtifactKind(
            ruleID: "project.xcresult", label: "Xcode test results", category: .projects, safety: .review,
            what: "Saved results from an Xcode test run, with logs and screenshots.", consequence: "Gone for good. Keep any you still want to look at.",
            minBytes: 50_000_000, matches: { $0.hasSuffix(".xcresult") }, manifests: [], leafNames: nil, leafSuffix: ".xcresult"),
        ArtifactKind(
            ruleID: "project.xcarchive", label: "Xcode archive", category: .projects, safety: .review,
            what: "An archived app build with its debug symbols.", consequence: "Gone for good. Keep it if you might need to read a crash report from that build.",
            minBytes: 50_000_000, matches: { $0.hasSuffix(".xcarchive") }, manifests: [], leafNames: nil, leafSuffix: ".xcarchive"),
    ]

    private static func artifactRule(_ kind: ArtifactKind) -> Rule {
        let id = kind.ruleID
        return Rule(
            id: id, category: kind.category, safety: kind.safety, what: kind.what, consequence: kind.consequence,
            action: .deleteItem, minBytes: kind.minBytes,
            locate: { env in env.discoveries[id] ?? [] }
        )
    }

    // MARK: Helpers

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func whole(_ url: URL, title: String, subtitle: String? = nil) -> [Candidate] {
        guard isDirectory(url) else { return [] }
        return [Candidate(url: url, title: title, subtitle: subtitle, guardRoot: url)]
    }

    private static func subdirectories(of url: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return [] }
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Xcode names each folder `ProjectName-<28 letters>`. Drop the letters.
    private static func tidyDerivedName(_ name: String) -> String {
        guard let dash = name.lastIndex(of: "-") else { return name }
        let tail = name[name.index(after: dash)...]
        let looksLikeHash = tail.count == 28 && tail.allSatisfy { $0.isLowercase && $0.isLetter }
        return looksLikeHash ? String(name[..<dash]).replacingOccurrences(of: "_", with: " ") : name
    }

    private static func derivedDataCandidate(_ child: URL, in folder: URL) -> Candidate {
        let name = child.lastPathComponent
        let shared: [String: String] = [
            "ModuleCache.noindex": "Module cache", "SDKStatCaches.noindex": "SDK stat cache",
            "CompilationCache.noindex": "Compilation cache", "SDKExplicitPrecompiledModules": "Precompiled SDK modules",
            "SymbolCache.noindex": "Symbol cache",
        ]
        if let title = shared[name] {
            return Candidate(url: child, title: title, subtitle: "Shared by every project", guardRoot: folder, directChildOnly: true)
        }
        if let plist = readPlist(child.appendingPathComponent("info.plist")), let workspace = plist["WorkspacePath"] as? String {
            let project = URL(fileURLWithPath: workspace).deletingPathExtension().lastPathComponent
            let location = PathUtil.lastComponent(PathUtil.parent(of: workspace))
            return Candidate(url: child, title: project, subtitle: "Build output · project in \(location)", guardRoot: folder, directChildOnly: true)
        }
        return Candidate(url: child, title: tidyDerivedName(name), subtitle: "Xcode build output", guardRoot: folder, directChildOnly: true)
    }

    private static func simulatorLabel(devices: URL) -> @Sendable (String) -> (title: String, detail: String?)? {
        { uuid in
            let plist = readPlist(devices.appendingPathComponent(uuid).appendingPathComponent("device.plist"))
            guard let name = plist?["name"] as? String else { return nil }
            return (name, (plist?["runtime"] as? String).map(prettyRuntime))
        }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-27-2` -> `iOS 27.2`
    static func prettyRuntime(_ identifier: String) -> String {
        let tail = identifier.components(separatedBy: ".").last ?? identifier
        let parts = tail.split(separator: "-").map(String.init)
        guard let platform = parts.first, parts.count > 1 else { return tail }
        return platform + " " + parts.dropFirst().joined(separator: ".")
    }

    private static func ownerBundleID(fromCacheFolder name: String) -> String {
        name.hasSuffix(".ShipIt") ? String(name.dropLast(".ShipIt".count)) : name
    }

    private static func friendlyName(forCacheFolder name: String) -> String {
        let parts = name.split(separator: ".")
        return parts.count >= 3 ? String(parts.last ?? Substring(name)) : name
    }
}
