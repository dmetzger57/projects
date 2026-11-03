import Foundation

/// Mutating operations — a port of projkit/ops.py. Each call re-reads the README,
/// applies one change and writes it back, so concurrent edits from the Mac are not lost
/// (beyond the single key being changed).
public enum Ops {
    static let badName = try! NSRegularExpression(pattern: #"[/:\x00]"#)

    static func checkName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = NSRange(name.startIndex..., in: name)
        if name.isEmpty || name.hasPrefix(".") || badName.firstMatch(in: name, range: r) != nil {
            throw OpError("invalid name: \(raw)")
        }
        return name
    }

    static func fresh(_ ws: Workspace, _ p: Project) throws -> Project {
        let q = ws.load(p.url)
        guard q.document != nil else { throw OpError(q.parseError ?? "'\(p.folderName)' has no README.md") }
        return q
    }

    static func editList(_ ws: Workspace, _ p: Project, _ key: String,
                         _ change: (inout [YAMLValue]) throws -> Void) throws {
        var q = try fresh(ws, p)
        guard q.document!.frontMatter.isEditable(key) else {
            throw OpError("'\(key)' uses YAML this app can't edit safely — edit it on the Mac")
        }
        var list = q.document!.frontMatter[key]?.list ?? []
        try change(&list)
        q.document!.frontMatter.set(key, .list(list))
        try ws.save(q)
    }

    static func setKeys(_ ws: Workspace, _ p: Project, _ values: [(String, YAMLValue)]) throws -> Project {
        var q = try fresh(ws, p)
        for (k, v) in values { q.document!.frontMatter.set(k, v) }
        try ws.save(q)
        return q
    }

    static func editBody(_ ws: Workspace, _ p: Project, _ change: (String) throws -> String) throws {
        var q = try fresh(ws, p)
        q.document!.body = try change(q.document!.body)
        try ws.save(q)
    }

    // MARK: workspace setup / areas

    /// README for `1 - Template` in a freshly set-up workspace (same shape the Mac tool migrates to).
    static let templateReadme = """
    ---
    format: 1
    title: Project
    area: Area
    status: active
    created:
    closed:
    tags: []
    goals: []
    links: []
    receipts: []
    ---

    ## Description

    ## Project Files

    ## Notes

    """

    /// Creates an area folder (names starting "<digits> - " are reserved for system folders).
    @discardableResult
    public static func newArea(_ ws: Workspace, _ rawName: String) throws -> URL {
        let name = try checkName(rawName)
        guard !Workspace.isReserved(name) else { throw OpError("area names can't start with a number and \" - \"") }
        if ws.areas().contains(where: { $0.lowercased() == name.lowercased() }) {
            throw OpError("area '\(name)' already exists")
        }
        let dir = ws.root.appendingPathComponent(name)
        try ws.fs.createDirectory(dir)
        return dir
    }

    /// Makes an empty (or partial) folder into a projects workspace. Idempotent: existing
    /// items are left alone. With `receiptsInside`, creates `3 - Receipts` for receipts.
    public static func setUpWorkspace(_ ws: Workspace, areas: [String], receiptsInside: Bool) throws {
        let tpl = ws.templateDir
        for d in [tpl, tpl.appendingPathComponent("Documents"), tpl.appendingPathComponent("Receipts"), ws.closedDir]
        where !ws.fs.exists(d) {
            try ws.fs.createDirectory(d)
        }
        let readme = tpl.appendingPathComponent(readmeName)
        if !ws.fs.exists(readme) { try ws.fs.writeText(templateReadme, to: readme) }
        if !ws.fs.exists(ws.backlogURL) { try ws.fs.writeText("# Idea Backlog\n\n", to: ws.backlogURL) }
        if receiptsInside, !ws.fs.exists(ws.internalReceiptsDir) { try ws.fs.createDirectory(ws.internalReceiptsDir) }
        var seen = Set(ws.areas().map { $0.lowercased() })
        for a in areas.map({ $0.trimmingCharacters(in: .whitespaces) }) where !a.isEmpty && seen.insert(a.lowercased()).inserted {
            try newArea(ws, a)
        }
    }

    // MARK: lifecycle

    @discardableResult
    public static func newProject(_ ws: Workspace, title rawTitle: String, area rawArea: String,
                                  status: String = "active") throws -> Project {
        let title = try checkName(rawTitle), area = try checkName(rawArea)
        guard projectStatuses.contains(status), status != "closed" else { throw OpError("invalid status for a new project: \(status)") }
        let areaDir = ws.root.appendingPathComponent(area)
        guard ws.fs.isDirectory(areaDir) else { throw OpError("area '\(area)' does not exist") }
        if let clash = ws.projectDirs().first(where: { $0.lastPathComponent.lowercased() == title.lowercased() }) {
            throw OpError("a project named '\(title)' already exists in '\(clash.deletingLastPathComponent().lastPathComponent)'")
        }
        let dir = areaDir.appendingPathComponent(title)
        guard !ws.fs.exists(dir) else { throw OpError("'\(title)' already exists") }

        try ws.fs.createDirectory(dir)
        do {
            let tpl = ws.template()
            if let tpl {
                for c in try ws.fs.children(of: tpl.url) where c.lastPathComponent != readmeName && c.pathExtension != "pages" {
                    try ws.fs.copy(c, to: dir.appendingPathComponent(c.lastPathComponent))
                }
            }
            for req in ["Documents", "Receipts"] where !ws.fs.exists(dir.appendingPathComponent(req)) {
                try ws.fs.createDirectory(dir.appendingPathComponent(req))
            }
            var fm = FrontMatter()
            fm.set("format", .scalar(String(formatVersion), quoted: false))
            fm.set("title", .string(title))
            fm.set("area", .string(area))
            fm.set("status", .string(status))
            fm.set("created", .date(ISODate.string()))
            fm.set("closed", .null)
            for k in ["tags", "goals", "links", "receipts"] { fm.set(k, .list([])) }
            var body = ReadmeBody.templateBody(tpl?.document?.body)
            body = ReadmeBody.addNote(body, text: "Project created", date: ISODate.string())
            let p = Project(url: dir, document: ProjectDocument(frontMatter: fm, body: body))
            try ws.save(p)
            return p
        } catch {
            try? ws.fs.removeItem(dir)
            throw error
        }
    }

    @discardableResult
    public static func rename(_ ws: Workspace, _ p: Project, to rawTitle: String) throws -> Project {
        let title = try checkName(rawTitle)
        let dst = p.url.deletingLastPathComponent().appendingPathComponent(title)
        let caseOnly = dst.lastPathComponent.lowercased() == p.folderName.lowercased()
        if !caseOnly, ws.projectDirs().contains(where: { $0.lastPathComponent.lowercased() == title.lowercased() }) {
            throw OpError("a project named '\(title)' already exists")
        }
        _ = try setKeys(ws, p, [("title", .string(title))])
        if caseOnly {
            let tmp = p.url.deletingLastPathComponent().appendingPathComponent(".\(p.folderName).renaming")
            try ws.fs.move(p.url, to: tmp)
            try ws.fs.move(tmp, to: dst)
        } else {
            try ws.fs.move(p.url, to: dst)
        }
        return ws.load(dst)
    }

    public static func setStatus(_ ws: Workspace, _ p: Project, _ status: String) throws {
        guard projectStatuses.contains(status), status != "closed" else {
            throw OpError(status == "closed" ? "use Close to close a project" : "bad status \(status)")
        }
        _ = try setKeys(ws, p, [("status", .string(status))])
    }

    @discardableResult
    public static func close(_ ws: Workspace, _ p: Project) throws -> Project {
        guard !ws.isInClosed(p) else { throw OpError("project is already closed") }
        let dst = ws.closedDir.appendingPathComponent(p.folderName)
        guard !ws.fs.exists(dst) else { throw OpError("'\(p.folderName)' already exists in Closed") }
        if !ws.fs.isDirectory(ws.closedDir) { try ws.fs.createDirectory(ws.closedDir) }
        var q = try fresh(ws, p)
        let area = q.area ?? ws.locationArea(q) ?? ""
        q.document!.frontMatter.set("area", .string(area))
        q.document!.frontMatter.set("status", .string("closed"))
        q.document!.frontMatter.set("closed", .date(ISODate.string()))
        q.document!.body = ReadmeBody.addNote(q.document!.body, text: "Project closed", date: ISODate.string())
        try ws.save(q)
        try ws.fs.move(p.url, to: dst)
        return ws.load(dst)
    }

    @discardableResult
    public static func reopen(_ ws: Workspace, _ p: Project, area: String? = nil) throws -> Project {
        guard ws.isInClosed(p) else { throw OpError("project is not closed") }
        let a = try checkName(area ?? p.area ?? "")
        let areaDir = ws.root.appendingPathComponent(a)
        guard ws.fs.isDirectory(areaDir) else { throw OpError("area '\(a)' does not exist") }
        let dst = areaDir.appendingPathComponent(p.folderName)
        guard !ws.fs.exists(dst) else { throw OpError("'\(p.folderName)' already exists in \(a)") }
        var q = try fresh(ws, p)
        q.document!.frontMatter.set("area", .string(a))
        q.document!.frontMatter.set("status", .string("active"))
        q.document!.frontMatter.set("closed", .null)
        q.document!.body = ReadmeBody.addNote(q.document!.body, text: "Project reopened", date: ISODate.string())
        try ws.save(q)
        try ws.fs.move(p.url, to: dst)
        return ws.load(dst)
    }

    // MARK: notes / sections

    public static func addNote(_ ws: Workspace, _ p: Project, _ text: String, date: String = ISODate.string()) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try editBody(ws, p) { ReadmeBody.addNote($0, text: text, date: date) }
    }

    public static func setSection(_ ws: Workspace, _ p: Project, _ heading: String, _ text: String) throws {
        try editBody(ws, p) { try ReadmeBody.setSection($0, heading: heading, text: text) }
    }

    // MARK: goals

    public static func addGoal(_ ws: Workspace, _ p: Project, _ text: String) throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        try editList(ws, p, "goals") { $0.append(.map(YAMLMap([("text", .string(t)), ("done", .bool(false))]))) }
    }

    public static func setGoal(_ ws: Workspace, _ p: Project, index: Int, done: Bool) throws {
        try editList(ws, p, "goals") { goals in
            guard goals.indices.contains(index) else { throw OpError("no goal #\(index + 1)") }
            var m = goals[index].map ?? YAMLMap([("text", goals[index])])
            m["done"] = .bool(done)
            m["done_on"] = done ? .date(ISODate.string()) : nil
            goals[index] = .map(m)
        }
    }

    public static func removeGoal(_ ws: Workspace, _ p: Project, index: Int) throws {
        try editList(ws, p, "goals") { goals in
            guard goals.indices.contains(index) else { throw OpError("no goal #\(index + 1)") }
            goals.remove(at: index)
        }
    }

    // MARK: links

    public static func addLink(_ ws: Workspace, _ p: Project, url: String, title: String?) throws {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard u.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, options: .regularExpression) != nil else {
            throw OpError("not a URL: \(u)")
        }
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        try editList(ws, p, "links") {
            $0.append(.map(YAMLMap([("title", .string(t?.isEmpty == false ? t! : u)), ("url", .string(u))])))
        }
    }

    public static func removeLink(_ ws: Workspace, _ p: Project, index: Int) throws {
        try editList(ws, p, "links") { links in
            guard links.indices.contains(index) else { throw OpError("no link #\(index + 1)") }
            links.remove(at: index)
        }
    }

    // MARK: receipts

    public static func receiptFileName(description: String, date: String, ext: String) -> String {
        var desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        desc = badName.stringByReplacingMatches(in: desc, range: NSRange(desc.startIndex..., in: desc), withTemplate: "-")
        if desc.range(of: #"^\d{4}-\d{2}-\d{2} "#, options: .regularExpression) != nil { desc = String(desc.dropFirst(11)) }
        if desc.isEmpty { desc = "Receipt" }
        let e = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return "\(date) \(desc)" + (e.isEmpty ? "" : ".\(e)")
    }

    /// Files `data` as <receipts>/<year>/<date> <description>.<ext> and references it.
    /// (Finder tag `receipt` can't be set on iOS; `proj lint --fix` on the Mac adds it.)
    @discardableResult
    public static func addReceipt(_ ws: Workspace, _ p: Project, data: Data, fileExtension: String,
                                  description: String, amount: Double?, vendor: String?,
                                  date: String = ISODate.string()) throws -> String {
        guard let root = ws.receiptsRoot else { throw OpError("choose the Receipts folder in Settings first") }
        guard ISODate.isValid(date) else { throw OpError("bad date: \(date)") }
        let yearDir = root.appendingPathComponent(String(date.prefix(4)))
        let name = receiptFileName(description: description.isEmpty ? (vendor ?? "") : description,
                                   date: date, ext: fileExtension)
        let target = yearDir.appendingPathComponent(name)
        let rel = "\(date.prefix(4))/\(name)"
        guard !ws.fs.exists(target) else { throw OpError("receipt already exists: \(rel)") }
        if p.receipts.contains(where: { $0.path == rel }) { throw OpError("receipt already attached: \(rel)") }
        if !ws.fs.isDirectory(yearDir) { try ws.fs.createDirectory(yearDir) }
        try ws.fs.writeData(data, to: target)
        let v = vendor?.trimmingCharacters(in: .whitespacesAndNewlines)
        try editList(ws, p, "receipts") {
            $0.append(.map(YAMLMap([("path", .string(rel)),
                                    ("amount", amount.map { .number($0) } ?? .null),
                                    ("vendor", v?.isEmpty == false ? .string(v!) : .null),
                                    ("date", .date(date))])))
        }
        return rel
    }

    /// Detach a receipt (the file stays in the receipts folder).
    public static func removeReceipt(_ ws: Workspace, _ p: Project, index: Int) throws {
        try editList(ws, p, "receipts") { r in
            guard r.indices.contains(index) else { throw OpError("no receipt #\(index + 1)") }
            r.remove(at: index)
        }
    }

    public static func receiptURL(_ ws: Workspace, _ r: Receipt) -> URL? {
        guard let root = ws.receiptsRoot else { return nil }
        let u = root.appendingPathComponent(r.path).standardizedFileURL
        return u.path.hasPrefix(root.standardizedFileURL.path + "/") ? u : nil
    }

    // MARK: idea backlog

    public static func ideas(_ ws: Workspace) -> [String] {
        guard let text = try? ws.fs.readText(ws.backlogURL) else { return [] }
        return text.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
    }

    static func writeIdeas(_ ws: Workspace, _ items: [String]) throws {
        let existing = (try? ws.fs.readText(ws.backlogURL)) ?? ""
        var head = existing.components(separatedBy: "\n").prefix { !$0.hasPrefix("- ") }.joined(separator: "\n")
        while head.hasSuffix("\n") || head.hasSuffix(" ") { head.removeLast() }
        if head.isEmpty { head = "# Idea Backlog" }
        try ws.fs.writeText(head + "\n\n" + items.map { "- \($0)\n" }.joined(), to: ws.backlogURL)
    }

    public static func addIdea(_ ws: Workspace, _ text: String) throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !t.isEmpty else { return }
        try writeIdeas(ws, ideas(ws) + [t])
    }

    @discardableResult
    public static func removeIdea(_ ws: Workspace, index: Int) throws -> String {
        var items = ideas(ws)
        guard items.indices.contains(index) else { throw OpError("no idea #\(index + 1)") }
        let t = items.remove(at: index)
        try writeIdeas(ws, items)
        return t
    }

    @discardableResult
    public static func promoteIdea(_ ws: Workspace, index: Int, area: String, title: String? = nil) throws -> Project {
        let items = ideas(ws)
        guard items.indices.contains(index) else { throw OpError("no idea #\(index + 1)") }
        let idea = items[index]
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = try newProject(ws, title: name?.isEmpty == false ? name! : idea, area: area)
        try addNote(ws, p, "Promoted from idea backlog: \(idea)")
        try removeIdea(ws, index: index)
        return ws.load(p.url)
    }
}
