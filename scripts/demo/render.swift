// Renders the static graphics for the demo video: background + device frame, screen mask,
// one caption overlay per scene, intro/outro cards and the touch dot.
// usage: swift render.swift <outdir> <platform label> <captions.tsv>   (tsv: chapter \t title \t subtitle)
import AppKit

let W = 1920.0, H = 1080.0
let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
let platform = args[2]
let rows = try! String(contentsOfFile: args[3], encoding: .utf8).split(separator: "\n").map { $0.components(separatedBy: "\t") }

// geometry from compose.py (layout.json next to the captions)
let L = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[3]).deletingLastPathComponent().appendingPathComponent("layout.json"))) as! [String: Double]
let scrW = L["w"]!, scrH = L["h"]!, scrX = L["x"]!, scrY = L["y"]!, scrR = L["r"]!, bezel = L["bezel"]!
let bar = L["bar"] ?? 0      // Web: browser toolbar height above the screen area
let accent = NSColor(srgbRed: 0.18, green: 0.49, blue: 0.36, alpha: 1)
let ink = NSColor(srgbRed: 0.11, green: 0.13, blue: 0.16, alpha: 1)
let muted = NSColor(srgbRed: 0.38, green: 0.42, blue: 0.47, alpha: 1)

func png(_ name: String, _ w: Double = W, _ h: Double = H, _ draw: () -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    // flip so y grows downward like video coordinates
    ctx.cgContext.translateBy(x: 0, y: h); ctx.cgContext.scaleBy(x: 1, y: -1)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

func font(_ size: Double, _ weight: NSFont.Weight) -> NSFont { NSFont.systemFont(ofSize: size, weight: weight) }

func text(_ s: String, _ f: NSFont, _ c: NSColor, x: Double, y: Double, width: Double, lineSpacing: Double = 6, align: NSTextAlignment = .left) -> Double {
    let p = NSMutableParagraphStyle(); p.lineSpacing = lineSpacing; p.alignment = align
    let a = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c, .paragraphStyle: p])
    let r = a.boundingRect(with: NSSize(width: width, height: 2000), options: [.usesLineFragmentOrigin, .usesFontLeading])
    NSGraphicsContext.saveGraphicsState()
    // text drawing in a flipped context
    let flipped = NSGraphicsContext(cgContext: NSGraphicsContext.current!.cgContext, flipped: true)
    NSGraphicsContext.current = flipped
    a.draw(with: NSRect(x: x, y: y, width: width, height: r.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
    NSGraphicsContext.restoreGraphicsState()
    return r.height
}

func background() {
    let g = NSGradient(colors: [NSColor(srgbRed: 0.95, green: 0.96, blue: 0.95, alpha: 1),
                                NSColor(srgbRed: 0.87, green: 0.91, blue: 0.89, alpha: 1)])!
    g.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -60)
}

// 1. background + device frame (the screen area is left for the video)
png("frame.png") {
    background()
    let body = NSRect(x: scrX - bezel, y: scrY - bezel - bar, width: scrW + 2 * bezel, height: scrH + 2 * bezel + bar)
    let sh = NSShadow(); sh.shadowBlurRadius = 40; sh.shadowOffset = NSSize(width: 0, height: -14)
    sh.shadowColor = NSColor.black.withAlphaComponent(0.28)
    NSGraphicsContext.saveGraphicsState(); sh.set()
    (bezel == 0 ? NSColor.white : NSColor(srgbRed: 0.09, green: 0.09, blue: 0.1, alpha: 1)).setFill()
    NSBezierPath(roundedRect: body, xRadius: scrR + bezel, yRadius: scrR + bezel).fill()
    NSGraphicsContext.restoreGraphicsState()
    if bar > 0 {                   // Web: browser toolbar with traffic lights and an address field
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: body, xRadius: scrR, yRadius: scrR).addClip()
        NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1).setFill()
        NSRect(x: body.minX, y: body.minY, width: body.width, height: bar).fill()
        NSColor(srgbRed: 0.84, green: 0.84, blue: 0.86, alpha: 1).setFill()
        NSRect(x: body.minX, y: body.minY + bar - 1, width: body.width, height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()
        for (i, c) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
            NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: body.minX + 20 + Double(i) * 22, y: body.minY + bar / 2 - 7, width: 14, height: 14)).fill()
        }
        let field = NSRect(x: body.midX - 280, y: body.minY + bar / 2 - 16, width: 560, height: 32)
        NSColor(srgbRed: 0.88, green: 0.88, blue: 0.9, alpha: 1).setFill()
        NSBezierPath(roundedRect: field, xRadius: 9, yRadius: 9).fill()
        _ = text("127.0.0.1:8765", font(16, .regular), ink, x: field.minX, y: field.minY + 6, width: field.width, align: .center)
    }
    if bezel == 0 { return }       // Mac / Web: a window, no device rim
    NSColor(srgbRed: 0.32, green: 0.33, blue: 0.35, alpha: 1).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), xRadius: scrR + bezel - 1.5, yRadius: scrR + bezel - 1.5)
    rim.lineWidth = 3; rim.stroke()
}

// 2. screen mask (white = video visible), screen-sized
png("mask.png", scrW, scrH) {
    NSColor.black.setFill(); NSRect(x: 0, y: 0, width: scrW, height: scrH).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: scrW, height: scrH), xRadius: scrR, yRadius: scrR).fill()
    if bar > 0 { NSRect(x: 0, y: 0, width: scrW, height: scrR).fill() }   // Web: square top under the toolbar
}

// 3. captions: chapter strip + title + subtitle on the right
let chapters: [String] = rows.reduce(into: []) { if !$0.contains($1[0]) { $0.append($1[0]) } }
let tx = L["tx"]!, tw = L["tw"]!, titleSize = L["title"]!, subSize = L["sub"]!, titleY = L["ty"]!
for (i, r) in rows.enumerated() {
    png(String(format: "cap%02d.png", i)) {
        // platform tag
        _ = text("PROJ  ·  \(platform.uppercased())", font(22, .semibold), accent, x: tx, y: 120, width: tw)
        // chapter strip
        var x = tx; var y = 170.0
        for c in chapters {
            let f = font(21, c == r[0] ? .semibold : .regular)
            let w = (c as NSString).size(withAttributes: [.font: f]).width + 32
            if x + w > tx + tw { x = tx; y += 52 }
            let pill = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: 40), xRadius: 20, yRadius: 20)
            if c == r[0] { accent.setFill(); pill.fill() }
            else { NSColor.white.withAlphaComponent(0.65).setFill(); pill.fill() }
            _ = text(c, f, c == r[0] ? .white : muted, x: x, y: y + 8, width: w, align: .center)
            x += w + 10
        }
        let h = text(r[1], font(titleSize, .bold), ink, x: tx, y: titleY, width: tw, lineSpacing: 0)
        _ = text(r[2], font(subSize, .regular), muted, x: tx, y: titleY + h + 28, width: min(tw, 880), lineSpacing: 10)
    }
}

// 4. intro / outro cards
png("intro.png") {
    background()
    _ = text("Proj", font(150, .bold), ink, x: 0, y: 330, width: W, align: .center)
    _ = text("Projects, goals and tasks in plain folders on iCloud Drive", font(44, .regular), muted, x: 0, y: 540, width: W, align: .center)
    _ = text("\(platform) tour", font(36, .semibold), accent, x: 0, y: 640, width: W, align: .center)
}
png("outro.png") {
    background()
    _ = text("Proj", font(120, .bold), ink, x: 0, y: 350, width: W, align: .center)
    _ = text("iPhone  ·  iPad  ·  Mac  ·  Web  ·  CLI", font(44, .medium), accent, x: 0, y: 530, width: W, align: .center)
    _ = text("One set of README files, every device.", font(38, .regular), muted, x: 0, y: 610, width: W, align: .center)
}

// 5. touch dot
png("dot.png", 56, 56) {
    NSColor.white.withAlphaComponent(0.55).setFill()
    NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 50, height: 50)).fill()
    NSColor.black.withAlphaComponent(0.35).setStroke()
    let c = NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 48, height: 48)); c.lineWidth = 3; c.stroke()
}
print("rendered \(rows.count) captions, chapters: \(chapters)")
