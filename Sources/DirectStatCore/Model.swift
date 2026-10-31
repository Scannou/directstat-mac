import Foundation

/// One file inside a folder. Files are stored as plain structs (not objects)
/// so a scan of millions of files stays small in memory.
public struct FileEntry: Sendable {
    public var name: String
    /// Bytes actually allocated on disk.
    public var size: Int64
    public var typeID: UInt16

    public init(name: String, size: Int64, typeID: UInt16) {
        self.name = name
        self.size = size
        self.typeID = typeID
    }
}

/// A folder in the scanned tree. After a scan finishes, `subdirs` and `files`
/// are each sorted largest first.
public final class DirNode: @unchecked Sendable {
    /// Folder name. For the scan root this is the full path.
    public let name: String
    public internal(set) unowned(unsafe) var parent: DirNode?
    public internal(set) var subdirs: [DirNode] = []
    public internal(set) var files: [FileEntry] = []
    /// Allocated bytes of everything inside this folder.
    public internal(set) var size: Int64 = 0
    /// Number of files anywhere below this folder.
    public internal(set) var fileCount: Int = 0
    /// Number of folders anywhere below this folder.
    public internal(set) var dirCount: Int = 0
    /// The folder could not be opened (usually missing permission).
    public internal(set) var unreadable = false
    /// The folder is a mount point of another volume and was not entered.
    public internal(set) var otherVolume = false

    public init(name: String, parent: DirNode?) {
        self.name = name
        self.parent = parent
    }

    public var isEmpty: Bool { subdirs.isEmpty && files.isEmpty }
    public var itemCount: Int { fileCount + dirCount }

    /// Root first, ending with this folder.
    public var ancestors: [DirNode] {
        var chain: [DirNode] = []
        var n: DirNode? = self
        while let cur = n { chain.append(cur); n = cur.parent }
        return chain.reversed()
    }

    public var path: String {
        let chain = ancestors
        var p = chain[0].name
        for part in chain.dropFirst() {
            if !p.hasSuffix("/") { p += "/" }
            p += part.name
        }
        return p
    }

    public func isAncestor(of other: DirNode) -> Bool {
        var n = other.parent
        while let cur = n {
            if cur === self { return true }
            n = cur.parent
        }
        return false
    }

    /// Subfolders and files merged into one list, largest first.
    public func children() -> [ItemRef] {
        var out: [ItemRef] = []
        out.reserveCapacity(subdirs.count + files.count)
        var i = 0, j = 0
        while i < subdirs.count || j < files.count {
            if j >= files.count || (i < subdirs.count && subdirs[i].size >= files[j].size) {
                out.append(.dir(subdirs[i])); i += 1
            } else {
                out.append(.file(self, j)); j += 1
            }
        }
        return out
    }

    static func bySize(_ a: DirNode, _ b: DirNode) -> Bool {
        a.size != b.size ? a.size > b.size : a.name < b.name
    }

    static func bySize(_ a: FileEntry, _ b: FileEntry) -> Bool {
        a.size != b.size ? a.size > b.size : a.name < b.name
    }
}

/// Points at either a folder or one file inside a folder.
public enum ItemRef: Hashable, @unchecked Sendable {
    case dir(DirNode)
    case file(DirNode, Int)

    public static func == (a: ItemRef, b: ItemRef) -> Bool {
        switch (a, b) {
        case let (.dir(x), .dir(y)): return x === y
        case let (.file(x, i), .file(y, j)): return x === y && i == j
        default: return false
        }
    }

    public func hash(into h: inout Hasher) {
        switch self {
        case .dir(let d):
            h.combine(0); h.combine(ObjectIdentifier(d))
        case .file(let d, let i):
            h.combine(1); h.combine(ObjectIdentifier(d)); h.combine(i)
        }
    }

    public var isDirectory: Bool {
        if case .dir = self { return true }
        return false
    }

    /// The folder itself, or the folder holding the file.
    public var containingDir: DirNode {
        switch self {
        case .dir(let d): return d
        case .file(let d, _): return d
        }
    }

    /// The folder this item sits in.
    public var parentDir: DirNode? {
        switch self {
        case .dir(let d): return d.parent
        case .file(let d, _): return d
        }
    }

    public var file: FileEntry? {
        guard case .file(let d, let i) = self, i >= 0, i < d.files.count else { return nil }
        return d.files[i]
    }

    public var name: String {
        switch self {
        case .dir(let d): return d.name
        case .file: return file?.name ?? ""
        }
    }

    public var size: Int64 {
        switch self {
        case .dir(let d): return d.size
        case .file: return file?.size ?? 0
        }
    }

    public var path: String {
        switch self {
        case .dir(let d): return d.path
        case .file(let d, _):
            let p = d.path
            return (p.hasSuffix("/") ? p : p + "/") + name
        }
    }
}

public struct TypeInfo: Identifiable, Sendable {
    public let id: UInt16
    /// Lowercased extension without the dot. Empty means no extension.
    public let ext: String
    public var size: Int64
    public var count: Int

    public var displayName: String { ext.isEmpty ? "(no extension)" : "." + ext }
}

/// The finished scan. Mutations (deleting items) go through `remove`, which
/// takes `lock`; background readers such as the treemap renderer hold it too.
public final class ScanResult: @unchecked Sendable {
    public let root: DirNode
    public let rootPath: String
    public let displayName: String
    public let duration: TimeInterval
    public let unreadableCount: Int
    public let lock = NSLock()
    public private(set) var types: [TypeInfo]
    private var colorSlot: [Int]

    init(root: DirNode, rootPath: String, displayName: String, duration: TimeInterval,
         unreadableCount: Int, types: [TypeInfo]) {
        self.root = root
        self.rootPath = rootPath
        self.displayName = displayName
        self.duration = duration
        self.unreadableCount = unreadableCount
        self.types = types
        self.colorSlot = Array(repeating: -1, count: types.count)
        let ranked = types.filter { $0.count > 0 && $0.size > 0 }.sorted { $0.size > $1.size }
        for (slot, t) in ranked.prefix(Palette.colors.count).enumerated() {
            colorSlot[Int(t.id)] = slot
        }
    }

    public var typesBySize: [TypeInfo] {
        types.filter { $0.count > 0 }.sorted { $0.size > $1.size }
    }

    public func color(forType id: UInt16) -> RGB {
        let i = Int(id)
        guard i < colorSlot.count, colorSlot[i] >= 0 else { return Palette.other }
        return Palette.colors[colorSlot[i]]
    }

    /// Removes an item from the tree after it was deleted on disk, and
    /// subtracts its size from every folder above it.
    public func remove(_ ref: ItemRef) {
        lock.lock(); defer { lock.unlock() }
        var size: Int64 = 0, files = 0, dirs = 0
        let parent: DirNode
        switch ref {
        case .file(let d, let i):
            guard i >= 0, i < d.files.count else { return }
            let f = d.files.remove(at: i)
            size = f.size; files = 1
            types[Int(f.typeID)].size -= f.size
            types[Int(f.typeID)].count -= 1
            parent = d
        case .dir(let d):
            guard let p = d.parent, let idx = p.subdirs.firstIndex(where: { $0 === d }) else { return }
            p.subdirs.remove(at: idx)
            size = d.size; files = d.fileCount; dirs = d.dirCount + 1
            var stack = [d]
            while let n = stack.popLast() {
                for f in n.files {
                    types[Int(f.typeID)].size -= f.size
                    types[Int(f.typeID)].count -= 1
                }
                stack.append(contentsOf: n.subdirs)
            }
            parent = p
        }
        var n: DirNode? = parent
        while let cur = n {
            cur.size -= size
            cur.fileCount -= files
            cur.dirCount -= dirs
            cur.parent?.subdirs.sort(by: DirNode.bySize)
            n = cur.parent
        }
    }
}

public struct RGB: Sendable, Hashable {
    public let r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
}

public enum Palette {
    /// Colors for the biggest file types, in rank order.
    public static let colors: [RGB] = [
        RGB(48, 110, 255),   // blue
        RGB(240, 60, 50),    // red
        RGB(40, 200, 80),    // green
        RGB(255, 205, 0),    // yellow
        RGB(40, 200, 230),   // cyan
        RGB(205, 70, 225),   // magenta
        RGB(255, 140, 0),    // orange
        RGB(150, 210, 50),   // lime
        RGB(255, 100, 165),  // pink
        RGB(125, 95, 240),   // violet
        RGB(175, 120, 70),   // brown
        RGB(90, 160, 200),   // steel
    ]
    public static let other = RGB(165, 165, 165)
    public static let folder = RGB(105, 105, 115)
}

public struct VolumeInfo: Sendable {
    public let name: String
    public let total: Int64
    public let available: Int64
    /// Free space plus what macOS can purge on demand (caches, iCloud copies).
    public let availableIncludingPurgeable: Int64

    public var used: Int64 { total - available }
    public var purgeable: Int64 { max(0, availableIncludingPurgeable - available) }

    public static func forPath(_ path: String) -> VolumeInfo? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity,
              let avail = v.volumeAvailableCapacity else { return nil }
        return VolumeInfo(
            name: v.volumeLocalizedName ?? "Disk",
            total: Int64(total),
            available: Int64(avail),
            availableIncludingPurgeable: v.volumeAvailableCapacityForImportantUsage ?? Int64(avail))
    }
}

/// Turns scan paths into the paths people know.
public enum Paths {
    public static let dataVolume = "/System/Volumes/Data"

    /// "/System/Volumes/Data/Users/x" -> "/Users/x". Both point at the same
    /// place; the short one is what Finder and Terminal show.
    public static func withoutDataVolume(_ path: String) -> String {
        if path == dataVolume { return "/" }
        if path.hasPrefix(dataVolume + "/") { return String(path.dropFirst(dataVolume.count)) }
        return path
    }

    /// Short form for display: no Data-volume prefix, home folder as "~".
    public static func display(_ path: String, home: String = NSHomeDirectory()) -> String {
        let p = withoutDataVolume(path)
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }
}
