import DirectStatCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

let usage = """
usage: directstat-cli [path] [--top N] [--depth N] [--threads N] [--png out.png] [--size WxH]

Scans a folder (default: current folder; "/" = whole disk) and prints the
largest folders, largest files, file types, and cleanup suggestions.
"""

var path = "."
var top = 10
var depth = 2
var threads: Int?
var pngPath: String?
var pngSize = (1600, 900)

var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--top": top = Int(args.next() ?? "") ?? top
    case "--depth": depth = Int(args.next() ?? "") ?? depth
    case "--threads": threads = Int(args.next() ?? "")
    case "--png": pngPath = args.next()
    case "--size":
        let parts = (args.next() ?? "").split(separator: "x").compactMap { Int($0) }
        if parts.count == 2 { pngSize = (parts[0], parts[1]) }
    case "-h", "--help": print(usage); exit(0)
    default: path = a
    }
}

func fmt(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
}

let scanner = DiskScanner(path: path, threadCount: threads)
let showProgress = isatty(STDERR_FILENO) != 0
let ticker = Thread {
    while !Thread.current.isCancelled {
        Thread.sleep(forTimeInterval: 0.5)
        if showProgress {
            let p = scanner.progress
            FileHandle.standardError.write(
                "\r\u{1B}[K\(p.files) files, \(p.dirs) folders, \(fmt(p.bytes))".data(using: .utf8)!)
        }
    }
}
ticker.start()
guard let result = scanner.run() else { exit(1) }
ticker.cancel()
if showProgress { FileHandle.standardError.write("\r\u{1B}[K".data(using: .utf8)!) }

let root = result.root
print("\(result.displayName)  (\(result.rootPath))")
print("  \(fmt(root.size)) in \(root.fileCount) files, \(root.dirCount) folders,"
      + " \(String(format: "%.1f", result.duration)) s, \(scanner.threadCount) threads")
if result.unreadableCount > 0 {
    print("  \(result.unreadableCount) folders could not be read (grant Full Disk Access to your terminal)")
}

print("\nLargest folders")
func printTree(_ d: DirNode, level: Int) {
    guard level < depth else { return }
    for sub in d.subdirs.prefix(top) where sub.size > 0 {
        let pct = root.size > 0 ? Double(sub.size) / Double(root.size) * 100 : 0
        let indent = String(repeating: "  ", count: level + 1)
        print("\(pad(fmt(sub.size), 10)) \(pad(String(format: "%.1f%%", pct), 6))  \(indent)\(sub.name)")
        printTree(sub, level: level + 1)
    }
}
printTree(root, level: 0)

print("\nLargest files")
for ref in Queries.largestFiles(in: root, limit: top) {
    print("\(pad(fmt(ref.size), 10))  \(ref.path)")
}

print("\nFile types")
for t in result.typesBySize.prefix(top) {
    print("\(pad(fmt(t.size), 10))  \(pad(String(t.count), 9)) files  \(t.displayName)")
}

let hogs = HogFinder.find(in: result)
if !hogs.isEmpty {
    print("\nCleanup suggestions")
    for h in hogs.prefix(top * 2) {
        let tag = h.safety == .safe ? "safe  " : "review"
        let where_ = h.nodes.count == 1 ? h.nodes[0].path : "\(h.nodes.count) folders"
        print("\(pad(fmt(h.size), 10))  [\(tag)] \(h.title): \(where_)")
    }
}

if let pngPath {
    let t0 = Date()
    let (image, layout) = TreemapRenderer.render(root: root, result: result,
                                                 width: pngSize.0, height: pngSize.1)
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    guard let cg = image.makeCGImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: pngPath) as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil)
    else { print("could not write \(pngPath)"); exit(1) }
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
    print("\nTreemap: \(pngPath) (\(layout.nodes.count) blocks, \(ms) ms)")
}
