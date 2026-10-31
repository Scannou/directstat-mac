import Darwin
import Foundation
import Synchronization

public struct ScanProgress: Sendable {
    public var files = 0
    public var dirs = 0
    public var bytes: Int64 = 0
    public var unreadable = 0
    public var currentPath = ""
    public init() {}
}

// getattrlistbulk attribute bits (from <sys/attr.h>), typed as UInt32.
private let kCmnName: UInt32 = 0x0000_0001
private let kCmnObjType: UInt32 = 0x0000_0008
private let kCmnFileID: UInt32 = 0x0200_0000
private let kCmnError: UInt32 = 0x2000_0000
private let kCmnReturnedAttrs: UInt32 = 0x8000_0000
private let kFileLinkCount: UInt32 = 0x0000_0001
private let kFileAllocSize: UInt32 = 0x0000_0004
private let kTypeDir: UInt32 = 2  // VDIR

/// Walks a folder tree in parallel and builds a `ScanResult`.
public final class DiskScanner: @unchecked Sendable {
    public let rootPath: String
    public let displayName: String
    public let threadCount: Int
    public let stayOnVolume: Bool

    private let fileCounter = Atomic<Int>(0)
    private let dirCounter = Atomic<Int>(0)
    private let byteCounter = Atomic<Int64>(0)
    private let unreadableCounter = Atomic<Int>(0)
    private let cancelled = Atomic<Bool>(false)
    private let current = Mutex<String>("")
    private let queueBox = Mutex<WorkQueue?>(nil)
    private let seenHardLinks = Mutex<Set<UInt64>>([])
    private var rootDev: dev_t = 0
    /// Where other volumes are mounted. Skipped without opening them: opening
    /// a network mount (even macOS's automatic /home) triggers a permission prompt.
    private var mountPoints: Set<String> = []

    public init(path: String, threadCount: Int? = nil, stayOnVolume: Bool = true) {
        let resolved = DiskScanner.resolveRoot(path)
        rootPath = resolved.path
        displayName = resolved.name
        self.threadCount = threadCount ?? max(4, min(8, ProcessInfo.processInfo.activeProcessorCount / 2 + 1))
        self.stayOnVolume = stayOnVolume
    }

    /// "/" means the whole disk. On modern macOS the user's data lives on the
    /// separate Data volume, so scan that instead of the read-only system volume.
    public static func resolveRoot(_ path: String) -> (path: String, name: String) {
        var p = (path as NSString).expandingTildeInPath
        p = (p as NSString).resolvingSymlinksInPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        let data = "/System/Volumes/Data"
        if p == "/" || p == data, FileManager.default.fileExists(atPath: data) {
            let name = VolumeInfo.forPath("/")?.name ?? "Macintosh HD"
            return (data, name)
        }
        if p == NSHomeDirectory() { return (p, "Home (\(NSUserName()))") }
        return (p, (p as NSString).lastPathComponent)
    }

    public var progress: ScanProgress {
        var p = ScanProgress()
        p.files = fileCounter.load(ordering: .relaxed)
        p.dirs = dirCounter.load(ordering: .relaxed)
        p.bytes = byteCounter.load(ordering: .relaxed)
        p.unreadable = unreadableCounter.load(ordering: .relaxed)
        p.currentPath = current.withLock { $0 }
        return p
    }

    public func cancel() {
        cancelled.store(true, ordering: .relaxed)
        queueBox.withLock { $0?.stop() }
    }

    /// Blocks until the scan finishes. Returns nil if cancelled.
    public func run() -> ScanResult? {
        let start = Date()
        var st = stat()
        let root = DirNode(name: rootPath, parent: nil)
        let types = TypeTable()
        if lstat(rootPath, &st) == 0 {
            rootDev = st.st_dev
            if stayOnVolume {
                mountPoints = DiskScanner.mountPointsToSkip(mounts: DiskScanner.currentMounts(), root: rootPath)
            }
            let queue = WorkQueue(root: Job(node: root, path: rootPath))
            queueBox.withLock { $0 = queue }
            if cancelled.load(ordering: .relaxed) { return nil }

            let group = DispatchGroup()
            for _ in 0..<threadCount {
                group.enter()
                let t = Thread { [self] in
                    self.worker(queue: queue, types: types)
                    group.leave()
                }
                t.stackSize = 1 << 20
                t.qualityOfService = .userInitiated
                t.start()
            }
            group.wait()
            queueBox.withLock { $0 = nil }
        } else {
            root.unreadable = true
            unreadableCounter.add(1, ordering: .relaxed)
        }
        if cancelled.load(ordering: .relaxed) { return nil }

        let names = types.names
        var typeInfos = names.enumerated().map {
            TypeInfo(id: UInt16($0.offset), ext: $0.element, size: 0, count: 0)
        }
        DiskScanner.finalize(root, types: &typeInfos)
        return ScanResult(
            root: root, rootPath: rootPath, displayName: displayName,
            duration: Date().timeIntervalSince(start),
            unreadableCount: unreadableCounter.load(ordering: .relaxed),
            types: typeInfos)
    }

    // MARK: - Workers

    private func worker(queue: WorkQueue, types: TypeTable) {
        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }
        var cache: [String: UInt16] = [:]
        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr = kCmnReturnedAttrs | kCmnName | kCmnError | kCmnObjType | kCmnFileID
        al.fileattr = kFileLinkCount | kFileAllocSize

        while let job = queue.next() {
            if cancelled.load(ordering: .relaxed) { queue.finish([]); break }
            let kids = scanDirectory(job, buf: buf, bufSize: bufSize, attrs: &al,
                                     cache: &cache, types: types)
            queue.finish(kids)
        }
    }

    private func scanDirectory(_ job: Job, buf: UnsafeMutableRawPointer, bufSize: Int,
                               attrs: inout attrlist, cache: inout [String: UInt16],
                               types: TypeTable) -> [Job] {
        let node = job.node
        let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            node.unreadable = true
            unreadableCounter.add(1, ordering: .relaxed)
            return []
        }
        defer { close(fd) }

        if stayOnVolume {
            var st = stat()
            if fstat(fd, &st) == 0 && st.st_dev != rootDev {
                node.otherVolume = true
                return []
            }
        }

        var kids: [Job] = []
        var subdirs: [DirNode] = []
        var files: [FileEntry] = []
        var bytes: Int64 = 0
        let base = job.path == "/" ? "/" : job.path + "/"

        while true {
            let count = getattrlistbulk(fd, &attrs, buf, bufSize, 0)
            if count < 0 {
                if errno == EINTR { continue }
                node.unreadable = true
                unreadableCounter.add(1, ordering: .relaxed)
                break
            }
            if count == 0 { break }

            var entry = UnsafeRawPointer(buf)
            for _ in 0..<Int(count) {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var p = entry + 4
                let common = p.loadUnaligned(as: UInt32.self)
                let fileAttrs = (p + 12).loadUnaligned(as: UInt32.self)
                p += MemoryLayout<attribute_set_t>.size

                if common & kCmnError != 0 {
                    let err = p.loadUnaligned(as: UInt32.self)
                    p += 4
                    if err != 0 { continue }
                }
                guard common & kCmnName != 0, common & kCmnObjType != 0 else { continue }

                let nameOffset = Int(p.loadUnaligned(as: Int32.self))
                let nameLength = Int((p + 4).loadUnaligned(as: UInt32.self))
                let namePtr = p + nameOffset
                p += 8
                guard nameLength > 1 else { continue }
                let nameBytes = UnsafeRawBufferPointer(start: namePtr, count: nameLength - 1)

                let objType = p.loadUnaligned(as: UInt32.self)
                p += 4

                if objType == kTypeDir {
                    let name = String(decoding: nameBytes, as: UTF8.self)
                    let child = DirNode(name: name, parent: node)
                    subdirs.append(child)
                    let childPath = base + name
                    if mountPoints.contains(childPath) {
                        child.otherVolume = true
                    } else {
                        kids.append(Job(node: child, path: childPath))
                    }
                    continue
                }

                var fileID: UInt64 = 0
                if common & kCmnFileID != 0 {
                    fileID = p.loadUnaligned(as: UInt64.self)
                    p += 8
                }
                var linkCount: UInt32 = 1
                if fileAttrs & kFileLinkCount != 0 {
                    linkCount = p.loadUnaligned(as: UInt32.self)
                    p += 4
                }
                var size: Int64 = 0
                if fileAttrs & kFileAllocSize != 0 {
                    size = p.loadUnaligned(as: Int64.self)
                }
                // Count hard-linked files once.
                if linkCount > 1 && fileID != 0 {
                    let first = seenHardLinks.withLock { $0.insert(fileID).inserted }
                    if !first { size = 0 }
                }

                let typeID = DiskScanner.typeID(for: nameBytes, cache: &cache, types: types)
                files.append(FileEntry(name: String(decoding: nameBytes, as: UTF8.self),
                                       size: size, typeID: typeID))
                bytes += size
            }
        }

        node.subdirs = subdirs
        node.files = files
        fileCounter.add(files.count, ordering: .relaxed)
        let dirsDone = dirCounter.add(1, ordering: .relaxed).newValue
        byteCounter.add(bytes, ordering: .relaxed)
        if dirsDone & 63 == 0 {
            let path = job.path
            current.withLock { $0 = path }
        }
        return kids
    }

    /// Paths of all mounted file systems.
    static func currentMounts() -> [String] {
        var list: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&list, MNT_NOWAIT)
        guard n > 0, let list else { return [] }
        return (0..<Int(n)).map { i in
            withUnsafeBytes(of: list[i].f_mntonname) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
    }

    /// Mount points inside the scan that belong to other volumes, in every
    /// spelling the scan may meet ("/Volumes/X" and "/System/Volumes/Data/Volumes/X").
    static func mountPointsToSkip(mounts: [String], root: String) -> Set<String> {
        let data = Paths.dataVolume
        var out: Set<String> = []
        for m in mounts where m != "/" {
            // The volume being scanned, or one that contains it.
            if root == m || root.hasPrefix(m + "/") { continue }
            out.insert(m)
            out.insert(Paths.withoutDataVolume(m))
            if !m.hasPrefix(data + "/") { out.insert(data + m) }
        }
        return out
    }

    /// Lowercased extension after the last dot, e.g. "photo.JPG" -> "jpg".
    private static func typeID(for name: UnsafeRawBufferPointer, cache: inout [String: UInt16],
                               types: TypeTable) -> UInt16 {
        let n = name.count
        var dot = -1
        var i = n - 1
        while i > 0 {
            if name[i] == 0x2E { dot = i; break }
            i -= 1
        }
        guard dot > 0, n - dot - 1 >= 1, n - dot - 1 <= 12 else { return 0 }
        var bytes = [UInt8](name[(dot + 1)...])
        for k in bytes.indices where bytes[k] >= 0x41 && bytes[k] <= 0x5A { bytes[k] += 32 }
        let ext = String(decoding: bytes, as: UTF8.self)
        if let id = cache[ext] { return id }
        let id = types.id(for: ext)
        cache[ext] = id
        return id
    }

    /// Adds up sizes bottom-up, sorts every folder largest first, and totals file types.
    static func finalize(_ root: DirNode, types: inout [TypeInfo]) {
        var stack: [(DirNode, Bool)] = [(root, false)]
        while let (n, visited) = stack.popLast() {
            if !visited {
                stack.append((n, true))
                for d in n.subdirs { stack.append((d, false)) }
                continue
            }
            var size: Int64 = 0
            var fileCount = n.files.count
            var dirCount = n.subdirs.count
            for f in n.files {
                size += f.size
                types[Int(f.typeID)].size += f.size
                types[Int(f.typeID)].count += 1
            }
            for d in n.subdirs {
                size += d.size
                fileCount += d.fileCount
                dirCount += d.dirCount
            }
            n.size = size
            n.fileCount = fileCount
            n.dirCount = dirCount
            n.files.sort(by: DirNode.bySize)
            n.subdirs.sort(by: DirNode.bySize)
        }
    }
}

struct Job {
    let node: DirNode
    let path: String
}

/// Shared stack of folders still to scan. Workers stop when it is empty and
/// nobody is still working (so no new folders can appear).
final class WorkQueue: @unchecked Sendable {
    private let cond = NSCondition()
    private var stack: [Job]
    private var active = 0
    private var stopped = false

    init(root: Job) { stack = [root] }

    func next() -> Job? {
        cond.lock(); defer { cond.unlock() }
        while true {
            if stopped { return nil }
            if let job = stack.popLast() {
                active += 1
                return job
            }
            if active == 0 {
                cond.broadcast()
                return nil
            }
            cond.wait()
        }
    }

    func finish(_ jobs: [Job]) {
        cond.lock()
        stack.append(contentsOf: jobs)
        active -= 1
        if !jobs.isEmpty || active == 0 { cond.broadcast() }
        cond.unlock()
    }

    func stop() {
        cond.lock()
        stopped = true
        cond.broadcast()
        cond.unlock()
    }
}

/// Global extension -> id table shared by all workers.
final class TypeTable: Sendable {
    private struct State {
        var map: [String: UInt16] = ["": 0]
        var names: [String] = [""]
    }
    private let state = Mutex(State())

    func id(for ext: String) -> UInt16 {
        state.withLock { s in
            if let id = s.map[ext] { return id }
            guard s.names.count < Int(UInt16.max) else { return 0 }
            let id = UInt16(s.names.count)
            s.map[ext] = id
            s.names.append(ext)
            return id
        }
    }

    var names: [String] { state.withLock { $0.names } }
}
