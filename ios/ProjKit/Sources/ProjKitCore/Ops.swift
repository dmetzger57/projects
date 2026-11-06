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
        try retargetArchived(ws, from: p.folderName, to: title)
        try retargetOverview(ws, from: p.folderName, to: title)
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

    // MARK: tasks (## Tasks checklist in the body)

    public static func addTask(_ ws: Workspace, _ p: Project, _ text: String) throws {
        try editBody(ws, p) { try ReadmeBody.addTask($0, text: text) }
    }

    /// Ticks or unticks a task, and every linked copy (Today <-> its project).
    public static func setTask(_ ws: Workspace, _ p: Project, index: Int, done: Bool) throws {
        try editBody(ws, p) { try ReadmeBody.setTask($0, index: index, done: done) }
        let t = ws.load(p.url).tasks
        if t.indices.contains(index), let id = t[index].linkID {
            try syncTaskDone(ws, id: id, done: done, skip: p.url)
        }
    }

    // MARK: Today list — mirrors projkit/ops.py (ensure_today, copy_to_today, sync_task_done, …)

    static let todayReadme = "---\nformat: 1\ntitle: Today\narea: Today\nstatus: active\n---\n\n## Tasks\n"

    public static func newTaskID() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }

    @discardableResult
    public static func ensureToday(_ ws: Workspace) throws -> Project {
        if let t = ws.today() { return t }
        if !ws.fs.isDirectory(ws.todayDir) { try ws.fs.createDirectory(ws.todayDir) }
        let readme = ws.todayDir.appendingPathComponent(readmeName)
        if !ws.fs.exists(readme) { try ws.fs.writeText(todayReadme, to: readme) }
        return ws.load(ws.todayDir)
    }

    /// Everything a task link can point into: all projects (closed too) plus Today and the Archive.
    static func linkedProjects(_ ws: Workspace) -> [Project] {
        (ws.projects() + [ws.today(), ws.archive()].compactMap { $0 }).filter { $0.document != nil }
    }

    static func syncTaskDone(_ ws: Workspace, id: String, done: Bool, skip: URL?) throws {
        for q in linkedProjects(ws) where q.url.standardizedFileURL != skip?.standardizedFileURL {
            let hits = q.tasks.filter { $0.linkID == id && $0.done != done }
            guard !hits.isEmpty else { continue }
            try editBody(ws, q) { body in
                try hits.reduce(body) { try ReadmeBody.setTask($0, index: $1.index, done: done) }
            }
        }
    }

    /// Copies a project's task into Today, linked so done state stays in step.
    /// Returns false when it was already there.
    @discardableResult
    public static func copyToToday(_ ws: Workspace, _ p: Project, index: Int) throws -> Bool {
        guard !ws.isToday(p) else { throw OpError("that task is already in Today") }
        let tasks = try fresh(ws, p).tasks
        guard tasks.indices.contains(index) else { throw OpError("no task #\(index + 1)") }
        let t = tasks[index]
        let id = t.linkID ?? newTaskID()
        if t.linkID == nil { try editBody(ws, p) { try ReadmeBody.setTaskID($0, index: index, id: id) } }
        let today = try ensureToday(ws)
        if today.tasks.contains(where: { $0.linkID == id }) { return false }
        try editBody(ws, today) { body in
            var b = try ReadmeBody.addTask(body, text: t.text, linkID: id)
            if t.done { b = try ReadmeBody.setTask(b, index: ReadmeBody.tasks(b).count - 1, done: true) }
            return b
        }
        return true
    }

    /// Removes ticked-off tasks from Today (their originals are untouched). Returns how many.
    @discardableResult
    public static func clearTodayDone(_ ws: Workspace) throws -> Int {
        guard let today = ws.today() else { return 0 }
        let done = today.tasks.filter(\.done).map(\.index)
        guard !done.isEmpty else { return 0 }
        try editBody(ws, today) { body in try done.reversed().reduce(body) { try ReadmeBody.removeTask($0, index: $1) } }
        return done.count
    }

    // MARK: Archive — mirrors projkit/ops.py (archive_task, restore_task, filter_archived, …)

    static let archiveReadme = "---\nformat: 1\ntitle: Archive\narea: Archive\nstatus: active\n---\n\n## Tasks\n"

    public enum ArchiveSort: String, CaseIterable, Sendable { case newest, oldest, name, project }

    @discardableResult
    public static func ensureArchive(_ ws: Workspace) throws -> Project {
        if let a = ws.archive() { return a }
        if !ws.fs.isDirectory(ws.archiveDir) { try ws.fs.createDirectory(ws.archiveDir) }
        let readme = ws.archiveDir.appendingPathComponent(readmeName)
        if !ws.fs.exists(readme) { try ws.fs.writeText(archiveReadme, to: readme) }
        return ws.load(ws.archiveDir)
    }

    /// Moves a task (with its notes and attachments) from its project to the Archive, recording the
    /// project and the date. Its Today link id is kept.
    public static func archiveTask(_ ws: Workspace, _ p: Project, index: Int, date: String = ISODate.string()) throws {
        guard !ws.isToday(p), !ws.isArchive(p) else { throw OpError("only tasks in a project can be archived") }
        let q = try fresh(ws, p)
        let block = try ReadmeBody.taskBlock(q.document!.body, index: index)
        let a = try ensureArchive(ws)
        let photos = q.tasks.indices.contains(index) ? q.tasks[index].photos : []
        try checkPhotoMove(ws, photos, from: q.url, to: a.url)
        try editBody(ws, a) { body in
            let b = ReadmeBody.addTaskBlock(body, block)
            return try ReadmeBody.setTaskArchived(b, index: ReadmeBody.tasks(b).count - 1, date: date, from: p.folderName)
        }                                    // written before the original is removed: never lost
        try movePhotos(ws, photos, from: q.url, to: a.url)
        try editBody(ws, q) { try ReadmeBody.removeTask($0, index: index) }
    }

    /// Archived tasks, optionally only from `project` (folder name, case-insensitive) or archived on or
    /// after `since` ("YYYY-MM-DD"), sorted newest first, oldest first, by name or by project.
    public static func filterArchived(_ tasks: [ProjectTask], project: String? = nil, since: String? = nil,
                                      sort: ArchiveSort = .newest) -> [ProjectTask] {
        let out = tasks.filter { t in
            (project == nil || (t.archivedFrom ?? "").lowercased() == project!.lowercased())
                && (since == nil || (t.archived ?? "") >= since!)
        }
        func newer(_ a: ProjectTask, _ b: ProjectTask) -> Bool {
            let (x, y) = (a.archived ?? "", b.archived ?? "")
            return x != y ? x > y : a.index > b.index
        }
        switch sort {
        case .newest: return out.sorted(by: newer)
        case .oldest: return out.sorted { newer($1, $0) }
        case .name:
            return out.sorted {
                let (x, y) = ($0.text.lowercased(), $1.text.lowercased())
                return x != y ? x < y : $0.index < $1.index
            }
        case .project:
            return out.sorted {
                let (x, y) = (($0.archivedFrom ?? "").lowercased(), ($1.archivedFrom ?? "").lowercased())
                return x != y ? x < y : newer($0, $1)
            }
        }
    }

    /// Original project names found in the Archive, A-Z.
    public static func archiveProjects(_ archive: Project?) -> [String] {
        Set(archive?.tasks.compactMap(\.archivedFrom) ?? []).sorted { $0.lowercased() < $1.lowercased() }
    }

    /// Moves an archived task back to the end of its project's task list. Returns that project.
    @discardableResult
    public static func restoreTask(_ ws: Workspace, index: Int) throws -> Project {
        guard let a = ws.archive() else { throw OpError("the Archive is empty") }
        let tasks = try fresh(ws, a).tasks
        guard tasks.indices.contains(index) else { throw OpError("no task #\(index + 1)") }
        let from = tasks[index].archivedFrom ?? ""
        guard let p = ws.projects().first(where: { !from.isEmpty && $0.folderName.lowercased() == from.lowercased() }) else {
            throw OpError("project '\(from)' no longer exists")
        }
        let block = try ReadmeBody.taskBlock(try fresh(ws, a).document!.body, index: index)
        let photos = tasks[index].photos
        try checkPhotoMove(ws, photos, from: a.url, to: p.url)
        try editBody(ws, p) { body in
            let b = ReadmeBody.addTaskBlock(body, block)
            return try ReadmeBody.setTaskArchived(b, index: ReadmeBody.tasks(b).count - 1, date: nil, from: nil)
        }
        try movePhotos(ws, photos, from: a.url, to: p.url)
        try editBody(ws, a) { try ReadmeBody.removeTask($0, index: index) }
        return ws.load(p.url)
    }

    /// Moves a task (with its notes, attachments and photo files) to the end of another project's task
    /// list. Its Today link id is kept, so a copy in Today keeps syncing. Mirrors projkit `move_task_to`.
    public static func moveTaskTo(_ ws: Workspace, _ p: Project, index: Int, to dest: Project) throws {
        guard ![p, dest].contains(where: { ws.isToday($0) || ws.isArchive($0) }) else {
            throw OpError("tasks can only be moved between projects")
        }
        guard p.url.standardizedFileURL != dest.url.standardizedFileURL else {
            throw OpError("the task is already in that project")
        }
        let q = try fresh(ws, p)
        let d = try fresh(ws, dest)
        let block = try ReadmeBody.taskBlock(q.document!.body, index: index)
        let photos = q.tasks.indices.contains(index) ? q.tasks[index].photos : []
        try checkPhotoMove(ws, photos, from: q.url, to: d.url)
        try editBody(ws, d) { ReadmeBody.addTaskBlock($0, block) }     // written before the original is removed
        try movePhotos(ws, photos, from: q.url, to: d.url)
        try editBody(ws, q) { try ReadmeBody.removeTask($0, index: index) }
    }

    /// After a project rename, points its archived tasks at the new name.
    static func retargetArchived(_ ws: Workspace, from old: String, to new: String) throws {
        guard let a = ws.archive(), a.document != nil else { return }
        let hits = a.tasks.filter { $0.archivedFrom?.lowercased() == old.lowercased() }
        guard !hits.isEmpty else { return }
        try editBody(ws, a) { body in
            try hits.reduce(body) { try ReadmeBody.setTaskArchived($0, index: $1.index, date: $1.archived, from: new) }
        }
    }

    public static func editTask(_ ws: Workspace, _ p: Project, index: Int, text: String) throws {
        try editBody(ws, p) { try ReadmeBody.editTask($0, index: index, text: text) }
    }

    public static func moveTask(_ ws: Workspace, _ p: Project, from: Int, to: Int) throws {
        try editBody(ws, p) { try ReadmeBody.moveTask($0, index: from, to: to) }
    }

    /// Deletes a task with its notes and attachment links; its photo files are deleted too.
    public static func removeTask(_ ws: Workspace, _ p: Project, index: Int) throws {
        let q = try fresh(ws, p)
        let photos = q.tasks.indices.contains(index) ? q.tasks[index].photos.map(\.path) : []
        try editBody(ws, q) { try ReadmeBody.removeTask($0, index: index) }
        try deleteUnreferencedPhotos(ws, q, photos)
    }

    // MARK: photos (files in the project's Photos/ folder; Proj creates them, so removing deletes the file)

    public static let photoExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp"]

    /// "2026-11-06 101230-k3x9.jpg": sortable, and unique enough to move between projects and the Archive.
    public static func newPhotoName(ext: String = "jpg", date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        let suffix = String((0..<4).map { _ in alphabet.randomElement()! })
        return "\(f.string(from: date))-\(suffix).\(ext.lowercased())"
    }

    /// Where a photo's file is (paths are relative to the project folder).
    public static func photoURL(_ p: Project, _ photo: ProjectPhoto) -> URL {
        p.url.appendingPathComponent(photoDirName).appendingPathComponent(photo.fileName)
    }

    /// Saves image data into the project's Photos/ folder and adds it to the project, or to task `task`.
    @discardableResult
    public static func addPhoto(_ ws: Workspace, _ p: Project, data: Data, ext: String = "jpg", note: String?,
                                task: Int? = nil) throws -> ProjectPhoto {
        let e = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard photoExtensions.contains(e) else { throw OpError("not a photo type Proj knows: \(ext)") }
        guard !data.isEmpty else { throw OpError("the photo is empty") }
        let q = try fresh(ws, p)
        if let task, !q.tasks.indices.contains(task) { throw OpError("no task #\(task + 1)") }
        let dir = q.url.appendingPathComponent(photoDirName)
        if !ws.fs.isDirectory(dir) { try ws.fs.createDirectory(dir) }
        let name = newPhotoName(ext: e)
        let path = "\(photoDirName)/\(name)"
        try ws.fs.writeData(data, to: dir.appendingPathComponent(name))
        do {
            try editBody(ws, q) { body in
                if let task { return try ReadmeBody.addTaskPhoto(body, task: task, note: note, path: path) }
                return try ReadmeBody.addPhoto(body, note: note, path: path)
            }
        } catch {
            try? ws.fs.removeItem(dir.appendingPathComponent(name))
            throw error
        }
        let r = ws.load(q.url)
        return (task.map { r.tasks[$0].photos } ?? r.photos).last!
    }

    public static func editPhotoNote(_ ws: Workspace, _ p: Project, index: Int, note: String?, task: Int? = nil) throws {
        try editBody(ws, p) { body in
            if let task { return try ReadmeBody.editTaskPhoto(body, task: task, index: index, note: note) }
            return try ReadmeBody.editPhoto(body, index: index, note: note)
        }
    }

    /// Removes a photo and deletes its file (unless another entry still shows it).
    public static func removePhoto(_ ws: Workspace, _ p: Project, index: Int, task: Int? = nil) throws {
        let q = try fresh(ws, p)
        let list = task.map { q.tasks.indices.contains($0) ? q.tasks[$0].photos : [] } ?? q.photos
        guard list.indices.contains(index) else { throw OpError("no photo #\(index + 1)") }
        try editBody(ws, q) { body in
            if let task { return try ReadmeBody.removeTaskPhoto(body, task: task, index: index) }
            return try ReadmeBody.removePhoto(body, index: index)
        }
        try deleteUnreferencedPhotos(ws, q, [list[index].path])
    }

    static func deleteUnreferencedPhotos(_ ws: Workspace, _ p: Project, _ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let keep = ReadmeBody.referencedPhotos(try fresh(ws, p).document!.body)
        for path in paths where !keep.contains(path) {
            let f = p.url.appendingPathComponent(path)
            if ws.fs.exists(f) { try ws.fs.removeItem(f) }
        }
    }

    static func checkPhotoMove(_ ws: Workspace, _ photos: [ProjectPhoto], from src: URL, to dst: URL) throws {
        for ph in photos where ws.fs.exists(dst.appendingPathComponent(ph.path)) && ws.fs.exists(src.appendingPathComponent(ph.path)) {
            throw OpError("\(dst.lastPathComponent)/\(ph.path) already exists")
        }
    }

    /// Moves a task's photo files along with the task (to or from the Archive).
    static func movePhotos(_ ws: Workspace, _ photos: [ProjectPhoto], from src: URL, to dst: URL) throws {
        guard !photos.isEmpty else { return }
        let dir = dst.appendingPathComponent(photoDirName)
        if !ws.fs.isDirectory(dir) { try ws.fs.createDirectory(dir) }
        for ph in photos {
            let s = src.appendingPathComponent(ph.path)
            if ws.fs.exists(s) { try ws.fs.move(s, to: dst.appendingPathComponent(ph.path)) }
        }
    }

    // MARK: project files

    public static func addFile(_ ws: Workspace, _ p: Project, target: String, name: String?) throws {
        try editBody(ws, p) { try ReadmeBody.addFile($0, name: name, target: target) }
    }

    public static func editFile(_ ws: Workspace, _ p: Project, index: Int, name: String?, target: String?) throws {
        try editBody(ws, p) { try ReadmeBody.editFile($0, index: index, name: name, target: target) }
    }

    public static func removeFile(_ ws: Workspace, _ p: Project, index: Int) throws {
        try editBody(ws, p) { try ReadmeBody.removeFile($0, index: index) }
    }

    // MARK: task attachments (linked by path or URL, never copied)

    public static func addTaskFile(_ ws: Workspace, _ p: Project, task: Int, target: String, name: String?) throws {
        try editBody(ws, p) { try ReadmeBody.addTaskFile($0, task: task, name: name, target: target) }
    }

    public static func editTaskFile(_ ws: Workspace, _ p: Project, task: Int, index: Int, name: String?, target: String?) throws {
        try editBody(ws, p) { try ReadmeBody.editTaskFile($0, task: task, index: index, name: name, target: target) }
    }

    public static func removeTaskFile(_ ws: Workspace, _ p: Project, task: Int, index: Int) throws {
        try editBody(ws, p) { try ReadmeBody.removeTaskFile($0, task: task, index: index) }
    }

    // MARK: task notes

    public static func addTaskNote(_ ws: Workspace, _ p: Project, task: Int, text: String) throws {
        try editBody(ws, p) { try ReadmeBody.addTaskNote($0, task: task, text: text) }
    }

    public static func editTaskNote(_ ws: Workspace, _ p: Project, task: Int, index: Int, text: String) throws {
        try editBody(ws, p) { try ReadmeBody.editTaskNote($0, task: task, index: index, text: text) }
    }

    public static func removeTaskNote(_ ws: Workspace, _ p: Project, task: Int, index: Int) throws {
        try editBody(ws, p) { try ReadmeBody.removeTaskNote($0, task: task, index: index) }
    }

    /// Location of a "Documents/…" entry inside the user-picked Documents folder (nil for URLs
    /// or anything escaping it).
    public static func fileURL(_ f: ProjectFile, documentsRoot: URL?) -> URL? {
        guard !f.isURL, let root = documentsRoot?.standardizedFileURL,
              let t = try? ReadmeBody.checkFileTarget(f.target) else { return nil }
        let u = root.appendingPathComponent(String(t.dropFirst("Documents/".count))).standardizedFileURL
        return u.path.hasPrefix(root.path + "/") ? u : nil
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

    /// Moves goal `from` so it ends up at position `to` (both 0-based, in the list as it is now).
    public static func moveGoal(_ ws: Workspace, _ p: Project, from: Int, to: Int) throws {
        try editList(ws, p, "goals") { goals in
            guard goals.indices.contains(from) else { throw OpError("no goal #\(from + 1)") }
            guard goals.indices.contains(to) else { throw OpError("no goal #\(to + 1)") }
            goals.insert(goals.remove(at: from), at: to)
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

    /// Saves a newly scanned document (it has no other original) as
    /// <receipts>/<year>/<date> <description>.<ext> and references it.
    /// Existing files are never copied: use `addReceiptReference` for those.
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
        try appendReceipt(ws, p, path: rel, amount: amount, vendor: vendor, date: date)
        return rel
    }

    /// How an existing file is referenced as a receipt: relative to the receipts root when it lives
    /// there, otherwise "Documents/…" (same form as Project Files).
    public static func receiptReference(_ ws: Workspace, fileURL: URL, documentsRoot: URL?) throws -> String {
        func clean(_ u: URL) -> String {
            let p = u.standardizedFileURL.resolvingSymlinksInPath().path
            return p.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p
        }
        let path = clean(fileURL)
        if let root = ws.receiptsRoot.map(clean), path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return try ReadmeBody.normalizeFilePath(path, documentsRoot: documentsRoot.map { URL(fileURLWithPath: clean($0)) })
    }

    /// References an existing file as a receipt by its path. The file is the single source of
    /// truth: it is never copied or moved.
    public static func addReceiptReference(_ ws: Workspace, _ p: Project, path rel: String, amount: Double?,
                                           vendor: String?, date: String = ISODate.string()) throws {
        guard ISODate.isValid(date) else { throw OpError("bad date: \(date)") }
        if p.receipts.contains(where: { $0.path == rel }) { throw OpError("receipt already attached: \(rel)") }
        try appendReceipt(ws, p, path: rel, amount: amount, vendor: vendor, date: date)
    }

    static func appendReceipt(_ ws: Workspace, _ p: Project, path rel: String, amount: Double?,
                              vendor: String?, date: String) throws {
        let v = vendor?.trimmingCharacters(in: .whitespacesAndNewlines)
        try editList(ws, p, "receipts") {
            $0.append(.map(YAMLMap([("path", .string(rel)),
                                    ("amount", amount.map { .number($0) } ?? .null),
                                    ("vendor", v?.isEmpty == false ? .string(v!) : .null),
                                    ("date", .date(date))])))
        }
    }

    /// Detach a receipt (the file itself is not touched).
    public static func removeReceipt(_ ws: Workspace, _ p: Project, index: Int) throws {
        try editList(ws, p, "receipts") { r in
            guard r.indices.contains(index) else { throw OpError("no receipt #\(index + 1)") }
            r.remove(at: index)
        }
    }

    /// Location of a receipt: "Documents/…" inside the user-picked Documents folder, anything
    /// else inside the receipts root (nil if it would escape them).
    public static func receiptURL(_ ws: Workspace, _ r: Receipt, documentsRoot: URL? = nil) -> URL? {
        if r.path.hasPrefix("Documents/") {
            return fileURL(ProjectFile(index: r.index, name: r.fileName, target: r.path), documentsRoot: documentsRoot)
        }
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
