import Foundation

/// Carries out cleanups. Every removal is validated by `DeletionGuard` first.
nonisolated enum Cleaner {
    static func run(items: [CleanItem], guardrail: DeletionGuard = DeletionGuard()) -> AsyncStream<CleanEvent> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(.started(total: items.count))
                for (index, item) in items.enumerated() {
                    if Task.isCancelled { break }
                    continuation.yield(.began(title: item.finding.title, index: index))
                    continuation.yield(.finished(await perform(item, guardrail: guardrail)))
                }
                continuation.yield(.done)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @concurrent
    static func perform(_ item: CleanItem, guardrail: DeletionGuard) async -> CleanResult {
        let finding = item.finding
        func result(_ outcome: CleanOutcome) -> CleanResult {
            CleanResult(id: finding.id, title: finding.title, bytes: finding.bytes, outcome: outcome)
        }

        guard finding.safety != .protected else { return result(.refused("Protected.")) }
        if finding.action == .resetSimulators { return result(resetSimulators()) }

        do {
            let contentsOnly = finding.action == .deleteContents
            let target = try guardrail.validate(
                url: finding.url, root: finding.guardRoot,
                leafNames: finding.leafNames, leafSuffix: finding.leafSuffix,
                directChildOnly: finding.directChildOnly, contents: contentsOnly
            )
            if contentsOnly {
                if let problem = removeContents(ofFolderAt: target, method: item.method, guardrail: guardrail) {
                    return result(.failed(problem))
                }
            } else {
                try remove(URL(fileURLWithPath: target), method: item.method)
            }
            return result(item.method == .moveToTrash ? .trashed : .removed)
        } catch GuardViolation.missing {
            return result(.alreadyGone)
        } catch let violation as GuardViolation {
            return result(.refused(violation.localizedDescription))
        } catch {
            return result(.failed(error.localizedDescription))
        }
    }

    // MARK: Removing

    /// Returns a problem description when something could not be removed, nil on success.
    private static func removeContents(ofFolderAt path: String, method: CleanMethod, guardrail: DeletionGuard) -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return "Couldn't open the folder. Sweep may need Full Disk Access."
        }
        var failures: [String] = []
        for name in names {
            if Task.isCancelled { break }
            let childPath = path + "/" + name
            do {
                _ = try guardrail.validate(url: URL(fileURLWithPath: childPath), root: URL(fileURLWithPath: path), directChildOnly: true)
                try remove(URL(fileURLWithPath: childPath), method: method)
            } catch GuardViolation.missing {
                continue
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }
        guard let first = failures.first else { return nil }
        return failures.count == 1 ? first : "\(first) (and \(failures.count - 1) more)"
    }

    private static func remove(_ url: URL, method: CleanMethod) throws {
        let fileManager = FileManager.default
        switch method {
        case .moveToTrash:
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        case .deletePermanently:
            do {
                try fileManager.removeItem(at: url)
            } catch {
                // Read-only folders and locked files stop a plain delete. Unlock, then try once more.
                _ = run("/bin/chmod", ["-R", "u+w", url.path])
                _ = run("/usr/bin/chflags", ["-R", "nouchg", url.path])
                try fileManager.removeItem(at: url)
            }
        }
    }

    private static func resetSimulators() -> CleanOutcome {
        _ = run("/usr/bin/xcrun", ["simctl", "shutdown", "all"])
        _ = run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"])
        let erase = run("/usr/bin/xcrun", ["simctl", "erase", "all"])
        guard erase.status == 0 else {
            let message = erase.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(message.isEmpty ? "simctl couldn't erase the simulators." : message)
        }
        return .removed
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
