import AppKit
// usage: axdump <pid>  — prints role | title | desc | value | id | frame for every element in the front window (and menus/sheets)
let pid = pid_t(CommandLine.arguments[1])!
let app = AXUIElementCreateApplication(pid)
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func str(_ e: AXUIElement, _ a: String) -> String { if let s = attr(e, a) as? String { return s }; if let n = attr(e, a) as? NSNumber { return n.stringValue }; return "" }
func frame(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
func walk(_ e: AXUIElement, _ d: Int) {
    let f = frame(e)
    let line = [str(e, kAXRoleAttribute), str(e, kAXTitleAttribute), str(e, kAXDescriptionAttribute), String(str(e, kAXValueAttribute).prefix(40)), str(e, kAXIdentifierAttribute)]
    print(String(repeating: " ", count: d) + line.joined(separator: " | ") + String(format: " @ %.0f,%.0f %.0fx%.0f", f.minX, f.minY, f.width, f.height))
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, d + 1) }
}
walk(app, 0)
