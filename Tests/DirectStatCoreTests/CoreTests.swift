import XCTest
@testable import DirectStatCore

final class CoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("directstat-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ rel: String, bytes: Int) throws {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Random bytes so APFS can't compress or dedupe them.
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        try data.write(to: url)
    }

    /// Allocated size the way `du` sees it, counting hard links once.
    private func duBytes(_ path: String) -> Int64 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-sk", path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try! p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Int64(out.split(separator: "\t").first!)! * 1024
    }

    private func scan() throws -> ScanResult {
        try XCTUnwrap(DiskScanner(path: dir.path, threadCount: 4).run())
    }

    func testSizesMatchDu() throws {
        try write("a/big.bin", bytes: 3_000_000)
        try write("a/b/c/deep.txt", bytes: 10_000)
        try write("small.JPG", bytes: 500)
        try write("node_modules/x/index.js", bytes: 20_000)
        for i in 0..<300 { try write("many/f\(i).log", bytes: 1000 + i) }
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("link").path,
                                                   withDestinationPath: "a/big.bin")
        try FileManager.default.linkItem(at: dir.appendingPathComponent("a/big.bin"),
                                         to: dir.appendingPathComponent("hardlink.bin"))

        let r = try scan()
        XCTAssertEqual(r.root.size, duBytes(dir.path), "total should match du")
        XCTAssertEqual(r.root.fileCount, 1 + 1 + 1 + 1 + 300 + 1 + 1)
        XCTAssertEqual(r.root.dirCount, 6) // a, a/b, a/b/c, node_modules, node_modules/x, many
        XCTAssertEqual(r.unreadableCount, 0)

        let types = Dictionary(uniqueKeysWithValues: r.typesBySize.map { ($0.ext, $0) })
        XCTAssertEqual(types["log"]?.count, 300)
        XCTAssertEqual(types["jpg"]?.count, 1, "extensions are lowercased")

        // Folders and files are sorted largest first everywhere.
        var stack = [r.root]
        while let d = stack.popLast() {
            XCTAssertEqual(d.files.map(\.size), d.files.map(\.size).sorted(by: >))
            XCTAssertEqual(d.subdirs.map(\.size), d.subdirs.map(\.size).sorted(by: >))
            XCTAssertEqual(d.size, d.files.reduce(0) { $0 + $1.size } + d.subdirs.reduce(0) { $0 + $1.size })
            stack.append(contentsOf: d.subdirs)
        }
    }

    func testRemoveUpdatesAncestors() throws {
        try write("a/b/one.bin", bytes: 100_000)
        try write("a/two.bin", bytes: 50_000)
        let r = try scan()
        let a = try XCTUnwrap(r.root.subdirs.first { $0.name == "a" })
        let b = try XCTUnwrap(a.subdirs.first)
        let before = r.root.size
        r.remove(.dir(b))
        XCTAssertEqual(r.root.size, before - b.size)
        XCTAssertEqual(a.subdirs.count, 0)
        XCTAssertEqual(r.root.fileCount, 1)
        r.remove(.file(a, 0))
        XCTAssertEqual(r.root.size, 0)
        XCTAssertEqual(r.root.fileCount, 0)
    }

    func testSquarifyFillsRect() {
        let sizes: [Double] = [60, 30, 20, 10, 6, 3, 1]
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let rects = TreemapRenderer.squarify(sizes, in: rect)
        let total = sizes.reduce(0, +)
        var area = 0.0
        for (s, r) in zip(sizes, rects) {
            XCTAssertTrue(rect.insetBy(dx: -0.001, dy: -0.001).contains(r), "\(r) outside")
            XCTAssertEqual(Double(r.width * r.height), s / total * 120_000, accuracy: 1.0)
            area += Double(r.width * r.height)
        }
        XCTAssertEqual(area, 120_000, accuracy: 1.0)
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                XCTAssertTrue(overlap.isNull || overlap.width * overlap.height < 0.01)
            }
        }
    }

    func testRenderAndHitTest() throws {
        try write("big.mov", bytes: 2_000_000)
        try write("sub/small.txt", bytes: 200_000)
        let r = try scan()
        let (img, layout) = TreemapRenderer.render(root: r.root, result: r, width: 200, height: 100)
        XCTAssertEqual(img.pixels.count, 200 * 100)
        XCTAssertFalse(img.pixels.contains(0xFF00_0000), "every pixel painted")
        XCTAssertNotNil(img.makeCGImage())
        let bigRect = try XCTUnwrap(layout.rect(for: .file(r.root, 0)))
        XCTAssertGreaterThan(bigRect.width * bigRect.height, 200 * 100 * 0.8)
        let hit = layout.hitTest(CGPoint(x: bigRect.midX, y: bigRect.midY))
        XCTAssertEqual(hit, .file(r.root, 0))
    }

    func testHogFinder() throws {
        try write("proj/node_modules/pkg/a.js", bytes: 300_000)
        try write("proj/node_modules/pkg/node_modules/inner/b.js", bytes: 100_000)
        try write("rust/target/CACHEDIR.TAG", bytes: 100)
        try write("rust/target/debug/app", bytes: 200_000)
        let r = try scan()
        let hogs = HogFinder.find(in: r, home: "/nonexistent", minSize: 1)
        let nm = try XCTUnwrap(hogs.first { $0.title == "node_modules folders" })
        XCTAssertEqual(nm.nodes.count, 1, "nested node_modules counted once")
        XCTAssertNotNil(hogs.first { $0.title == "Build caches" })
    }

    func testNormalizeDataVolume() {
        XCTAssertEqual(HogFinder.normalize("/System/Volumes/Data/Users/x"), "/Users/x")
        XCTAssertEqual(HogFinder.normalize("/System/Volumes/Data"), "/")
        XCTAssertEqual(HogFinder.normalize("/Users/x"), "/Users/x")
    }

    func testDisplayPaths() {
        let home = "/Users/x"
        XCTAssertEqual(Paths.display("/System/Volumes/Data/Users/x/Downloads", home: home), "~/Downloads")
        XCTAssertEqual(Paths.display("/System/Volumes/Data/Users/x", home: home), "~")
        XCTAssertEqual(Paths.display("/System/Volumes/Data/Applications", home: home), "/Applications")
        XCTAssertEqual(Paths.display("/Users/xy/file", home: home), "/Users/xy/file", "prefix must end at a /")
        XCTAssertEqual(Paths.display("/System/Volumes/Data", home: home), "/")
        XCTAssertEqual(Paths.withoutDataVolume("/System/Volumes/Data/Users/x/.Trash/a"), "/Users/x/.Trash/a")
    }

    func testLargestFiles() throws {
        for i in 1...20 { try write("d\(i % 3)/f\(i).bin", bytes: i * 10_000) }
        let r = try scan()
        let top = Queries.largestFiles(in: r.root, limit: 5)
        XCTAssertEqual(top.map(\.name), ["f20.bin", "f19.bin", "f18.bin", "f17.bin", "f16.bin"])
    }
}
