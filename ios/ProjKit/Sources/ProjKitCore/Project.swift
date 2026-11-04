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
    public let path: String        // "Documents/…" (relative to home) or relative to the receipts root
    public let amount: Double?
    public let vendor: String?
    public let date: String?
    public var id: Int { index }
    public var fileName: String { (path as NSString).lastPathComponent }

    public init(index: Int, path: String, amount: Double?, vendor: String?, date: String?) {
        self.index = index; self.path = path; self.amount = amount; self.vendor = vendor; self.date = date
    }
}

/// A `- [ ]` / `- [x]` item in the README's `## Tasks` section.
public struct ProjectTask: Identifiable, Hashable, Sendable {
    public let index: Int          // 0-based position among task lines
    public let text: String
    public let done: Bool
    public var id: Int { index }
}

/// A named link in `## Project Files`: a file under ~/Documents ("Documents/…") or a URL.
public struct ProjectFile: Identifiable, Hashable, Sendable {
    public let index: Int
    public let name: String
    public let target: String
    public var isURL: Bool { ReadmeBody.isURL(target) }
    public var id: Int { index }

    public init(index: Int, name: String, target: String) {
        self.index = index; self.name = name; self.target = target
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

    public var tasks: [ProjectTask] { document.map { ReadmeBody.tasks($0.body) } ?? [] }

    public var files: [ProjectFile] { document.map { ReadmeBody.files($0.body) } ?? [] }

    /// Project Files content that isn't a link entry.
    public var filesOtherText: String { document.map { ReadmeBody.filesOtherText($0.body) } ?? "" }

    public var taskProgress: (done: Int, total: Int) {
        let t = tasks
        return (t.filter(\.done).count, t.count)
    }
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

    // MARK: tasks — byte-identical with projkit/ops.py body_*_task (same expected strings in tests)

    static func parseTask(_ line: String) -> (done: Bool, text: String)? {
        guard line.count > 6, line.hasPrefix("- ["), line.dropFirst(4).hasPrefix("] ") else { return nil }
        let mark = line[line.index(line.startIndex, offsetBy: 3)]
        guard mark == " " || mark == "x" || mark == "X" else { return nil }
        let text = String(line.dropFirst(6))
        guard !text.isEmpty else { return nil }
        return (mark != " ", text.trimmingCharacters(in: .whitespaces))
    }

    static func sectionBounds(_ lines: [String], _ heading: String) -> (start: Int, end: Int)? {
        guard let s = lines.firstIndex(where: { isH2($0) && h2Name($0).lowercased() == heading.lowercased() }) else { return nil }
        return (s, (s + 1..<lines.count).first { isH2(lines[$0]) } ?? lines.count)
    }

    static func taskLineIndices(_ lines: [String]) -> [Int] {
        guard let b = sectionBounds(lines, "Tasks") else { return [] }
        return (b.start + 1..<b.end).filter { parseTask(lines[$0]) != nil }
    }

    public static func tasks(_ body: String) -> [ProjectTask] {
        let lines = body.components(separatedBy: "\n")
        return taskLineIndices(lines).enumerated().map { n, i in
            let t = parseTask(lines[i])!
            return ProjectTask(index: n, text: t.text, done: t.done)
        }
    }

    static func cleanTask(_ text: String) throws -> String {
        let t = text.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { throw OpError("task text is empty") }
        return t
    }

    static func splitBody(_ body: String) -> [String] {
        trimTrailingNewlines(body).components(separatedBy: "\n")
    }

    public static func addTask(_ body: String, text: String) throws -> String {
        var lines = splitBody(body)
        let bullet = "- [ ] " + (try cleanTask(text))
        if let b = sectionBounds(lines, "Tasks") {
            let idx = taskLineIndices(lines)
            var pos: Int
            if let last = idx.last {
                pos = last + 1
            } else {
                pos = b.end
                while pos > b.start + 1, lines[pos - 1].trimmingCharacters(in: .whitespaces).isEmpty { pos -= 1 }
            }
            lines.insert(bullet, at: pos)
        } else {
            let notes = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).lowercased() == "## notes" } ?? lines.count
            var block = ["## Tasks", bullet] + (notes < lines.count ? [""] : [])
            if notes > 0, !lines[notes - 1].trimmingCharacters(in: .whitespaces).isEmpty { block.insert("", at: 0) }
            lines.insert(contentsOf: block, at: notes)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func taskLine(_ body: String, _ index: Int) throws -> ([String], Int) {
        let lines = splitBody(body)
        let idx = taskLineIndices(lines)
        guard idx.indices.contains(index) else { throw OpError("no task #\(index + 1)") }
        return (lines, idx[index])
    }

    public static func setTask(_ body: String, index: Int, done: Bool) throws -> String {
        var (lines, i) = try taskLine(body, index)
        lines[i] = "- [" + (done ? "x" : " ") + "]" + lines[i].dropFirst(5)
        return lines.joined(separator: "\n") + "\n"
    }

    public static func editTask(_ body: String, index: Int, text: String) throws -> String {
        var (lines, i) = try taskLine(body, index)
        lines[i] = String(lines[i].prefix(6)) + (try cleanTask(text))
        return lines.joined(separator: "\n") + "\n"
    }

    /// (start, end) line ranges of each task: the task line plus its indented detail lines.
    static func taskBlocks(_ lines: [String]) -> [(start: Int, end: Int)] {
        guard let b = sectionBounds(lines, "Tasks") else { return [] }
        return taskLineIndices(lines).map { i in
            var end = i + 1
            while end < b.end, let c = lines[end].first, c == " " || c == "\t",
                  !lines[end].trimmingCharacters(in: .whitespaces).isEmpty { end += 1 }
            return (i, end)
        }
    }

    /// Removes the task line and its indented detail lines.
    public static func removeTask(_ body: String, index: Int) throws -> String {
        var lines = splitBody(body)
        let blocks = taskBlocks(lines)
        guard blocks.indices.contains(index) else { throw OpError("no task #\(index + 1)") }
        lines.removeSubrange(blocks[index].start..<blocks[index].end)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Moves task `index` (with its detail lines) so it becomes task number `to` (0-based, clamped).
    public static func moveTask(_ body: String, index: Int, to rawTo: Int) throws -> String {
        var lines = splitBody(body)
        let blocks = taskBlocks(lines)
        guard blocks.indices.contains(index) else { throw OpError("no task #\(index + 1)") }
        let to = max(0, min(rawTo, blocks.count - 1))
        guard to != index else { return lines.joined(separator: "\n") + "\n" }
        let range = blocks[index].start..<blocks[index].end
        let moved = Array(lines[range])
        lines.removeSubrange(range)
        let rest = taskBlocks(lines)
        let pos = to < rest.count ? rest[to].start : rest[rest.count - 1].end
        lines.insert(contentsOf: moved, at: pos)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: project files — byte-identical with projkit/ops.py body_*_file (same literals in tests)

    static let fileRegex = try! NSRegularExpression(pattern: #"^- \[([^\]]*)\]\((<[^<>]*>|[^\s()<>]+)\)\s*$"#)

    public static func isURL(_ t: String) -> Bool {
        t.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil
    }

    static func parseFileLine(_ line: String) -> (name: String, target: String)? {
        let ns = line as NSString
        guard let m = fileRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var target = ns.substring(with: m.range(at: 2))
        if target.hasPrefix("<") { target = String(target.dropFirst().dropLast()) }
        return (ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces), target)
    }

    static func fileLineIndices(_ lines: [String]) -> [Int] {
        guard let b = sectionBounds(lines, "Project Files") else { return [] }
        return (b.start + 1..<b.end).filter { parseFileLine(lines[$0]) != nil }
    }

    public static func files(_ body: String) -> [ProjectFile] {
        let lines = body.components(separatedBy: "\n")
        return fileLineIndices(lines).enumerated().map { n, i in
            let f = parseFileLine(lines[i])!
            return ProjectFile(index: n, name: f.name, target: f.target)
        }
    }

    public static func filesOtherText(_ body: String) -> String {
        let lines = body.components(separatedBy: "\n")
        guard let b = sectionBounds(lines, "Project Files") else { return "" }
        return (b.start + 1..<b.end).filter { parseFileLine(lines[$0]) == nil }.map { lines[$0] }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A stored target is a URL or a path relative to the home folder starting "Documents/".
    public static func checkFileTarget(_ target: String) throws -> String {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.contains(where: { "<>\n\r".contains($0) }) { throw OpError("invalid link target: \(target)") }
        if isURL(t) { return t }
        guard t.hasPrefix("Documents/"), t.count > "Documents/".count else {
            throw OpError("file paths must be under Documents/ (got \(t))")
        }
        if t.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." }) {
            throw OpError("'..' is not allowed in file paths: \(t)")
        }
        var out = t
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    public static func defaultFileName(_ target: String) -> String {
        if isURL(target) {
            let rest = target.replacingOccurrences(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, with: "", options: .regularExpression)
            var host = String(rest.split(separator: "/", omittingEmptySubsequences: false).first ?? "")
            host = String(host.split(separator: "?", omittingEmptySubsequences: false).first ?? "")
            if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
            return host.isEmpty ? target : host
        }
        let name = String(target.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
        guard name.drop(while: { $0 == "." }).contains("."), let dot = name.lastIndex(of: ".") else { return name }
        return String(name[..<dot])
    }

    static func cleanFileName(_ name: String?, target: String) -> String {
        var n = (name ?? "").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if n.isEmpty { n = defaultFileName(target) }
        return n.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }

    public static func formatFileLine(name: String?, target: String) throws -> String {
        let t = try checkFileTarget(target)
        let dest = isURL(t) && !t.contains(where: { " ()".contains($0) }) ? t : "<\(t)>"
        return "- [\(cleanFileName(name, target: t))](\(dest))"
    }

    public static func addFile(_ body: String, name: String?, target: String) throws -> String {
        let line = try formatFileLine(name: name, target: target)
        var lines = splitBody(body)
        if let b = sectionBounds(lines, "Project Files") {
            var pos: Int
            if let last = fileLineIndices(lines).last {
                pos = last + 1
            } else {
                pos = b.end
                while pos > b.start + 1, lines[pos - 1].trimmingCharacters(in: .whitespaces).isEmpty { pos -= 1 }
            }
            lines.insert(line, at: pos)
        } else {
            let notes = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).lowercased() == "## notes" } ?? lines.count
            var block = ["## Project Files", line] + (notes < lines.count ? [""] : [])
            if notes > 0, !lines[notes - 1].trimmingCharacters(in: .whitespaces).isEmpty { block.insert("", at: 0) }
            lines.insert(contentsOf: block, at: notes)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func fileLine(_ body: String, _ index: Int) throws -> ([String], Int) {
        let lines = splitBody(body)
        let idx = fileLineIndices(lines)
        guard idx.indices.contains(index) else { throw OpError("no project file #\(index + 1)") }
        return (lines, idx[index])
    }

    /// Change the name and/or target of entry `index` (nil keeps the current value).
    public static func editFile(_ body: String, index: Int, name: String?, target: String?) throws -> String {
        var (lines, i) = try fileLine(body, index)
        let cur = parseFileLine(lines[i])!
        lines[i] = try formatFileLine(name: name ?? cur.name, target: target ?? cur.target)
        return lines.joined(separator: "\n") + "\n"
    }

    public static func removeFile(_ body: String, index: Int) throws -> String {
        var (lines, i) = try fileLine(body, index)
        lines.remove(at: i)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Turns a typed path or a picked file's URL path into "Documents/…" (URLs pass through).
    /// Accepts "Documents/…", "~/Documents/…", iCloud Drive paths (…/com~apple~CloudDocs/Documents/…),
    /// and paths inside `documentsRoot` (the user-picked Documents folder).
    public static func normalizeFilePath(_ raw: String, documentsRoot: URL? = nil) throws -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if isURL(t) { return t }
        if t.hasPrefix("~/") { t = String(t.dropFirst(2)) }
        let marker = "/com~apple~CloudDocs/Documents/"
        if let r = t.range(of: marker) { return try checkFileTarget("Documents/" + t[r.upperBound...]) }
        if let root = documentsRoot?.standardizedFileURL.path, t.hasPrefix(root + "/") {
            return try checkFileTarget("Documents/" + t.dropFirst(root.count + 1))
        }
        if t.hasPrefix("/") { throw OpError("file must be inside your Documents folder: \(t)") }
        return try checkFileTarget(t)
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
