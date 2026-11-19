import AppKit

// Drives the Proj Mac app with the real cursor (CGEvent) and finds controls via Accessibility.
// usage: drive <pid> <tour file | -c "cmd|arg|..." ...>     (-c is handy for probing one step at a time)
// Labels match an element's AX description, value or title. "label@AXRole" also requires the role
// (e.g. "Home@AXMenuItem"); "@AXTextField" alone matches any text field. axdump <pid> lists them all.
// Tour lines (| separated; # comments):
//   scene|Chapter|Subtitle         caption change (logged)
//   click|<label>[|n][|xmin]       move to + click element whose description/value/title == label
//                                  (label starting with ^ = prefix match, ~ = contains); n = nth match (1-based);
//                                  xmin = only elements whose left edge >= window.x + xmin
//   click?|<label>                 click if it appears within 1.5 s, else skip
//   rclick|<label>[|n][|xmin]      right-click (context menu)
//   hover|<label>[|n][|xmin]       move only
//   at|x|y  / clickat|x|y          move / click at window-relative point
//   type|text                      type text; key|return|esc|tab|cmd+r|down|up
//   scroll|dy[|x|y]                scroll wheel at window point (dy pixels, negative = down)
//   drag|<label>|dx|dy             press on element, drag by dx,dy, release
//   pause|secs  wait|<label>[|secs]  end
// Logs EVT|time|... lines to stdout.

let pid = pid_t(CommandLine.arguments[1])!
let app = AXUIElementCreateApplication(pid)
setvbuf(stdout, nil, _IOLBF, 0)
func now() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }
func sleep(_ s: Double) { Thread.sleep(forTimeInterval: s) }

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func str(_ e: AXUIElement, _ a: String) -> String { if let s = attr(e, a) as? String { return s }; return "" }
func frame(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
func windowFrame() -> CGRect {
    let ws = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    return ws.map(frame).first { $0.width > 600 } ?? .zero
}
func matches(_ e: AXUIElement, _ spec: String) -> Bool {
    // "label@AXRole" restricts the role; "@AXRole" alone matches any element of that role
    var label = spec
    if let r = spec.range(of: "@AX", options: .backwards) {
        label = String(spec[..<r.lowerBound])
        if str(e, kAXRoleAttribute) != String(spec[spec.index(after: r.lowerBound)...]) { return false }
        if label.isEmpty { return true }
    }
    let cands = [str(e, kAXDescriptionAttribute), str(e, kAXValueAttribute), str(e, kAXTitleAttribute)]
    if label.hasPrefix("^") { let l = String(label.dropFirst()); return cands.contains { $0.hasPrefix(l) } }
    if label.hasPrefix("~") { let l = String(label.dropFirst()); return cands.contains { $0.contains(l) } }
    return cands.contains(label)
}
func collect(_ e: AXUIElement, _ label: String, _ out: inout [CGRect], depth: Int = 0) {
    if depth > 40 { return }
    if matches(e, label) {
        let f = frame(e)
        if f.width > 0 && f.height > 0 && f.minY < 2000 { out.append(f) }
    }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { collect(c, label, &out, depth: depth + 1) }
}
func find(_ label: String, nth: Int = 1, xmin: Double? = nil, timeout: Double = 6) -> CGRect? {
    let t0 = Date()
    repeat {
        var out: [CGRect] = []
        // windows + focused UI (menus/popovers live under the app element too)
        collect(app, label, &out)
        let w = windowFrame()
        if let xm = xmin { out = out.filter { $0.minX >= w.minX + xm } }
        // keep visible ones inside the window or menus near it
        out = out.filter { $0.minY >= w.minY - 5 && $0.maxY <= w.maxY + 400 }
        if out.count >= nth { return out[nth - 1] }
        sleep(0.25)
    } while Date().timeIntervalSince(t0) < timeout
    FileHandle.standardError.write("NOTFOUND \(label)\n".data(using: .utf8)!)
    return nil
}

// ---- mouse / keyboard
var cursor: CGPoint = CGEvent(source: nil)?.location ?? .zero
let src = CGEventSource(stateID: .hidSystemState)
func post(_ t: CGEventType, _ p: CGPoint, _ b: CGMouseButton = .left, clicks: Int64 = 1) {
    let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: b)!
    e.setIntegerValueField(.mouseEventClickState, value: clicks)
    e.post(tap: .cghidEventTap)
}
func move(to p: CGPoint, dur: Double? = nil, dragging: Bool = false) {
    let a = cursor
    let dist = hypot(p.x - a.x, p.y - a.y)
    let d = dur ?? min(0.75, max(0.25, Double(dist) / 1400))
    let steps = max(2, Int(d * 90))
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let k = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2     // ease in-out
        let q = CGPoint(x: a.x + (p.x - a.x) * k, y: a.y + (p.y - a.y) * k)
        post(dragging ? .leftMouseDragged : .mouseMoved, q)
        sleep(d / Double(steps))
    }
    cursor = p
}
func rel(_ p: CGPoint) -> String { let w = windowFrame(); return String(format: "%.1f|%.1f", p.x - w.minX, p.y - w.minY) }
func click(_ p: CGPoint, right: Bool = false) {
    move(to: p); sleep(0.12)
    print("EVT|\(now())|\(right ? "RCLICK" : "CLICK")|\(rel(p))")
    if right { post(.rightMouseDown, p, .right); sleep(0.08); post(.rightMouseUp, p, .right) }
    else { post(.leftMouseDown, p); sleep(0.08); post(.leftMouseUp, p) }
}
func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

let keycodes: [String: CGKeyCode] = ["return": 36, "esc": 53, "tab": 48, "down": 125, "up": 126, "left": 123, "right": 124,
                                     "space": 49, "delete": 51, "r": 15, "f": 3, "n": 45, "a": 0, "w": 13, "1": 18, "2": 19]
func key(_ spec: String) {
    var flags: CGEventFlags = []
    var name = spec
    for (m, f) in [("cmd+", CGEventFlags.maskCommand), ("shift+", .maskShift), ("opt+", .maskAlternate), ("ctrl+", .maskControl)] {
        if name.hasPrefix(m) { flags.insert(f); name = String(name.dropFirst(m.count)) }
    }
    guard let code = keycodes[name] else { FileHandle.standardError.write("BADKEY \(spec)\n".data(using: .utf8)!); return }
    print("EVT|\(now())|KEY|\(spec)")
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
        e.flags = flags; e.post(tap: .cghidEventTap); sleep(0.03)
    }
}
func type(_ s: String) {
    for ch in s {
        var u = Array(String(ch).utf16)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)!
            e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
            e.post(tap: .cghidEventTap)
        }
        sleep(ch == " " ? 0.09 : 0.065)
    }
}
func scroll(_ dy: Int, at p: CGPoint?) {
    if let p { move(to: p) }
    print("EVT|\(now())|SCROLL|\(rel(cursor))|\(dy)")
    let steps = max(1, abs(dy) / 12)
    for i in 0..<steps {
        let amt = Int32(dy / steps) + (i == 0 ? Int32(dy % steps) : 0)
        let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1, wheel1: amt, wheel2: 0, wheel3: 0)!
        e.location = cursor
        e.post(tap: .cghidEventTap); sleep(0.016)
    }
    sleep(0.4)
}

// ---- interpreter
func run(_ line: String) {
    let p = line.components(separatedBy: "|")
    let cmd = p[0].trimmingCharacters(in: .whitespaces)
    let w = windowFrame()
    func arg(_ i: Int) -> String? { p.count > i && !p[i].isEmpty ? p[i] : nil }
    func target() -> CGRect? { find(p[1], nth: Int(arg(2) ?? "1") ?? 1, xmin: arg(3).flatMap(Double.init)) }
    switch cmd {
    case "scene": print("EVT|\(now())|SCENE|\(p[1])|\(p[2])")
    case "click": if let r = target() { click(center(r)) }
    case "click?": if let r = find(p[1], timeout: 1.5) { click(center(r)) }
    case "rclick": if let r = target() { click(center(r), right: true) }
    case "hover": if let r = target() { move(to: center(r)) }
    case "at": move(to: CGPoint(x: w.minX + Double(p[1])!, y: w.minY + Double(p[2])!))
    case "clickat": click(CGPoint(x: w.minX + Double(p[1])!, y: w.minY + Double(p[2])!))
    case "type": type(p.dropFirst().joined(separator: "|"))
    case "key": key(p[1])
    case "scroll": scroll(Int(p[1])!, at: arg(2).map { CGPoint(x: w.minX + Double($0)!, y: w.minY + Double(p[3])!) })
    case "drag":
        if let r = find(p[1]) {
            let a = center(r); move(to: a); sleep(0.1)
            print("EVT|\(now())|DRAG|\(rel(a))|\(p[2])|\(p[3])")
            post(.leftMouseDown, a); sleep(0.5)
            move(to: CGPoint(x: a.x + Double(p[2])!, y: a.y + Double(p[3])!), dur: 1.0, dragging: true)
            sleep(0.3); post(.leftMouseUp, cursor)
        }
    case "pause": sleep(Double(p[1])!)
    case "wait": _ = find(p[1], timeout: Double(arg(2) ?? "6")!)
    case "end": print("EVT|\(now())|END")
    default: break
    }
}

let rest = Array(CommandLine.arguments.dropFirst(2))
var lines: [String]
if rest.first == "-c" { lines = Array(rest.dropFirst()) }
else { lines = try! String(contentsOfFile: rest[0], encoding: .utf8).components(separatedBy: "\n") }
for l in lines {
    let t = l.trimmingCharacters(in: .whitespaces)
    if t.isEmpty || t.hasPrefix("#") { continue }
    run(t)
    // default settle time after an action, unless the line was a pause/scene
    if !["pause", "scene", "type", "at", "wait", "end", "click?"].contains(t.components(separatedBy: "|")[0]) { sleep(0.6) }
}
