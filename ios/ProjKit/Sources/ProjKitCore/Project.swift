import Foundation

public let readmeName = "README.md"
public let formatVersion = 1
public let projectStatuses = ["idea", "backlog", "active", "blocked", "on-hold", "completed-on-hold", "closed"]
/// Set automatically when the last open task is ticked. Mirrors projkit `COMPLETED_ON_HOLD`.
public let completedOnHold = "completed-on-hold"

/// How a status is shown ("on-hold" → "On Hold"); files keep the names. Mirrors projkit `STATUS_LABELS`.
public let projectStatusLabels = ["idea": "Idea", "backlog": "Backlog", "active": "Active", "blocked": "Blocked",
                                  "on-hold": "On Hold", completedOnHold: "Completed – On Hold", "closed": "Closed",
                                  "legacy": "Legacy"]

public func statusLabel(_ status: String) -> String { projectStatusLabels[status] ?? status }

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
    /// Attachments: indented links under the task (files under Documents/ or URLs); index is per task.
    public var files: [ProjectFile] = []
    /// Notes: the task's other indented detail lines ("  - text"); index is per task.
    public var notes: [TaskNote] = []
    /// Photos: indented "  - ![note](<Photos/file.jpg>)" lines; index is per task.
    public var photos: [ProjectPhoto] = []
    /// Hidden link shared with its copy in Today ("<!-- task:k3x9q2ab -->" at the end of the line).
    public var linkID: String? = nil
    /// Set on tasks in the Archive: when it was archived ("YYYY-MM-DD") and the project folder it came from.
    public var archived: String? = nil
    public var archivedFrom: String? = nil
    /// An Apple Reminder was scheduled for this task, at this local time ("YYYY-MM-DDTHH:MM").
    public var reminder: String? = nil
    public var id: Int { index }
}

/// A photo: a Markdown image of a file in the project's own Photos/ folder, with the note as caption.
public struct ProjectPhoto: Identifiable, Hashable, Sendable {
    public let index: Int          // 0-based position among the project's (or the task's) photos
    public let note: String
    public let path: String        // "Photos/<file>", relative to the project folder
    public var id: Int { index }
    public var fileName: String { String(path.dropFirst(photoDirName.count + 1)) }

    public init(index: Int, note: String, path: String) {
        self.index = index; self.note = note; self.path = path
    }
}

/// Folder inside each project (and the Archive) that holds its photos.
public let photoDirName = "Photos"

public struct TaskNote: Identifiable, Hashable, Sendable {
    public let index: Int          // 0-based position among the task's notes
    public let text: String
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

    public var photos: [ProjectPhoto] { document.map { ReadmeBody.photos($0.body) } ?? [] }

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
        return taskBlocks(lines).enumerated().map { n, b in
            let raw = parseTask(lines[b.start])!
            let (visible, linkID) = splitTaskText(raw.text)
            let (rest, archived, from) = splitArchived(visible)
            let (text, reminder) = splitReminder(rest)
            let t = (done: raw.done, text: text)
            let files = taskFileIndices(lines, b).enumerated().map { k, j in
                let f = parseFileLine(stripIndent(lines[j]))!
                return ProjectFile(index: k, name: f.name, target: f.target)
            }
            let notes = taskNoteIndices(lines, b).enumerated().map { k, j in TaskNote(index: k, text: parseTaskNote(lines[j])) }
            let photos = taskPhotoIndices(lines, b).enumerated().map { k, j in
                let ph = parsePhotoLine(stripIndent(lines[j]))!
                return ProjectPhoto(index: k, note: ph.note, path: ph.path)
            }
            return ProjectTask(index: n, text: t.text, done: t.done, files: files, notes: notes, photos: photos,
                               linkID: linkID, archived: archived, archivedFrom: from, reminder: reminder)
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

    // MARK: Today links — byte-identical with projkit (TASK_ID_RE, split_task_text, _task_suffix)

    static let taskIDRegex = try! NSRegularExpression(pattern: #"\s*<!--\s*task:([A-Za-z0-9]+)\s*-->\s*$"#)

    /// (visible text, link id or nil) of a task line's text.
    public static func splitTaskText(_ text: String) -> (String, String?) {
        let ns = text as NSString
        guard let m = taskIDRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return (text.trimmingCharacters(in: .whitespaces), nil)
        }
        return (ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces), ns.substring(with: m.range(at: 1)))
    }

    static func taskSuffix(_ id: String?) -> String { id.map { " <!-- task:\($0) -->" } ?? "" }

    /// Gives task `index` a link id (replacing any it had).
    public static func setTaskID(_ body: String, index: Int, id: String) throws -> String {
        var (lines, i) = try taskLine(body, index)
        lines[i] = String(lines[i].prefix(6)) + splitTaskText(String(lines[i].dropFirst(6))).0 + taskSuffix(id)
        return lines.joined(separator: "\n") + "\n"
    }

    public static func addTask(_ body: String, text: String, linkID: String? = nil) throws -> String {
        addTaskBlock(body, ["- [ ] " + (try cleanTask(text)) + taskSuffix(linkID)])
    }

    /// Adds a task line (block[0]) with its detail lines after the last task.
    public static func addTaskBlock(_ body: String, _ block: [String]) -> String {
        var lines = splitBody(body)
        if let b = sectionBounds(lines, "Tasks") {
            var pos: Int
            if let last = taskBlocks(lines).last {
                pos = last.end           // after the last task's detail lines (attachments stay with it)
            } else {
                pos = b.end
                while pos > b.start + 1, lines[pos - 1].trimmingCharacters(in: .whitespaces).isEmpty { pos -= 1 }
            }
            lines.insert(contentsOf: block, at: pos)
        } else {
            let notes = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).lowercased() == "## notes" } ?? lines.count
            var new = ["## Tasks"] + block + (notes < lines.count ? [""] : [])
            if notes > 0, !lines[notes - 1].trimmingCharacters(in: .whitespaces).isEmpty { new.insert("", at: 0) }
            lines.insert(contentsOf: new, at: notes)
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
        let (visible, id) = splitTaskText(String(lines[i].dropFirst(6)))
        let (rest, date, from) = splitArchived(visible)
        lines[i] = String(lines[i].prefix(6)) + (try cleanTask(text)) + reminderSuffix(splitReminder(rest).1)
            + archivedSuffix(date, from) + taskSuffix(id)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Reminder marker — byte-identical with projkit (REMINDER_RE, split_reminder, body_set_task_reminder)

    static let reminderRegex = try! NSRegularExpression(
        pattern: #"\s*<!--\s*reminder:(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})\s*-->\s*$"#)

    /// (text, reminder "YYYY-MM-DDTHH:MM" or nil) of a task's text (link id and archive marker already removed).
    public static func splitReminder(_ text: String) -> (String, String?) {
        let ns = text as NSString
        guard let m = reminderRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return (text.trimmingCharacters(in: .whitespaces), nil)
        }
        return (ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces), ns.substring(with: m.range(at: 1)))
    }

    static func reminderSuffix(_ when: String?) -> String { when.map { " <!-- reminder:\($0) -->" } ?? "" }

    /// Records (or with nil, clears) the Apple Reminder scheduled for task `index` ("YYYY-MM-DDTHH:MM"),
    /// keeping its archive marker and link id.
    public static func setTaskReminder(_ body: String, index: Int, when: String?) throws -> String {
        if let w = when, w.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$"#, options: .regularExpression) == nil {
            throw OpError("reminder time must be YYYY-MM-DDTHH:MM, not '\(w)'")
        }
        var (lines, i) = try taskLine(body, index)
        let (visible, id) = splitTaskText(String(lines[i].dropFirst(6)))
        let (rest, date, from) = splitArchived(visible)
        lines[i] = String(lines[i].prefix(6)) + splitReminder(rest).0 + reminderSuffix(when)
            + archivedSuffix(date, from) + taskSuffix(id)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Archive marker — byte-identical with projkit (ARCHIVED_RE, split_archived, body_set_task_archived)

    static let archivedRegex = try! NSRegularExpression(
        pattern: #"\s*<!--\s*archived:(\d{4}-\d{2}-\d{2})\s+from:(.*?)\s*-->\s*$"#)

    /// (text, archive date, original project folder) of a task's visible text (link id already removed).
    public static func splitArchived(_ text: String) -> (String, String?, String?) {
        let ns = text as NSString
        guard let m = archivedRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return (text.trimmingCharacters(in: .whitespaces), nil, nil)
        }
        return (ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces),
                ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces))
    }

    static func archivedSuffix(_ date: String?, _ from: String?) -> String {
        guard let date, let from else { return "" }
        return " <!-- archived:\(date) from:\(from) -->"
    }

    /// Sets (or with date nil, clears) the archive marker of task `index`, keeping its link id.
    public static func setTaskArchived(_ body: String, index: Int, date: String?, from: String?) throws -> String {
        let src = from?.trimmingCharacters(in: .whitespaces)
        if let f = from, f.contains("-->") || f.contains("\n") || src!.isEmpty {
            throw OpError("can't record '\(f)' as a task's project")
        }
        var (lines, i) = try taskLine(body, index)
        let (visible, id) = splitTaskText(String(lines[i].dropFirst(6)))
        lines[i] = String(lines[i].prefix(6)) + splitArchived(visible).0 + archivedSuffix(date, src) + taskSuffix(id)
        return lines.joined(separator: "\n") + "\n"
    }

    /// The task line and its indented detail lines.
    public static func taskBlock(_ body: String, index: Int) throws -> [String] {
        let lines = splitBody(body)
        let blocks = taskBlocks(lines)
        guard blocks.indices.contains(index) else { throw OpError("no task #\(index + 1)") }
        return Array(lines[blocks[index].start..<blocks[index].end])
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
    /// Keeps done tasks below open ones: a done task moves to the bottom, an open one to just above
    /// the first done task. Returns the new body and the task's new index. Mirrors projkit `body_settle_task`.
    public static func settleTask(_ body: String, index: Int) throws -> (body: String, index: Int) {
        let done = tasks(body).map(\.done)
        guard done.indices.contains(index) else { throw OpError("no task #\(index + 1)") }
        var others = done
        others.remove(at: index)
        let to = done[index] ? done.count - 1 : (others.firstIndex(of: true) ?? others.count)
        return (try moveTask(body, index: index, to: to), to)
    }

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

    // MARK: task attachments — byte-identical with projkit/ops.py body_*_task_file

    static let taskFileIndent = "  "

    static func stripIndent(_ l: String) -> String { String(l.drop { $0 == " " || $0 == "\t" }) }

    /// Attachment lines of a task: indented Project-Files-style links among its detail lines.
    static func taskFileIndices(_ lines: [String], _ b: (start: Int, end: Int)) -> [Int] {
        (b.start + 1..<b.end).filter { parseFileLine(stripIndent(lines[$0])) != nil }
    }

    static func taskFileLine(_ body: String, task: Int, index: Int) throws -> ([String], Int) {
        let lines = splitBody(body)
        let blocks = taskBlocks(lines)
        guard blocks.indices.contains(task) else { throw OpError("no task #\(task + 1)") }
        let idx = taskFileIndices(lines, blocks[task])
        guard idx.indices.contains(index) else { throw OpError("task #\(task + 1) has no attachment #\(index + 1)") }
        return (lines, idx[index])
    }

    /// Adds an attachment after the task's last attachment (or at the end of its detail lines).
    public static func addTaskFile(_ body: String, task: Int, name: String?, target: String) throws -> String {
        let line = taskFileIndent + (try formatFileLine(name: name, target: target))
        var lines = splitBody(body)
        let blocks = taskBlocks(lines)
        guard blocks.indices.contains(task) else { throw OpError("no task #\(task + 1)") }
        let idx = taskFileIndices(lines, blocks[task])
        lines.insert(line, at: idx.last.map { $0 + 1 } ?? blocks[task].end)
        return lines.joined(separator: "\n") + "\n"
    }

    public static func editTaskFile(_ body: String, task: Int, index: Int, name: String?, target: String?) throws -> String {
        var (lines, i) = try taskFileLine(body, task: task, index: index)
        let stripped = stripIndent(lines[i])
        let cur = parseFileLine(stripped)!
        let indent = String(lines[i].prefix(lines[i].count - stripped.count))
        lines[i] = indent + (try formatFileLine(name: name ?? cur.name, target: target ?? cur.target))
        return lines.joined(separator: "\n") + "\n"
    }

    public static func removeTaskFile(_ body: String, task: Int, index: Int) throws -> String {
        var (lines, i) = try taskFileLine(body, task: task, index: index)
        lines.remove(at: i)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: task notes — byte-identical with projkit/ops.py body_*_task_note

    /// Note lines of a task: every detail line that isn't an attachment or a photo.
    static func taskNoteIndices(_ lines: [String], _ b: (start: Int, end: Int)) -> [Int] {
        (b.start + 1..<b.end).filter {
            parseFileLine(stripIndent(lines[$0])) == nil && parsePhotoLine(stripIndent(lines[$0])) == nil
        }
    }

    /// Text of a note line ("  - text"; a hand-written line without the bullet also counts).
    static func parseTaskNote(_ line: String) -> String {
        let t = stripIndent(line)
        let body = t.hasPrefix("- ") || t.hasPrefix("* ") ? String(t.dropFirst(2)) : t
        return body.trimmingCharacters(in: .whitespaces)
    }

    static func cleanTaskNote(_ text: String) throws -> String {
        let t = text.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { throw OpError("note text is empty") }
        guard parseFileLine("- " + t) == nil else { throw OpError("a note can't be just a link; attach it to the task instead") }
        guard parsePhotoLine("- " + t) == nil else { throw OpError("a note can't be just a photo; add the photo to the task instead") }
        return t
    }

    static func taskNoteLine(_ body: String, task: Int, index: Int) throws -> ([String], Int) {
        let lines = splitBody(body)
        let blocks = taskBlocks(lines)
        guard blocks.indices.contains(task) else { throw OpError("no task #\(task + 1)") }
        let idx = taskNoteIndices(lines, blocks[task])
        guard idx.indices.contains(index) else { throw OpError("task #\(task + 1) has no note #\(index + 1)") }
        return (lines, idx[index])
    }

    /// Adds a note after the task's last note (or directly under the task line).
    public static func addTaskNote(_ body: String, task: Int, text: String) throws -> String {
        let line = taskFileIndent + "- " + (try cleanTaskNote(text))
        var lines = splitBody(body)
        let blocks = taskBlocks(lines)
        guard blocks.indices.contains(task) else { throw OpError("no task #\(task + 1)") }
        let idx = taskNoteIndices(lines, blocks[task])
        lines.insert(line, at: idx.last.map { $0 + 1 } ?? blocks[task].start + 1)
        return lines.joined(separator: "\n") + "\n"
    }

    public static func editTaskNote(_ body: String, task: Int, index: Int, text: String) throws -> String {
        var (lines, i) = try taskNoteLine(body, task: task, index: index)
        let stripped = stripIndent(lines[i])
        lines[i] = String(lines[i].prefix(lines[i].count - stripped.count)) + "- " + (try cleanTaskNote(text))
        return lines.joined(separator: "\n") + "\n"
    }

    public static func removeTaskNote(_ body: String, task: Int, index: Int) throws -> String {
        var (lines, i) = try taskNoteLine(body, task: task, index: index)
        lines.remove(at: i)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: photos — byte-identical with projkit (PHOTO_RE, parse_photo_line, body_*_photo)

    static let photoRegex = try! NSRegularExpression(pattern: #"^- !\[([^\]]*)\]\((<[^<>]*>|[^\s()<>]+)\)\s*$"#)

    /// (note, path) of a photo line ("Photos/<file>" only; other images are left alone).
    public static func parsePhotoLine(_ line: String) -> (note: String, path: String)? {
        let ns = line as NSString
        guard let m = photoRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var path = ns.substring(with: m.range(at: 2))
        if path.hasPrefix("<") { path = String(path.dropFirst().dropLast()) }
        let prefix = photoDirName + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let name = path.dropFirst(prefix.count)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        return (ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces), path)
    }

    static func photoLineIndices(_ lines: [String]) -> [Int] {
        guard let b = sectionBounds(lines, "Photos") else { return [] }
        return (b.start + 1..<b.end).filter { parsePhotoLine(lines[$0]) != nil }
    }

    /// Photo lines of a task: indented photo lines among its detail lines.
    static func taskPhotoIndices(_ lines: [String], _ b: (start: Int, end: Int)) -> [Int] {
        (b.start + 1..<b.end).filter { parsePhotoLine(stripIndent(lines[$0])) != nil }
    }

    public static func photos(_ body: String) -> [ProjectPhoto] {
        let lines = body.components(separatedBy: "\n")
        return photoLineIndices(lines).enumerated().map { k, i in
            let ph = parsePhotoLine(lines[i])!
            return ProjectPhoto(index: k, note: ph.note, path: ph.path)
        }
    }

    /// Every photo path the body refers to (project and task photos).
    static func referencedPhotos(_ body: String) -> Set<String> {
        Set(body.components(separatedBy: "\n").compactMap { parsePhotoLine(stripIndent($0))?.path })
    }

    static func cleanPhotoNote(_ note: String?) -> String {
        (note ?? "").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }

    public static func formatPhotoLine(note: String?, path: String) throws -> String {
        guard parsePhotoLine("- ![](<\(path)>)") != nil else { throw OpError("not a photo path: \(path)") }
        return "- ![\(cleanPhotoNote(note))](<\(path)>)"
    }

    static func photoLine(_ body: String, index: Int) throws -> ([String], Int) {
        let lines = splitBody(body)
        let idx = photoLineIndices(lines)
        guard idx.indices.contains(index) else { throw OpError("no photo #\(index + 1)") }
        return (lines, idx[index])
    }

    /// Adds a photo after the last one in ## Photos (creating the section just before ## Notes, or at the end).
    public static func addPhoto(_ body: String, note: String?, path: String) throws -> String {
        let line = try formatPhotoLine(note: note, path: path)
        var lines = splitBody(body)
        if let b = sectionBounds(lines, "Photos") {
            var pos: Int
            if let last = photoLineIndices(lines).last {
                pos = last + 1
            } else {
                pos = b.end
                while pos > b.start + 1, lines[pos - 1].trimmingCharacters(in: .whitespaces).isEmpty { pos -= 1 }
            }
            lines.insert(line, at: pos)
        } else {
            let notes = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).lowercased() == "## notes" } ?? lines.count
            var new = ["## Photos", line] + (notes < lines.count ? [""] : [])
            if notes > 0, !lines[notes - 1].trimmingCharacters(in: .whitespaces).isEmpty { new.insert("", at: 0) }
            lines.insert(contentsOf: new, at: notes)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func editPhoto(_ body: String, index: Int, note: String?) throws -> String {
        var (lines, i) = try photoLine(body, index: index)
        lines[i] = try formatPhotoLine(note: note, path: parsePhotoLine(lines[i])!.path)
        return lines.joined(separator: "\n") + "\n"
    }

    public static func removePhoto(_ body: String, index: Int) throws -> String {
        var (lines, i) = try photoLine(body, index: index)
        lines.remove(at: i)
        return lines.joined(separator: "\n") + "\n"
    }

    static func taskPhotoLine(_ body: String, task: Int, index: Int) throws -> ([String], Int) {
        let lines = splitBody(body)
        let blocks = taskBlocks(lines)
        guard blocks.indices.contains(task) else { throw OpError("no task #\(task + 1)") }
        let idx = taskPhotoIndices(lines, blocks[task])
        guard idx.indices.contains(index) else { throw OpError("task #\(task + 1) has no photo #\(index + 1)") }
        return (lines, idx[index])
    }

    /// Adds a photo after the task's last photo (or at the end of its detail lines).
    public static func addTaskPhoto(_ body: String, task: Int, note: String?, path: String) throws -> String {
        let line = taskFileIndent + (try formatPhotoLine(note: note, path: path))
        var lines = splitBody(body)
        let blocks = taskBlocks(lines)
        guard blocks.indices.contains(task) else { throw OpError("no task #\(task + 1)") }
        let idx = taskPhotoIndices(lines, blocks[task])
        lines.insert(line, at: idx.last.map { $0 + 1 } ?? blocks[task].end)
        return lines.joined(separator: "\n") + "\n"
    }

    public static func editTaskPhoto(_ body: String, task: Int, index: Int, note: String?) throws -> String {
        var (lines, i) = try taskPhotoLine(body, task: task, index: index)
        let stripped = stripIndent(lines[i])
        lines[i] = String(lines[i].prefix(lines[i].count - stripped.count))
            + (try formatPhotoLine(note: note, path: parsePhotoLine(stripped)!.path))
        return lines.joined(separator: "\n") + "\n"
    }

    public static func removeTaskPhoto(_ body: String, task: Int, index: Int) throws -> String {
        var (lines, i) = try taskPhotoLine(body, task: task, index: index)
        lines.remove(at: i)
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
