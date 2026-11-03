import Foundation

public let readmeName = "README.md"
public let formatVersion = 1
public let projectStatuses = ["idea", "active", "on-hold", "closed"]

public struct Goal: Identifiable, Hashable, Sendable {
    public let index: Int          // 0-based position in front matter
    public let text: String
    public let done: Bool
    public let doneOn: String?
    public var id: Int { index }
}

public struct ProjectLink: Identifiable, Hashable, Sendable {
    public let index: Int
    public let title: String
    public let url: String
    public var id: Int { index }
}

public struct Receipt: Identifiable, Hashable, Sendable {
    public let index: Int
    public let path: String        // relative to the receipts root
    public let amount: Double?
    public let vendor: String?
    public let date: String?
    public var id: Int { index }
    public var fileName: String { (path as NSString).lastPathComponent }

    public init(index: Int, path: String, amount: Double?, vendor: String?, date: String?) {
        self.index = index; self.path = path; self.amount = amount; self.vendor = vendor; self.date = date
    }
}

public struct Note: Identifiable, Hashable, Sendable {
    public let date: String        // YYYY-MM-DD
    public let text: String        // markdown under the heading
    public var id: String { date }
}

public enum ISODate {
    public static func string(_ d: Date = Date()) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    public static func isValid(_ s: String) -> Bool {
        s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
}

public struct Project: Identifiable, Hashable, Sendable {
    public let url: URL
    public var document: ProjectDocument?   // nil when legacy (no README.md)
    public var parseError: String?

    public init(url: URL, document: ProjectDocument?, parseError: String? = nil) {
        self.url = url
        self.document = document
        self.parseError = parseError
    }

    public static func == (a: Project, b: Project) -> Bool { a.url == b.url && a.document == b.document }
    public func hash(into h: inout Hasher) { h.combine(url) }

    public var id: String { folderName }
    public var folderName: String { url.lastPathComponent }
    public var readmeURL: URL { url.appendingPathComponent(readmeName) }
    public var isLegacy: Bool { document == nil }

    var fm: FrontMatter { document?.frontMatter ?? FrontMatter() }

    public var title: String { fm["title"]?.string ?? folderName }
    public var area: String? { fm["area"]?.string }
    public var status: String { isLegacy ? "legacy" : (fm["status"]?.string ?? "active") }
    public var created: String? { fm["created"]?.string }
    public var closedOn: String? { fm["closed"]?.string }
    public var tags: [String] { fm["tags"]?.list?.compactMap(\.string) ?? [] }

    public var goals: [Goal] {
        (fm["goals"]?.list ?? []).enumerated().compactMap { i, v in
            guard let m = v.map else { return v.string.map { Goal(index: i, text: $0, done: false, doneOn: nil) } }
            return Goal(index: i, text: m["text"]?.string ?? "", done: m["done"]?.bool ?? false,
                        doneOn: m["done_on"]?.string)
        }
    }

    public var links: [ProjectLink] {
        (fm["links"]?.list ?? []).enumerated().compactMap { i, v in
            guard let m = v.map, let u = m["url"]?.string else { return nil }
            return ProjectLink(index: i, title: m["title"]?.string ?? u, url: u)
        }
    }

    public var receipts: [Receipt] {
        (fm["receipts"]?.list ?? []).enumerated().compactMap { i, v in
            guard let m = v.map, let p = m["path"]?.string else { return nil }
            return Receipt(index: i, path: p, amount: m["amount"]?.double, vendor: m["vendor"]?.string,
                           date: m["date"]?.string)
        }
    }

    public var goalProgress: (done: Int, total: Int) {
        let g = goals
        return (g.filter(\.done).count, g.count)
    }

    public var totalCost: Double { receipts.compactMap(\.amount).reduce(0, +) }

    public func section(_ heading: String) -> String? {
        document.flatMap { ReadmeBody.section($0.body, heading) }
    }

    public var notes: [Note] { document.map { ReadmeBody.notes($0.body) } ?? [] }
}

// MARK: - Markdown body helpers (mirror projkit/project.py and ops.py)

public enum ReadmeBody {
    static func isH2(_ l: String) -> Bool { l.hasPrefix("## ") }
    static func h2Name(_ l: String) -> String { String(l.dropFirst(3)).trimmingCharacters(in: .whitespaces) }

    public static func section(_ body: String, _ heading: String) -> String? {
        var out: [String] = []
        var inside = false
        var found = false
        for l in body.components(separatedBy: "\n") {
            if isH2(l) {
                if inside { break }
                inside = h2Name(l).lowercased() == heading.lowercased()
                found = found || inside
                continue
            }
            if inside { out.append(l) }
        }
        return found ? out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    public static func notes(_ body: String) -> [Note] {
        guard let sec = section(body, "Notes") else { return [] }
        var notes: [Note] = []
        var date: String?
        var buf: [String] = []
        func flush() {
            if let d = date { notes.append(Note(date: d, text: buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))) }
        }
        for l in sec.components(separatedBy: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("### "), ISODate.isValid(String(t.dropFirst(4)).trimmingCharacters(in: .whitespaces)) {
                flush()
                date = String(t.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                buf = []
            } else if date != nil {
                buf.append(l)
            }
        }
        flush()
        return notes
    }

    static func trimTrailingNewlines(_ s: String) -> String {
        var s = s
        while s.hasSuffix("\n") { s.removeLast() }
        return s
    }

    /// Append `- text` under `### date` in `## Notes` (creating either if needed).
    public static func addNote(_ body: String, text: String, date: String) -> String {
        let head = "### \(date)"
        let bullet = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            .enumerated().map { ($0.offset == 0 ? "- " : "  ") + $0.element }.joined(separator: "\n")
        var lines = trimTrailingNewlines(body).components(separatedBy: "\n")
        if lines == [""] { lines = [] }

        var notesI = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).lowercased() == "## notes" }
        if notesI == nil {
            lines += ["", "## Notes"]
            notesI = lines.count - 1
        }
        let n = notesI!
        var end = (n + 1..<lines.count).first { isH2(lines[$0]) } ?? lines.count
        if let h = (n + 1..<end).first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == head }) {
            var subEnd = (h + 1..<end).first { lines[$0].hasPrefix("#") } ?? end
            while subEnd > h + 1, lines[subEnd - 1].trimmingCharacters(in: .whitespaces).isEmpty { subEnd -= 1 }
            lines.insert(bullet, at: subEnd)
        } else {
            while end > n + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            let block = (end > n + 1 ? [""] : []) + [head, bullet]
            lines.insert(contentsOf: block, at: end)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static let editableSections = ["Description", "Project Files"]

    /// Replace the content of `## heading` (created before Notes if missing).
    public static func setSection(_ body: String, heading: String, text: String) throws -> String {
        guard editableSections.contains(heading) else { throw OpError("section '\(heading)' is not editable") }
        let t = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.components(separatedBy: "\n").contains(where: isH2) {
            throw OpError("section text may not contain '## ' headings")
        }
        var lines = trimTrailingNewlines(body).components(separatedBy: "\n")
        let start = lines.firstIndex { isH2($0) && h2Name($0).lowercased() == heading.lowercased() }
        var new = ["## \(heading)"] + (t.isEmpty ? [] : t.components(separatedBy: "\n")) + [""]
        if let s = start {
            let end = (s + 1..<lines.count).first { isH2(lines[$0]) } ?? lines.count
            lines.replaceSubrange(s..<end, with: end < lines.count ? new : Array(new.dropLast()))
        } else {
            let notes = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).lowercased() == "## notes" } ?? lines.count
            if notes > 0, !lines[notes - 1].trimmingCharacters(in: .whitespaces).isEmpty { new.insert("", at: 0) }
            lines.insert(contentsOf: new, at: notes)
        }
        var out = trimTrailingNewlines(lines.joined(separator: "\n")) + "\n"
        if !out.hasPrefix("\n") { out = "\n" + out }
        return out
    }

    /// Template body with Notes emptied (headings kept).
    public static func templateBody(_ template: String?) -> String {
        guard let template else { return "\n## Description\n\n## Project Files\n\n## Notes\n" }
        var out: [String] = []
        var skip = false
        for l in template.components(separatedBy: "\n") {
            if isH2(l) {
                skip = h2Name(l).lowercased() == "notes"
                out.append(l)
                continue
            }
            if !skip { out.append(l) }
        }
        var s = out.joined(separator: "\n")
        while s.hasSuffix("\n") || s.hasSuffix(" ") { s.removeLast() }
        return s + "\n"
    }
}

public struct OpError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
