// Renders the WhyFi app icon. Usage: swift make-icon.swift <out.png> [size]
import AppKit

let out = CommandLine.arguments[1]
let size = CGFloat(Double(CommandLine.arguments.dropFirst(2).first ?? "1024") ?? 1024)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: size / 1024, y: size / 1024)  // design on a 1024 grid, origin bottom-left

// macOS icon grid: 824×824 body centered in 1024.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(shape)
ctx.setFillColor(rgb(0x0f1b2d))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x22406a), rgb(0x0a1320)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

let baseline: CGFloat = 230

// The clear channel: a soft green column fading upward.
let col = CGRect(x: 565, y: baseline, width: 160, height: 470)
ctx.saveGState()
ctx.clip(to: col)
let green = CGGradient(colorsSpace: cs, colors: [rgb(0x2ed158, 0.55), rgb(0x2ed158, 0.0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(green, start: CGPoint(x: 0, y: baseline), end: CGPoint(x: 0, y: col.maxY), options: [])
ctx.restoreGState()

// Busy channels: smooth humps (raised-cosine), drawn back to front.
func hump(center: CGFloat, halfWidth: CGFloat, height: CGFloat, fill: CGColor, stroke: CGColor, line: CGFloat) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: center - halfWidth, y: baseline))
    for i in 0...64 {
        let t = CGFloat(i) / 64
        let x = center - halfWidth + 2 * halfWidth * t
        let y = baseline + height * (0.5 - 0.5 * cos(2 * .pi * t))
        p.addLine(to: CGPoint(x: x, y: y))
    }
    // Fill the closed shape but stroke only the curve, so outlines don't pile up along the axis.
    ctx.addPath(p); ctx.setFillColor(fill); ctx.fillPath()
    ctx.addPath(p); ctx.setStrokeColor(stroke); ctx.setLineWidth(line); ctx.setLineJoin(.round); ctx.setLineCap(.round); ctx.strokePath()
}
let grey = rgb(0xd8d6cf, 0.14), greyLine = rgb(0xd8d6cf, 0.75)
hump(center: 300, halfWidth: 150, height: 330, fill: grey, stroke: greyLine, line: 12)
hump(center: 430, halfWidth: 150, height: 250, fill: grey, stroke: greyLine, line: 12)
hump(center: 815, halfWidth: 75, height: 230, fill: grey, stroke: greyLine, line: 12)
hump(center: 345, halfWidth: 170, height: 470, fill: rgb(0x3987e5, 0.35), stroke: rgb(0x6aaef5), line: 16)

// Axis.
ctx.setStrokeColor(rgb(0xffffff, 0.45))
ctx.setLineWidth(10)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 150, y: baseline)); ctx.addLine(to: CGPoint(x: 890, y: baseline))
ctx.strokePath()

// Wi-Fi glyph on top of the clear channel: dot plus three arcs.
let wc = CGPoint(x: 645, y: 640)
ctx.setStrokeColor(rgb(0xffffff))
ctx.setFillColor(rgb(0xffffff))
ctx.setLineCap(.round)
ctx.setLineWidth(30)
for r in [70.0, 130.0, 190.0] {
    ctx.addArc(center: wc, radius: r, startAngle: .pi / 4, endAngle: 3 * .pi / 4, clockwise: false)
    ctx.strokePath()
}
ctx.fillEllipse(in: CGRect(x: wc.x - 24, y: wc.y - 24, width: 48, height: 48))

// Soft top highlight.
let gloss = CGGradient(colorsSpace: cs, colors: [rgb(0xffffff, 0.10), rgb(0xffffff, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
