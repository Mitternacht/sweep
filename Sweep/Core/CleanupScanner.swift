import Foundation

nonisolated enum ScanEvent: Sendable {
    /// Discovery is done and this many things will be measured.
    case planned(total: Int)
    case progress(done: Int, total: Int)
    case found(Finding)
    /// A place that exists but Sweep isn't allowed to read yet.
    case needsAccess(String)
}

private nonisolated enum Evaluation: Sendable {
    case finding(Finding)
    case needsAccess(String)
    case dropped
}

private nonisolated struct WorkItem: Sendable {
    var rule: Rule
    var candidate: Candidate
}

private nonisolated enum Step: Sendable {
    case discovered([WorkItem])
    case evaluated(Evaluation)
}

/// Runs every rule, measures what they find and streams the results back as they finish.
nonisolated enum CleanupScanner {
    static func scan(environment: ScanEnvironment, rules: [Rule] = Catalog.rules()) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task {
                await run(environment: environment, rules: rules, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(
        environment: ScanEnvironment,
        rules: [Rule],
        continuation: AsyncStream<ScanEvent>.Continuation
    ) async {
        let env = environment

        // Places that are known up front start measuring right away.
        var queue: [WorkItem] = []
        for rule in rules {
            for candidate in rule.locate(env) { queue.append(WorkItem(rule: rule, candidate: candidate)) }
        }
        let rulesByID = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let roots = env.projectRoots

        var total = queue.count
        continuation.yield(.planned(total: total))

        // Build junk inside project folders has to be searched for. Each folder is searched on its own and its
        // results are measured as soon as it's done, so one slow drive never holds up the rest.
        let evaluationLimit = 6
        let searchLimit = 2
        await withTaskGroup(of: Step.self) { group in
            var nextRoot = 0
            var searching = 0
            var measuring = 0
            var done = 0

            while true {
                if Task.isCancelled { group.cancelAll(); break }
                while searching < searchLimit, nextRoot < roots.count {
                    let root = roots[nextRoot]
                    group.addTask {
                        let found = await ArtifactFinder.discover(roots: [root], kinds: Catalog.artifactKinds)
                        let items = found.flatMap { id, candidates in
                            candidates.compactMap { candidate in rulesByID[id].map { WorkItem(rule: $0, candidate: candidate) } }
                        }
                        return .discovered(items)
                    }
                    nextRoot += 1
                    searching += 1
                }
                while measuring < evaluationLimit, !queue.isEmpty {
                    let item = queue.removeFirst()
                    group.addTask { .evaluated(await evaluate(rule: item.rule, candidate: item.candidate, environment: env)) }
                    measuring += 1
                }
                if searching + measuring == 0 { break }
                guard let step = await group.next() else { break }

                switch step {
                case .discovered(let items):
                    searching -= 1
                    queue.append(contentsOf: items)
                    total += items.count
                    continuation.yield(.planned(total: total))
                case .evaluated(let evaluation):
                    measuring -= 1
                    done += 1
                    switch evaluation {
                    case .finding(let finding): continuation.yield(.found(finding))
                    case .needsAccess(let name): continuation.yield(.needsAccess(name))
                    case .dropped: break
                    }
                    continuation.yield(.progress(done: done, total: total))
                }
            }
        }
    }

    @concurrent
    private static func evaluate(rule: Rule, candidate: Candidate, environment env: ScanEnvironment) async -> Evaluation {
        let path = candidate.url.path
        guard let node = await DiskScanner.tree(path: path, retainDepth: 1, maxChildren: 60) else { return .dropped }
        if node.bytes == 0, node.unreadable > 0 { return .needsAccess(candidate.title) }
        guard node.bytes >= rule.minBytes else { return .dropped }
        if let minAge = rule.minAge, let newest = node.newest, env.now.timeIntervalSince(newest) < minAge { return .dropped }

        let action = candidate.actionOverride ?? rule.action
        let guardRoot = candidate.guardRoot ?? (action == .deleteContents ? candidate.url : candidate.url.deletingLastPathComponent())
        let canonical = PathUtil.canonical(path)

        let breakdown: [BreakdownItem] = (node.children ?? []).prefix(6).map { child in
            let label = candidate.childLabel?(child.name)
            return BreakdownItem(id: child.name, title: label?.title ?? child.name, detail: label?.detail, bytes: child.bytes)
        }

        return .finding(Finding(
            id: "\(rule.id)|\(canonical)",
            ruleID: rule.id,
            title: candidate.title,
            subtitle: subtitle(for: candidate, newest: node.newest, now: env.now),
            what: rule.what,
            consequence: rule.consequence,
            category: rule.category,
            safety: candidate.safetyOverride ?? rule.safety,
            url: candidate.url,
            volumeID: volumeID(for: candidate.url, in: env.volumes),
            bytes: node.bytes,
            fileCount: node.files,
            lastChanged: node.newest,
            action: action,
            guardRoot: guardRoot,
            leafNames: candidate.leafNames,
            leafSuffix: candidate.leafSuffix,
            directChildOnly: candidate.directChildOnly,
            blockedBy: blockers(for: rule, candidate: candidate, canonicalPath: canonical, running: env.runningApps),
            breakdown: breakdown
        ))
    }

    // MARK: Pieces

    static func subtitle(for candidate: Candidate, newest: Date?, now: Date) -> String {
        var parts: [String] = []
        if let text = candidate.subtitle { parts.append(text) }
        if let newest {
            parts.append("Last changed " + newest.formatted(.relative(presentation: .named, unitsStyle: .wide)))
        }
        return parts.joined(separator: " · ")
    }

    static func volumeID(for url: URL, in volumes: [Volume]) -> String {
        let path = PathUtil.canonical(url.path)
        let external = volumes
            .filter { !$0.isInternal && PathUtil.isInside(path, of: $0.mountURL.path) }
            .max { $0.mountURL.path.count < $1.mountURL.path.count }
        return external?.id ?? volumes.first(where: \.isInternal)?.id ?? "/"
    }

    static func blockers(for rule: Rule, candidate: Candidate, canonicalPath: String, running: [RunningApp]) -> [Blocker] {
        var result: [Blocker] = []
        func add(_ blocker: Blocker) {
            if !result.contains(where: { $0.message == blocker.message }) { result.append(blocker) }
        }
        for id in rule.blockedByBundleIDs {
            if let app = running.first(where: { $0.bundleID == id }) {
                add(Blocker(appName: app.name, message: "Quit \(app.name) first"))
            }
        }
        if let owner = candidate.ownerBundleID, let app = running.first(where: { $0.bundleID == owner }) {
            add(Blocker(appName: app.name, message: "Quit \(app.name) first"))
        }
        for app in running where app.paths.contains(where: { PathUtil.isInside($0, of: canonicalPath) }) {
            add(Blocker(appName: app.name, message: "In use by \(app.name)"))
        }
        return result
    }
}
