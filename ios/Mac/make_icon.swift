// Draws the Mac app icon (1024×1024 PNG): a clipboard with a checklist and a project timeline on the
// app's green, on the macOS icon grid (824 px rounded square, 100 px margins, soft drop shadow).
//   swift ios/Mac/make_icon.swift out.png
import AppKit
import CoreGraphics

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// draw top-down like a design tool
ctx.translateBy(x: 0, y: size); ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// --- background tile: the macOS grid, with a drop shadow
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = rounded(tile, 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0x2f6f5e)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x3f9a80), rgb(0x245a4b)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
// soft highlight across the top
let hi = CGGradient(colorsSpace: cs, colors: [rgb(0xffffff, 0.16), rgb(0xffffff, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(hi, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 480), options: [])
ctx.restoreGState()
// hairline edge
ctx.addPath(rounded(tile.insetBy(dx: 1, dy: 1), 184)); ctx.setStrokeColor(rgb(0xffffff, 0.18)); ctx.setLineWidth(2); ctx.strokePath()

// --- clipboard board and paper
let board = CGRect(x: 262, y: 214, width: 500, height: 636)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: rgb(0x0b2a22, 0.45))
ctx.addPath(rounded(board, 46)); ctx.setFillColor(rgb(0x1d4a3e)); ctx.fillPath()
ctx.restoreGState()
let paper = board.insetBy(dx: 30, dy: 30).offsetBy(dx: 0, dy: 14)
ctx.saveGState()
ctx.addPath(rounded(paper, 22)); ctx.clip()
let pg = CGGradient(colorsSpace: cs, colors: [rgb(0xffffff), rgb(0xf1f3ef)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(pg, start: CGPoint(x: 512, y: paper.minY), end: CGPoint(x: 512, y: paper.maxY), options: [])
ctx.restoreGState()

// clip at the top
let clip = CGRect(x: 412, y: 180, width: 200, height: 84)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 10, color: rgb(0x000000, 0.3))
ctx.addPath(rounded(clip, 26)); ctx.setFillColor(rgb(0xc9d3cf)); ctx.fillPath()
ctx.restoreGState()
let cg = CGGradient(colorsSpace: cs, colors: [rgb(0xe9eeec), rgb(0xaab8b2)] as CFArray, locations: [0, 1])!
ctx.saveGState(); ctx.addPath(rounded(clip, 26)); ctx.clip()
ctx.drawLinearGradient(cg, start: CGPoint(x: 512, y: clip.minY), end: CGPoint(x: 512, y: clip.maxY), options: [])
ctx.restoreGState()
ctx.addEllipse(in: CGRect(x: 494, y: 200, width: 36, height: 36)); ctx.setFillColor(rgb(0x1d4a3e)); ctx.fillPath()

// --- checklist: two done, one open
let green = rgb(0x2f7d66), line = rgb(0xc8d6d0)
func check(at y: CGFloat, done: Bool, length: CGFloat) {
    let box = CGRect(x: 318, y: y - 30, width: 60, height: 60)
    if done {
        ctx.addPath(rounded(box, 16)); ctx.setFillColor(green); ctx.fillPath()
        ctx.move(to: CGPoint(x: box.minX + 15, y: box.midY + 1))
        ctx.addLine(to: CGPoint(x: box.minX + 26, y: box.midY + 13))
        ctx.addLine(to: CGPoint(x: box.maxX - 13, y: box.minY + 17))
        ctx.setStrokeColor(rgb(0xffffff)); ctx.setLineWidth(9); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.strokePath()
    } else {
        ctx.addPath(rounded(box.insetBy(dx: 4, dy: 4), 13)); ctx.setStrokeColor(green); ctx.setLineWidth(7); ctx.strokePath()
    }
    ctx.addPath(rounded(CGRect(x: 408, y: y - 13, width: length, height: 26), 13))
    ctx.setFillColor(done ? line : rgb(0x9fb8ae)); ctx.fillPath()
}
check(at: 352, done: true, length: 270)
check(at: 450, done: true, length: 210)
check(at: 548, done: false, length: 246)

// --- timeline: a small Gantt chart of three phases
ctx.move(to: CGPoint(x: 318, y: 618)); ctx.addLine(to: CGPoint(x: 706, y: 618))
ctx.setStrokeColor(rgb(0xdfe7e3)); ctx.setLineWidth(4); ctx.strokePath()
let bars: [(CGFloat, CGFloat, CGFloat, UInt32)] = [(318, 150, 664, 0x2f7d66), (430, 170, 712, 0xe0a33a), (560, 146, 760, 0x5b8fd6)]
for (x, w, y, c) in bars {
    ctx.addPath(rounded(CGRect(x: x, y: y - 17, width: w, height: 34), 17)); ctx.setFillColor(rgb(c)); ctx.fillPath()
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
