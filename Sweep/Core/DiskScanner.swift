import Foundation
import Darwin

// MARK: - Results

nonisolated struct Measure: Hashable, Sendable {
    var bytes: Int64 = 0
    var files: Int = 0
    /// Newest modification time of any file inside.
    var newest: Date?
    /// Items that could not be read (permissions).
    var unreadable: Int = 0

    mutating func merge(_ other: Measure) {
        bytes += other.bytes
        files += other.files
        unreadable += other.unreadable
        if let theirs = other.newest, theirs > (newest ?? .distantPast) { newest = theirs }
    }
}

/// A file or folder with its size. Folders that were walked with `retainDepth` keep their biggest children.
nonisolated struct TreeNode: Identifiable, Sendable {
    var id: String { path }
    var path: String
    var name: String
    var isDirectory: Bool
    var bytes: Int64
    var files: Int
    var newest: Date?
    var unreadable: Int
    /// nil means "not listed" (a file, or a folder deeper than the retained depth).
    var children: [TreeNode]?
    /// Children left out of `children` to keep memory small, folded into one count.
    var hiddenCount: Int = 0
    var hiddenBytes: Int64 = 0
}

// MARK: - Walker

/// Sums real disk usage (allocated blocks, like `du`) with plain POSIX calls, which is much faster
/// than `FileManager`'s enumerator. Hard links are counted once. Other volumes are not entered.
nonisolated final class DiskWalker {
    private struct FileKey: Hashable { let dev: Int32; let ino: UInt64 }
    private struct DirectoryResult {
        var measure = Measure()
        var children: [TreeNode]?
        var hiddenCount = 0
        var hiddenBytes: Int64 = 0
    }

    private var seen = Set<FileKey>()
    private var rootDevice: dev_t = 0
    private let retainDepth: Int
    private let maxChildren: Int

    /// - Parameters:
    ///   - retainDepth: folders this many levels from the start keep a list of their children. 0 keeps none.
    ///   - maxChildren: the biggest N children are kept per folder; the rest are folded into one count.
    init(retainDepth: Int = 0, maxChildren: Int = 400) {
        self.retainDepth = retainDepth
        self.maxChildren = maxChildren
    }

    func walk(path: String) -> TreeNode? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let name = PathUtil.lastComponent(path)

        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            rootDevice = info.st_dev
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0 else {
                return TreeNode(path: path, name: name, isDirectory: true, bytes: 0, files: 0, newest: nil, unreadable: 1, children: nil)
            }
            var result = walkDirectory(fd: fd, path: path, level: 0)
            result.measure.bytes += Int64(info.st_blocks) * 512
            return TreeNode(
                path: path, name: name, isDirectory: true,
                bytes: result.measure.bytes, files: result.measure.files, newest: result.measure.newest,
                unreadable: result.measure.unreadable, children: result.children,
                hiddenCount: result.hiddenCount, hiddenBytes: result.hiddenBytes
            )
        case S_IFREG:
            return TreeNode(
                path: path, name: name, isDirectory: false,
                bytes: Int64(info.st_blocks) * 512, files: 1,
                newest: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
                unreadable: 0, children: nil
            )
        default:
            return nil
        }
    }

    private func walkDirectory(fd: Int32, path: String, level: Int) -> DirectoryResult {
        guard let dir = fdopendir(fd) else {
            close(fd)
            var failed = DirectoryResult()
            failed.measure.unreadable = 1
            return failed
        }
        defer { closedir(dir) }   // also closes `fd`

        let dirFD = dirfd(dir)
        let keepChildren = level < retainDepth
        var result = DirectoryResult()
        var kids: [TreeNode] = []

        while let entry = readdir(dir) {
            if Task.isCancelled { break }

            let namePointer = UnsafeRawPointer(entry)
                .advanced(by: MemoryLayout<dirent>.offset(of: \.d_name)!)
                .assumingMemoryBound(to: CChar.self)
            if namePointer[0] == 0x2E { // "."
                if namePointer[1] == 0 { continue }
                if namePointer[1] == 0x2E, namePointer[2] == 0 { continue }
            }

            var info = stat()
            guard fstatat(dirFD, namePointer, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                result.measure.unreadable += 1
                continue
            }

            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                if info.st_dev != rootDevice { continue }   // a different volume is mounted here
                let name = String(cString: namePointer)
                let childPath = path + "/" + name
                var sub = DirectoryResult()
                let childFD = openat(dirFD, namePointer, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if childFD >= 0 {
                    sub = walkDirectory(fd: childFD, path: childPath, level: level + 1)
                } else {
                    sub.measure.unreadable = 1
                }
                sub.measure.bytes += Int64(info.st_blocks) * 512
                result.measure.merge(sub.measure)
                if keepChildren {
                    kids.append(TreeNode(
                        path: childPath, name: name, isDirectory: true,
                        bytes: sub.measure.bytes, files: sub.measure.files, newest: sub.measure.newest,
                        unreadable: sub.measure.unreadable, children: sub.children,
                        hiddenCount: sub.hiddenCount, hiddenBytes: sub.hiddenBytes
                    ))
                }

            case S_IFREG:
                if info.st_nlink > 1 {
                    let key = FileKey(dev: info.st_dev, ino: info.st_ino)
                    if !seen.insert(key).inserted { continue }   // another name for a file already counted
                }
                let bytes = Int64(info.st_blocks) * 512
                let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                result.measure.bytes += bytes
                result.measure.files += 1
                if modified > (result.measure.newest ?? .distantPast) { result.measure.newest = modified }
                if keepChildren {
                    let name = String(cString: namePointer)
                    kids.append(TreeNode(
                        path: path + "/" + name, name: name, isDirectory: false,
                        bytes: bytes, files: 1, newest: modified, unreadable: 0, children: nil
                    ))
                }

            default:
                result.measure.bytes += Int64(info.st_blocks) * 512   // symlinks and specials: their own tiny footprint
            }
        }

        if keepChildren {
            kids.sort { $0.bytes > $1.bytes }
            if kids.count > maxChildren {
                let rest = kids[maxChildren...]
                result.hiddenCount = rest.count
                result.hiddenBytes = rest.reduce(0) { $0 + $1.bytes }
                kids = Array(kids[..<maxChildren])
            }
            result.children = kids
        }
        return result
    }
}

// MARK: - Async entry points

nonisolated enum DiskScanner {
    /// Walks `path` off the calling actor. Cancelling the task stops the walk early.
    @concurrent
    static func tree(path: String, retainDepth: Int, maxChildren: Int = 400) async -> TreeNode? {
        DiskWalker(retainDepth: retainDepth, maxChildren: maxChildren).walk(path: path)
    }
}
