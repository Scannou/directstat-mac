// Draws the DirectStat app icon (1024x1024 PNG): a mini cushion treemap on a
// dark rounded square. Usage: swift scripts/make-icon.swift out.png
import AppKit
import CoreGraphics

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                    bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Top-left origin, like the rest of the app's drawing code.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
}

// Body: Apple's icon grid puts an 824 pt rounded square in the 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(20, 24, 36))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [rgb(38, 45, 66), rgb(14, 17, 28)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY),
                       options: [])
ctx.restoreGState()

// Thin top highlight on the body edge.
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.setStrokeColor(rgb(255, 255, 255, 0.10))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// Treemap blocks as fractions of the inner area: (x0, y0, x1, y1, color).
let blue = (48.0, 110.0, 255.0), red = (240.0, 60.0, 50.0), green = (40.0, 200.0, 80.0)
let yellow = (255.0, 205.0, 0.0), cyan = (40.0, 200.0, 230.0), magenta = (205.0, 70.0, 225.0)
let orange = (255.0, 140.0, 0.0), lime = (150.0, 210.0, 50.0), gray = (165.0, 165.0, 165.0)
let blocks: [(Double, Double, Double, Double, (Double, Double, Double))] = [
    (0.00, 0.00, 0.56, 0.60, blue),
    (0.00, 0.60, 0.31, 1.00, red),
    (0.31, 0.60, 0.56, 1.00, yellow),
    (0.56, 0.00, 1.00, 0.38, green),
    (0.56, 0.38, 0.78, 0.70, cyan),
    (0.78, 0.38, 1.00, 1.00, magenta),
    (0.56, 0.70, 0.70, 1.00, orange),
    (0.70, 0.70, 0.78, 0.86, lime),
    (0.70, 0.86, 0.78, 1.00, gray),
]

let inner = body.insetBy(dx: 74, dy: 74)
let gap = 12.0
let tile = 16.0
// Outer corners follow the body's curve (body radius minus the inset).
let outer = 185.0 - 74.0 - gap / 2

/// Rounded rect with its own radius per corner (top-left origin).
func roundedRect(_ r: CGRect, tl: Double, tr: Double, br: Double, bl: Double) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: tr)
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: br)
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: bl)
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: tl)
    p.closeSubpath()
    return p
}

for (x0, y0, x1, y1, c) in blocks {
    let r = CGRect(x: inner.minX + x0 * inner.width + gap / 2,
                   y: inner.minY + y0 * inner.height + gap / 2,
                   width: (x1 - x0) * inner.width - gap,
                   height: (y1 - y0) * inner.height - gap)
    let tl = x0 == 0 && y0 == 0 ? outer : tile
    let tr = x1 == 1 && y0 == 0 ? outer : tile
    let br = x1 == 1 && y1 == 1 ? outer : tile
    let bl = x0 == 0 && y1 == 1 ? outer : tile
    ctx.saveGState()
    ctx.addPath(roundedRect(r, tl: tl, tr: tr, br: br, bl: bl))
    ctx.clip()
    // Cushion look: bright spot toward the upper left, darker edges.
    let light = rgb(min(255, c.0 * 0.55 + 140), min(255, c.1 * 0.55 + 140), min(255, c.2 * 0.55 + 140))
    let mid = rgb(c.0, c.1, c.2)
    let dark = rgb(c.0 * 0.38, c.1 * 0.38, c.2 * 0.38)
    let g = CGGradient(colorsSpace: space, colors: [light, mid, dark] as CFArray,
                       locations: [0, 0.45, 1])!
    let center = CGPoint(x: r.midX - r.width * 0.12, y: r.midY - r.height * 0.12)
    let radius = max(r.width, r.height) * 0.78
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center,
                           endRadius: radius, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
