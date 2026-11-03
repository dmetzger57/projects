import Foundation

// A small YAML reader/writer for the README front-matter subset defined in SPEC.md:
// top-level keys holding scalars, flow lists ([a, b]), block lists of scalars or of
// flat mappings, and flat mappings. Anything else is kept verbatim as "opaque" and is
// never rewritten. Untouched keys are re-emitted byte-for-byte (comments included);
// only keys changed through `set`/`remove` are re-rendered, in the same style the
// Python tool writes (mapping indent 2, sequence dash at +2, content at +4).

public indirect enum YAMLValue: Equatable, Sendable {
    case null
    case scalar(String, quoted: Bool)
    case list([YAMLValue])
    case map(YAMLMap)

    // MARK: constructors that pick a safe style
    public static func string(_ s: String) -> YAMLValue { .scalar(s, quoted: YAMLScalar.needsQuotes(s)) }
    public static func bool(_ b: Bool) -> YAMLValue { .scalar(b ? "true" : "false", quoted: false) }
    public static func number(_ d: Double) -> YAMLValue { .scalar(YAMLScalar.format(d), quoted: false) }
    public static func date(_ iso: String) -> YAMLValue { .scalar(iso, quoted: false) }
    public static func optionalString(_ s: String?) -> YAMLValue { s.map { .string($0) } ?? .null }

    // MARK: typed accessors
    public var string: String? {
        if case let .scalar(s, _) = self { return s }
        return nil
    }
    public var bool: Bool? {
        guard case let .scalar(s, quoted) = self, !quoted else { return nil }
        switch s.lowercased() {
        case "true", "yes", "on": return true
        case "false", "no", "off": return false
        default: return nil
        }
    }
    public var double: Double? {
        guard case let .scalar(s, _) = self else { return nil }
        return Double(s.replacingOccurrences(of: "_", with: ""))
    }
    public var list: [YAMLValue]? {
        if case let .list(l) = self { return l }
        return nil
    }
    public var map: YAMLMap? {
        if case let .map(m) = self { return m }
        return nil
    }
    public var isNull: Bool { self == .null }
}

public struct YAMLMap: Equatable, Sendable {
    public struct Pair: Equatable, Sendable {
        public var key: String
        public var value: YAMLValue
    }
    public var pairs: [Pair] = []

    public init(_ pairs: [(String, YAMLValue)] = []) {
        self.pairs = pairs.map { Pair(key: $0.0, value: $0.1) }
    }

    public subscript(key: String) -> YAMLValue? {
        get { pairs.first { $0.key == key }?.value }
        set {
            if let i = pairs.firstIndex(where: { $0.key == key }) {
                if let v = newValue { pairs[i].value = v } else { pairs.remove(at: i) }
            } else if let v = newValue {
                pairs.append(Pair(key: key, value: v))
            }
        }
    }
}

enum YAMLScalar {
    static let indicators: Set<Character> = ["-", "?", ":", ",", "[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`"]

    static func needsQuotes(_ s: String) -> Bool {
        guard let first = s.first, let last = s.last else { return true }
        if first == " " || last == " " || indicators.contains(first) { return true }
        if s.contains(": ") || s.contains(" #") || s.hasSuffix(":") { return true }
        if s.contains(where: { $0 == "\n" || $0 == "\t" || $0 == "\r" }) { return true }
        let lower = s.lowercased()
        if ["true", "false", "yes", "no", "on", "off", "null", "~", "y", "n"].contains(lower) { return true }
        if Double(s) != nil || s.range(of: #"^[-+]?(\d[\d_]*)?\.?\d+([eE][-+]?\d+)?$"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^0[xob]"#, options: .regularExpression) != nil { return true }
        return false
    }

    static func format(_ d: Double) -> String {
        if d.isFinite, d == d.rounded(), abs(d) < 1e15 { return String(format: "%.1f", d) }
        return String(d)
    }

    /// Plain scalars are emitted as-is (their YAML type — bool, number, date — is preserved);
    /// `.string(_)` already chose `quoted: true` for any string that would be ambiguous.
    static func render(_ s: String, quoted: Bool) -> String {
        guard quoted else { return s }
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if ch.value < 0x20 { out += String(format: "\\x%02X", ch.value) } else { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    }

    /// Parses one scalar token (already isolated from its key). Returns nil if malformed.
    static func parse(_ raw: String) -> YAMLValue? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\"") { return parseDouble(t) }
        if t.hasPrefix("'") { return parseSingle(t) }
        let plain = stripComment(t)
        if plain.isEmpty || plain == "~" || plain.lowercased() == "null" { return .null }
        if plain.hasPrefix("|") || plain.hasPrefix(">") || plain.hasPrefix("&") || plain.hasPrefix("*") || plain.hasPrefix("!") { return nil }
        return .scalar(plain, quoted: false)
    }

    static func stripComment(_ s: String) -> String {
        if s.hasPrefix("#") { return "" }
        if let r = s.range(of: " #") { return String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces) }
        if let r = s.range(of: "\t#") { return String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func rest(after idx: String.Index, in s: String) -> Bool {
        stripComment(String(s[idx...])).isEmpty
    }

    static func parseDouble(_ s: String) -> YAMLValue? {
        var out = ""
        var i = s.index(after: s.startIndex)
        while i < s.endIndex {
            let c = s[i]
            if c == "\"" {
                return rest(after: s.index(after: i), in: s) ? .scalar(out, quoted: true) : nil
            }
            if c == "\\" {
                i = s.index(after: i)
                guard i < s.endIndex else { return nil }
                switch s[i] {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "0": out.append("\0")
                case "x", "u", "U":
                    let n = s[i] == "x" ? 2 : (s[i] == "u" ? 4 : 8)
                    guard let end = s.index(i, offsetBy: n, limitedBy: s.index(before: s.endIndex)) else { return nil }
                    let hex = String(s[s.index(after: i)...end])
                    guard let v = UInt32(hex, radix: 16), let sc = Unicode.Scalar(v) else { return nil }
                    out.unicodeScalars.append(sc)
                    i = end
                default: return nil
                }
            } else {
                out.append(c)
            }
            i = s.index(after: i)
        }
        return nil
    }

    static func parseSingle(_ s: String) -> YAMLValue? {
        var out = ""
        var i = s.index(after: s.startIndex)
        while i < s.endIndex {
            if s[i] == "'" {
                let n = s.index(after: i)
                if n < s.endIndex, s[n] == "'" { out.append("'"); i = s.index(after: n); continue }
                return rest(after: n, in: s) ? .scalar(out, quoted: true) : nil
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return nil
    }
}

// MARK: - Document

public struct FrontMatter: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var key: String
        var lines: [String]        // original lines for this key (key line + children)
        var trailing: [String]     // following top-level comment/blank lines, kept on re-render
        var value: YAMLValue?      // nil = opaque (unsupported construct; never rewritten)
        var dirty = false
    }

    var preamble: [String] = []
    var entries: [Entry] = []

    public init() {}

    public var keys: [String] { entries.map(\.key) }

    public subscript(key: String) -> YAMLValue? {
        entries.first { $0.key == key }?.value
    }

    /// True if the key is absent or was understood (so it can be safely rewritten).
    public func isEditable(_ key: String) -> Bool {
        guard let e = entries.first(where: { $0.key == key }) else { return true }
        return e.value != nil
    }

    public mutating func set(_ key: String, _ value: YAMLValue) {
        if let i = entries.firstIndex(where: { $0.key == key }) {
            entries[i].value = value
            entries[i].dirty = true
        } else {
            entries.append(Entry(key: key, lines: [], trailing: [], value: value, dirty: true))
        }
    }

    public mutating func remove(_ key: String) {
        entries.removeAll { $0.key == key }
    }

    // MARK: parse

    static let keyPattern = try! NSRegularExpression(pattern: #"^([^\s#'"\-?:,\[\]{}][^:]*?):(?:\s+(.*))?$"#)

    static func splitKey(_ text: String) -> (String, String)? {
        let ns = text as NSString
        guard let m = keyPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let key = ns.substring(with: m.range(at: 1))
        let rest = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
        return (key, rest)
    }

    public static func parse(_ text: String) -> FrontMatter {
        var fm = FrontMatter()
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var current: Entry?
        func flush() {
            if var e = current {
                // move trailing top-level comments/blank lines out of the value
                while let last = e.lines.last, e.lines.count > 1, isBlankOrComment(last) {
                    e.trailing.insert(last, at: 0)
                    e.lines.removeLast()
                }
                e.value = parseValue(e.lines)
                fm.entries.append(e)
            }
            current = nil
        }
        for line in lines {
            let indent = line.prefix { $0 == " " }.count
            if indent == 0, !isBlankOrComment(line), let (key, _) = splitKey(line) {
                flush()
                current = Entry(key: key, lines: [line], trailing: [], value: nil)
            } else if current != nil {
                current!.lines.append(line)
            } else {
                fm.preamble.append(line)
            }
        }
        flush()
        return fm
    }

    static func isBlankOrComment(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.hasPrefix("#")
    }

    struct L { let indent: Int; let text: String }

    static func parseValue(_ lines: [String]) -> YAMLValue? {
        guard let first = lines.first, let (_, rest) = splitKey(first) else { return nil }
        let children = lines.dropFirst().filter { !isBlankOrComment($0) }.map {
            L(indent: $0.prefix { $0 == " " }.count, text: String($0.drop { $0 == " " }))
        }
        let inline = YAMLScalar.stripComment(rest)
        if !inline.isEmpty || rest.trimmingCharacters(in: .whitespaces).hasPrefix("\"") || rest.trimmingCharacters(in: .whitespaces).hasPrefix("'") {
            guard children.isEmpty else { return nil }   // multi-line scalars unsupported
            if inline.hasPrefix("[") { return parseFlowList(inline) }
            if inline == "{}" { return .map(YAMLMap()) }
            if inline.hasPrefix("{") { return nil }
            return YAMLScalar.parse(rest)
        }
        guard !children.isEmpty else { return .null }
        if children[0].text == "-" || children[0].text.hasPrefix("- ") {
            return parseBlockList(children[...])
        }
        return parseBlockMap(children[...]).map { .map($0) }
    }

    static func parseFlowList(_ s: String) -> YAMLValue? {
        guard s.hasPrefix("["), s.hasSuffix("]") else { return nil }
        let inner = s.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        if inner.isEmpty { return .list([]) }
        var items: [String] = []
        var cur = ""
        var quote: Character?
        for c in inner {
            if let q = quote {
                cur.append(c)
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c; cur.append(c)
            } else if c == "[" || c == "{" {
                return nil
            } else if c == "," {
                items.append(cur); cur = ""
            } else {
                cur.append(c)
            }
        }
        items.append(cur)
        var out: [YAMLValue] = []
        for it in items {
            guard let v = YAMLScalar.parse(it) else { return nil }
            out.append(v)
        }
        return .list(out)
    }

    static func parseBlockMap(_ lines: ArraySlice<L>) -> YAMLMap? {
        guard let indent = lines.first?.indent else { return YAMLMap() }
        var m = YAMLMap()
        for l in lines {
            guard l.indent == indent, let (k, rest) = splitKey(l.text) else { return nil }
            guard let v = YAMLScalar.parse(rest) else { return nil }
            if case .null = v, !YAMLScalar.stripComment(rest).isEmpty { return nil }
            m[k] = v
        }
        return m
    }

    static func parseBlockList(_ lines: ArraySlice<L>) -> YAMLValue? {
        guard let dashIndent = lines.first?.indent else { return .list([]) }
        // group lines into items
        var groups: [[L]] = []
        for l in lines {
            if l.indent == dashIndent, l.text == "-" || l.text.hasPrefix("- ") {
                groups.append([l])
            } else if l.indent > dashIndent, !groups.isEmpty {
                groups[groups.count - 1].append(l)
            } else {
                return nil
            }
        }
        var items: [YAMLValue] = []
        for g in groups {
            let head = g[0].text.dropFirst()                      // drop "-"
            let content = head.drop { $0 == " " }
            let contentIndent = dashIndent + 1 + (head.count - content.count)
            if content.isEmpty {
                guard g.count > 1, let m = parseBlockMap(g.dropFirst()[...]) else { return nil }
                items.append(.map(m))
            } else if splitKey(String(content)) != nil, !content.hasPrefix("\""), !content.hasPrefix("'") {
                let first = L(indent: contentIndent, text: String(content))
                guard let m = parseBlockMap(([first] + g.dropFirst())[...]) else { return nil }
                items.append(.map(m))
            } else {
                guard g.count == 1, let v = YAMLScalar.parse(String(content)) else { return nil }
                items.append(v)
            }
        }
        return .list(items)
    }

    // MARK: render

    public func serialize() -> String {
        var out = preamble
        for e in entries {
            if e.dirty, let v = e.value {
                out += FrontMatter.render(key: e.key, value: v)
            } else {
                out += e.lines
            }
            out += e.trailing
        }
        return out.map { $0 + "\n" }.joined()
    }

    static func inline(_ v: YAMLValue) -> String? {
        switch v {
        case .null: return ""
        case let .scalar(s, q): return YAMLScalar.render(s, quoted: q)
        case let .list(l) where l.isEmpty: return "[]"
        case let .map(m) where m.pairs.isEmpty: return "{}"
        default: return nil
        }
    }

    static func pad(_ n: Int) -> String { String(repeating: " ", count: n) }

    static func keyLine(_ key: String, _ inlineValue: String, indent: Int) -> String {
        inlineValue.isEmpty ? "\(pad(indent))\(key):" : "\(pad(indent))\(key): \(inlineValue)"
    }

    static func render(key: String, value: YAMLValue, indent: Int = 0) -> [String] {
        if let s = inline(value) { return [keyLine(key, s, indent: indent)] }
        switch value {
        case let .list(items): return ["\(pad(indent))\(key):"] + renderList(items, indent: indent + 2)
        case let .map(m): return ["\(pad(indent))\(key):"] + renderMap(m, indent: indent + 2)
        default: return []
        }
    }

    static func renderMap(_ m: YAMLMap, indent: Int) -> [String] {
        m.pairs.flatMap { render(key: $0.key, value: $0.value, indent: indent) }
    }

    static func renderList(_ items: [YAMLValue], indent: Int) -> [String] {
        var out: [String] = []
        for item in items {
            if let s = inline(item) {
                out.append(s.isEmpty ? "\(pad(indent))-" : "\(pad(indent))- \(s)")
                continue
            }
            switch item {
            case let .map(m):
                var lines = renderMap(m, indent: indent + 2)
                lines[0] = pad(indent) + "- " + lines[0].dropFirst(indent + 2)
                out += lines
            case let .list(l):
                out.append("\(pad(indent))-")
                out += renderList(l, indent: indent + 2)
            default: break
            }
        }
        return out
    }
}

// MARK: - README document (front matter + body)

public struct ProjectDocument: Equatable, Sendable {
    public var frontMatter: FrontMatter
    public var body: String

    public init(frontMatter: FrontMatter = FrontMatter(), body: String = "") {
        self.frontMatter = frontMatter
        self.body = body
    }

    /// Splits `---\n<yaml>---\n<body>`; text without front matter becomes body only.
    public static func parse(_ text: String) -> ProjectDocument {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return ProjectDocument(body: text)
        }
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ProjectDocument(body: text)
        }
        let yaml = lines[1..<end].map { $0 + "\n" }.joined()
        let body = lines[(end + 1)...].joined(separator: "\n")
        return ProjectDocument(frontMatter: FrontMatter.parse(yaml), body: body)
    }

    public func serialize() -> String {
        let b = body.hasPrefix("\n") ? body : "\n" + body
        return "---\n" + frontMatter.serialize() + "---\n" + b
    }
}
