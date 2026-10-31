import CoreGraphics
import Foundation

public struct TreemapStyle: Sendable {
    /// Cushion height of the top level.
    public var height = 0.38
    /// Each level down gets this fraction of its parent's cushion height.
    public var scaleFactor = 0.91
    public var ambient = 0.13
    public var brightness = 1.40
    /// Folders smaller than this many pixels are drawn as one block.
    public var minFolderArea = 12.0
    public init() {}
}

/// Where each visible item ended up, in pixel coordinates (origin top-left).
public struct TreemapLayout: @unchecked Sendable {
    public struct Node {
        public var rect: CGRect
        public var ref: ItemRef
        public var first: Int32
        public var count: Int32
    }

    public var nodes: [Node] = []
    public var pixelScale: CGFloat = 1

    public init() {}

    /// Deepest item under a point (pixel coordinates).
    public func hitTest(_ p: CGPoint) -> ItemRef? {
        guard let root = nodes.first, root.rect.contains(p) else { return nil }
        var i = 0
        outer: while true {
            let n = nodes[i]
            let start = Int(n.first)
            for c in start..<(start + Int(n.count)) where nodes[c].rect.contains(p) {
                i = c
                continue outer
            }
            return n.ref
        }
    }

    /// Rectangle of an item, or of its deepest visible folder if the item
    /// itself is too small to draw. Nil if the item is outside this map.
    public func rect(for ref: ItemRef) -> CGRect? {
        guard let root = nodes.first, case .dir(let rootDir) = root.ref else { return nil }
        if ref == root.ref { return root.rect }
        var targets: [ItemRef] = [ref]
        var d = ref.parentDir
        while let cur = d, cur !== rootDir {
            targets.append(.dir(cur))
            d = cur.parent
        }
        guard d != nil else { return nil }
        var i = 0
        for t in targets.reversed() {
            let n = nodes[i]
            let start = Int(n.first)
            guard let c = (start..<(start + Int(n.count))).first(where: { nodes[$0].ref == t }) else {
                return n.rect
            }
            i = c
        }
        return nodes[i].rect
    }
}

public struct TreemapImage: Sendable {
    public let width: Int
    public let height: Int
    /// 0xFFRRGGBB per pixel, row 0 at the top.
    public let pixels: [UInt32]

    public func makeCGImage() -> CGImage? {
        let data = pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

public enum TreemapRenderer {
    /// Draws `root` into a `width` x `height` pixel image. The caller should
    /// hold `result.lock` so the tree can't change while drawing.
    public static func render(root: DirNode, result: ScanResult, width: Int, height: Int,
                              pixelScale: CGFloat = 1,
                              style: TreemapStyle = TreemapStyle()) -> (TreemapImage, TreemapLayout) {
        let w = max(1, width), h = max(1, height)
        var pixels = [UInt32](repeating: 0xFF00_0000, count: w * h)
        var layout = TreemapLayout()
        layout.pixelScale = pixelScale
        pixels.withUnsafeMutableBufferPointer { buf in
            let ctx = RenderContext(buf: buf.baseAddress!, width: w, height: h, style: style,
                                    result: result)
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            ctx.nodes.append(.init(rect: rect, ref: .dir(root), first: 0, count: 0))
            if root.size > 0 {
                ctx.render(index: 0, surface: Surface(), height: style.height)
            }
            layout.nodes = ctx.nodes
        }
        return (TreemapImage(width: w, height: h, pixels: pixels), layout)
    }

    /// Squarified treemap (Bruls, Huizing, van Wijk). `sizes` should be
    /// largest first and all positive. Returns one rectangle per size.
    static func squarify(_ sizes: [Double], in rect: CGRect) -> [CGRect] {
        var out = [CGRect](repeating: .zero, count: sizes.count)
        let total = sizes.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return out }
        let scale = Double(rect.width * rect.height) / total
        var x = Double(rect.minX), y = Double(rect.minY)
        var w = Double(rect.width), h = Double(rect.height)
        let n = sizes.count
        var i = 0
        while i < n {
            let side = min(w, h)
            var j = i
            var rowSum = 0.0, rowMax = 0.0, rowMin = Double.infinity
            var best = Double.infinity
            while j < n {
                let a = sizes[j] * scale
                let s = rowSum + a
                let mx = max(rowMax, a), mn = min(rowMin, a)
                let worst = max(side * side * mx / (s * s), (s * s) / (side * side * mn))
                if j > i && worst > best { break }
                best = worst; rowSum = s; rowMax = mx; rowMin = mn
                j += 1
            }
            let thickness = side > 0 ? rowSum / side : 0
            if w >= h {
                // Column on the left, items stacked top to bottom.
                let stripW = j == n ? w : min(thickness, w)
                var yy = y
                for k in i..<j {
                    let hk = k == j - 1 ? (y + h - yy) : sizes[k] * scale / thickness
                    out[k] = CGRect(x: x, y: yy, width: stripW, height: hk)
                    yy += hk
                }
                x += stripW; w -= stripW
            } else {
                // Row on top, items left to right.
                let stripH = j == n ? h : min(thickness, h)
                var xx = x
                for k in i..<j {
                    let wk = k == j - 1 ? (x + w - xx) : sizes[k] * scale / thickness
                    out[k] = CGRect(x: xx, y: y, width: wk, height: stripH)
                    xx += wk
                }
                y += stripH; h -= stripH
            }
            i = j
        }
        return out
    }
}

/// Cushion surface z = x2·x² + x1·x + y2·y² + y1·y (van Wijk & van de Wetering).
struct Surface {
    var x2 = 0.0, x1 = 0.0, y2 = 0.0, y1 = 0.0

    mutating func addRidges(_ r: CGRect, _ h: Double) {
        let w = Double(r.width), hh = Double(r.height)
        if w > 0 {
            x1 += 4 * h * Double(r.maxX + r.minX) / w
            x2 -= 4 * h / w
        }
        if hh > 0 {
            y1 += 4 * h * Double(r.maxY + r.minY) / hh
            y2 -= 4 * h / hh
        }
    }
}

private final class RenderContext {
    let buf: UnsafeMutablePointer<UInt32>
    let width: Int, height: Int
    let style: TreemapStyle
    let result: ScanResult
    var nodes: [TreemapLayout.Node] = []
    let lx: Double, ly: Double, lz: Double

    init(buf: UnsafeMutablePointer<UInt32>, width: Int, height: Int, style: TreemapStyle,
         result: ScanResult) {
        self.buf = buf
        self.width = width
        self.height = height
        self.style = style
        self.result = result
        let len = (1.0 + 1.0 + 100.0).squareRoot()
        lx = -1 / len; ly = -1 / len; lz = 10 / len
    }

    func render(index: Int, surface parent: Surface, height h: Double) {
        let node = nodes[index]
        let rect = node.rect
        var s = parent
        s.addRidges(rect, h)

        switch node.ref {
        case .file(let d, let i):
            paint(rect, s, result.color(forType: d.files[i].typeID))
        case .dir(let d):
            let area = Double(rect.width * rect.height)
            if area < style.minFolderArea || d.isEmpty || d.size <= 0 {
                paint(rect, s, Palette.folder)
                return
            }
            var items = d.children()
            if let firstZero = items.firstIndex(where: { $0.size <= 0 }) {
                items.removeSubrange(firstZero...)
            }
            let total = items.reduce(0.0) { $0 + Double($1.size) }
            guard total > 0 else { paint(rect, s, Palette.folder); return }
            let scale = area / total

            // Lump the long tail of sub-pixel items into one block.
            var keep = items.count
            var tail = 0.0
            while keep > 1 && (tail + Double(items[keep - 1].size)) * scale < 1.0 {
                tail += Double(items[keep - 1].size)
                keep -= 1
            }
            var sizes = items[0..<keep].map { Double($0.size) }
            if tail > 0 { sizes.append(tail) }
            let rects = TreemapRenderer.squarify(sizes, in: rect)

            let first = nodes.count
            for k in 0..<keep where hasPixels(rects[k]) {
                nodes.append(.init(rect: rects[k], ref: items[k], first: 0, count: 0))
            }
            nodes[index].first = Int32(first)
            nodes[index].count = Int32(nodes.count - first)
            if tail > 0 { paint(rects[keep], s, Palette.folder) }
            let childHeight = h * style.scaleFactor
            for c in first..<nodes.count where c < first + Int(nodes[index].count) {
                render(index: c, surface: s, height: childHeight)
            }
        }
    }

    @inline(__always) private func hasPixels(_ r: CGRect) -> Bool {
        Double(r.minX).rounded() < Double(r.maxX).rounded()
            && Double(r.minY).rounded() < Double(r.maxY).rounded()
    }

    private func paint(_ r: CGRect, _ s: Surface, _ c: RGB) {
        let x0 = max(0, Int(Double(r.minX).rounded()))
        let x1 = min(width, Int(Double(r.maxX).rounded()))
        let y0 = max(0, Int(Double(r.minY).rounded()))
        let y1 = min(height, Int(Double(r.maxY).rounded()))
        guard x0 < x1, y0 < y1 else { return }
        let k = style.brightness
        let cr = Double(c.r) * k, cg = Double(c.g) * k, cb = Double(c.b) * k
        let ia = style.ambient, isrc = 1 - style.ambient
        for y in y0..<y1 {
            let ny = -(2 * s.y2 * (Double(y) + 0.5) + s.y1)
            let row = buf + y * width
            for x in x0..<x1 {
                let nx = -(2 * s.x2 * (Double(x) + 0.5) + s.x1)
                var cosa = (nx * lx + ny * ly + lz) / (nx * nx + ny * ny + 1).squareRoot()
                if cosa > 1 { cosa = 1 }
                var p = isrc * cosa
                if p < 0 { p = 0 }
                p += ia
                let r = UInt32(min(255, cr * p))
                let g = UInt32(min(255, cg * p))
                let b = UInt32(min(255, cb * p))
                row[x] = 0xFF00_0000 | (r << 16) | (g << 8) | b
            }
        }
    }
}
