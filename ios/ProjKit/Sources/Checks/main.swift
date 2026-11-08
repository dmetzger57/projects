import Foundation
import ProjKitCore

// Minimal test runner (Swift Testing/XCTest need full Xcode; this works with the CLT).

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passed = 0

func check(_ cond: @autoclosure () -> Bool, _ msg: String, file: String = #fileID, line: Int = #line) {
    if cond() { passed += 1 } else { failures += 1; print("  ✗ \(msg)  (\(file):\(line))") }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #fileID, line: Int = #line) {
    if a == b { passed += 1 } else {
        failures += 1
        print("  ✗ \(msg)\n    got:      \(String(reflecting: a))\n    expected: \(String(reflecting: b))  (\(file):\(line))")
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    print("• \(name)")
    do { try body() } catch { failures += 1; print("  ✗ threw \(error)") }
}

let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../Fixtures").standardizedFileURL

func tempWorkspace() throws -> Workspace {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("projkit-\(UUID().uuidString)")
    let root = base.appendingPathComponent("Projects"), rec = base.appendingPathComponent("Receipts")
    for d in ["1 - Template/Documents", "1 - Template/Receipts", "2 - Closed", "House", "Personal"] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
    }
    try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
    try String(contentsOf: fixtures.appendingPathComponent("Template.md"), encoding: .utf8)
        .write(to: root.appendingPathComponent("1 - Template/README.md"), atomically: true, encoding: .utf8)
    return Workspace(root: root, receiptsRoot: rec)
}

// MARK: - mutate mode (for the Python cross-check)

let args = CommandLine.arguments
if args.count == 3, args[1] == "--dump-tasks" {
    let ws = Workspace(root: URL(fileURLWithPath: args[2]).deletingLastPathComponent(), receiptsRoot: nil)
    let p = ws.load(URL(fileURLWithPath: args[2]))
    for t in p.tasks { print(t.index, t.text, t.files.map(\.name)) }
    exit(0)
}

if args.count == 4, args[1] == "--mutate" {
    let ws = Workspace(root: URL(fileURLWithPath: args[2]), receiptsRoot: URL(fileURLWithPath: args[3]))
    do {
        // Its own project in the first real area (from the template), so the check doesn't depend on
        // which real projects exist or are open; the rest of the copied tree (Today, overview) is real.
        guard let area = ws.areas().first else { throw OpError("no areas to add a project to") }
        var photo = try Ops.newProject(ws, title: "Crosscheck Scanner", area: area)
        try Ops.addGoal(ws, photo, "Scan the slides")           // goal #1 (the template may have none)
        try Ops.setGoal(ws, photo, index: 0, done: true)
        try Ops.addGoal(ws, photo, "Buy a scanner: Epson FF-680W")
        try Ops.addNote(ws, photo, "Edited on iPhone\nsecond line")
        try Ops.addLink(ws, photo, url: "https://example.com/a?b=c#d", title: "Example: \"quoted\"")
        try Ops.setSection(ws, photo, "Description", "Consolidate **all** photos.\n\n- prints\n- slides")
        try Ops.addReceipt(ws, photo, data: Data("%PDF-1.4".utf8), fileExtension: "pdf",
                           description: "Epson scanner", amount: 649.99, vendor: "B&H", date: "2026-11-03")
        try Ops.addTask(ws, photo, "Order scanner")
        try Ops.addTask(ws, photo, "Pick storage")
        try Ops.addTask(ws, photo, "Temporary")
        try Ops.setTask(ws, photo, index: 1, done: true)        // done: settles at the bottom
        try Ops.editTask(ws, photo, index: 0, text: "Order Epson FF-680W")
        try Ops.setTaskReminder(ws, photo, index: 0, when: "2026-11-10T09:00")   // kept through the edits below
        try Ops.removeTask(ws, photo, index: 1)                 // "Temporary"
        try Ops.addTask(ws, photo, "Move me to the top")        // added above the done task
        try Ops.moveTask(ws, photo, from: 1, to: 0)
        try Ops.addTaskFile(ws, photo, task: 1, target: "Documents/Quotes/Epson quote.pdf", name: nil)
        try Ops.addTaskFile(ws, photo, task: 1, target: "https://epson.com/ff-680w", name: "Product page")
        try Ops.addTaskNote(ws, photo, task: 1, text: "Ask about the 3-year warranty")
        try Ops.addTaskNote(ws, photo, task: 1, text: "Check B&H price")
        try Ops.editTaskNote(ws, photo, task: 1, index: 1, text: "Check B&H and Adorama prices")
        try Ops.addTaskNote(ws, photo, task: 0, text: "Delete me")
        try Ops.removeTaskNote(ws, photo, task: 0, index: 0)
        // Today: copy two tasks, tick one in Today and untick it from the project (ends unchanged)
        try Ops.copyToToday(ws, ws.load(photo.url), index: 0)
        try Ops.copyToToday(ws, ws.load(photo.url), index: 2)       // already done: copied done
        // Today may hold real tasks (this runs on a copy of the real tree) and copies settle among
        // them, so find the task by its text rather than by position.
        func at(_ q: Project, _ text: String) throws -> Int {
            guard let i = q.tasks.firstIndex(where: { $0.text == text }) else { throw OpError("no task '\(text)'") }
            return i
        }
        try Ops.setTask(ws, ws.today()!, index: try at(ws.today()!, "Move me to the top"), done: true)
        guard ws.load(photo.url).tasks.last?.text == "Move me to the top" else {
            throw OpError("ticked from Today, but not settled last: \(ws.load(photo.url).tasks.map(\.text))")
        }
        try Ops.setTask(ws, ws.load(photo.url), index: try at(ws.load(photo.url), "Move me to the top"), done: false)
        guard ws.load(photo.url).tasks.map(\.text) == ["Order Epson FF-680W", "Move me to the top", "Pick storage"] else {
            throw OpError("unticked, but not above the done: \(ws.load(photo.url).tasks.map(\.text))")
        }
        try Ops.moveTask(ws, ws.load(photo.url), from: 1, to: 0)
        try Ops.addTask(ws, ws.today()!, "Call the bank")
        // Archive: a task with a note moves out (the rename below must follow it into the Archive)
        try Ops.addTask(ws, photo, "Archive me")                // above the done task
        try Ops.addTaskNote(ws, photo, task: 2, text: "kept with it")
        try Ops.archiveTask(ws, ws.load(photo.url), index: 2, date: "2026-11-04")
        try Ops.addFile(ws, photo, target: "Documents/Manuals/Epson FF-680W.pdf", name: "Scanner manual")
        try Ops.addFile(ws, photo, target: "https://docs.google.com/document/d/abc/edit?tab=t.0", name: nil)
        try Ops.editFile(ws, photo, index: 1, name: "Plan", target: nil)
        try Ops.setStatus(ws, photo, "blocked")
        try Ops.moveProject(ws, photo, to: 0)                 // overview: top of its area, area collapsed and first
        try Ops.setCollapsed(ws, areas: [ws.displayArea(photo)], true)
        try Ops.moveArea(ws, ws.displayArea(photo), to: 0)
        photo = try Ops.rename(ws, photo, to: "Crosscheck Photos")
        let p = try Ops.newProject(ws, title: "Crosscheck Swift Made", area: area)
        try Ops.addGoal(ws, p, "true")      // must stay a string, not a bool
        try Ops.addTask(ws, photo, "Move me across")           // moved to another project, with its note
        try Ops.addTaskNote(ws, photo, task: 2, text: "came along")
        try Ops.moveTaskTo(ws, ws.load(photo.url), index: 2, to: p)
        try Ops.close(ws, p)
        try Ops.addIdea(ws, "Idea from iPhone")
        photo = ws.load(photo.url)
        try Ops.addPhoto(ws, photo, data: Data([0xff, 0xd8, 0xff]), ext: "jpg", note: "Shelf [old] scanner")
        try Ops.addPhoto(ws, ws.load(photo.url), data: Data([0xff, 0xd8, 0xff]), ext: "jpg", note: "Quote", task: 1)
        print("mutations applied")
    } catch {
        print("error: \(error)")
        exit(1)
    }
    exit(0)
}

if args.count == 3, args[1] == "--setup" {
    let root = URL(fileURLWithPath: args[2])
    let ws = Workspace(root: root, receiptsRoot: root.appendingPathComponent(internalReceiptsDirName))
    do {
        try Ops.setUpWorkspace(ws, areas: ["Home", "Personal"], receiptsInside: true)
        let p = try Ops.newProject(ws, title: "Garden", area: "Home")
        try Ops.addGoal(ws, p, "Plant tomatoes")
        try Ops.addIdea(ws, "Greenhouse")
        print("setup applied")
    } catch {
        print("error: \(error)")
        exit(1)
    }
    exit(0)
}

// MARK: - tests

test("round-trip of every real README is byte-identical") {
    let files = try FileManager.default.contentsOfDirectory(atPath: fixtures.path).filter { $0.hasSuffix(".md") }
    check(files.count >= 5, "fixtures present")
    for f in files {
        let text = try String(contentsOf: fixtures.appendingPathComponent(f), encoding: .utf8)
        eq(ProjectDocument.parse(text).serialize(), text, f)
    }
}

test("parses typed fields from a migrated README") {
    let text = try String(contentsOf: fixtures.appendingPathComponent("Projects_Note_Taking_and_Archiving.md"), encoding: .utf8)
    let p = Project(url: URL(fileURLWithPath: "/x/Projects Note Taking and Archiving"), document: ProjectDocument.parse(text))
    eq(p.title, "Projects Note Taking and Archiving")
    eq(p.status, "active")
    eq(p.created, "2026-11-02")
    eq(p.goals.map(\.done), [true, true, false])
    eq(p.goalProgress.done, 2)
    check(p.section("Project Files")!.contains("  - Project description and notes"), "nested list kept")
    eq(p.notes.first?.date, "2026-11-02")
    check(p.notes[0].text.hasPrefix("- I will use iCloud"), "note text")
}

test("links with URLs parse") {
    let text = try String(contentsOf: fixtures.appendingPathComponent("Web-Check_Tool.md"), encoding: .utf8)
    let p = Project(url: URL(fileURLWithPath: "/x/Web-Check Tool"), document: ProjectDocument.parse(text))
    eq(p.links.count, 1)
    check(p.links[0].url.hasPrefix("https://www.makeuseof.com/"), "url")
}

test("only changed keys are re-rendered; comments elsewhere survive") {
    let src = """
    ---
    # leading comment
    title: X   # keep me
    status: active
    goals:
      - text: A
        done: false
    weird: |
      multi
      line
    tags: [a, "b c"]
    ---
    body

    """
    var doc = ProjectDocument.parse(src)
    check(!doc.frontMatter.isEditable("weird"), "block scalar is opaque")
    eq(doc.frontMatter["tags"], .list([.scalar("a", quoted: false), .scalar("b c", quoted: true)]))
    var goals = doc.frontMatter["goals"]!.list!
    var g = goals[0].map!
    g["done"] = .bool(true)
    goals[0] = .map(g)
    goals.append(.map(YAMLMap([("text", .string("yes")), ("done", .bool(false))])))
    doc.frontMatter.set("goals", .list(goals))
    let out = doc.serialize()
    check(out.contains("# leading comment\ntitle: X   # keep me\n"), "untouched lines verbatim")
    check(out.contains("goals:\n  - text: A\n    done: true\n  - text: \"yes\"\n    done: false\n"), "python-style render:\n\(out)")
    check(out.contains("weird: |\n  multi\n  line\n"), "opaque kept")
    eq(ProjectDocument.parse(out).frontMatter["goals"]!.list![1].map!["text"], .scalar("yes", quoted: true))
}

test("string quoting rules") {
    for s in ["true", "123", "1.5", "2026-11-03", "a: b", "#x", "- x", "", " x", "null", "x #y", "[a]"] {
        eq(YAMLValue.string(s), .scalar(s, quoted: true), "should quote \(s)")
    }
    for s in ["Web-Check Tool", "Buy shingles", "https://x.com/a?b=c", "Define storage (video?)", "‘quoted’ word"] {
        eq(YAMLValue.string(s), .scalar(s, quoted: false), "plain \(s)")
    }
    var fm = FrontMatter()
    fm.set("t", .string("\"hi\" she said\\now"))     // leading quote forces quoting
    eq(fm.serialize(), "t: \"\\\"hi\\\" she said\\\\now\"\n")
    eq(FrontMatter.parse(fm.serialize())["t"], .scalar("\"hi\" she said\\now", quoted: true))
    fm.set("t", .string("say \"hi\" now"))              // inner quotes are fine plain
    eq(FrontMatter.parse(fm.serialize())["t"], .scalar("say \"hi\" now", quoted: false))
    eq(FrontMatter.parse("t: 'it''s'\n")["t"], .scalar("it's", quoted: true))
    eq(YAMLValue.number(150).string, "150.0")
    eq(YAMLValue.number(412.5).string, "412.5")
}

test("notes: same day appends, new day adds heading, creates section") {
    var b = "\n## Description\nx\n\n## Notes\n### 2026-11-02\n- one\n"
    b = ReadmeBody.addNote(b, text: "two", date: "2026-11-02")
    b = ReadmeBody.addNote(b, text: "multi\nline", date: "2026-11-03")
    eq(b, "\n## Description\nx\n\n## Notes\n### 2026-11-02\n- one\n- two\n\n### 2026-11-03\n- multi\n  line\n")
    eq(ReadmeBody.addNote("\n## Description\nhi\n", text: "n", date: "2026-01-01"),
       "\n## Description\nhi\n\n## Notes\n### 2026-01-01\n- n\n")
}

test("sections: replace, create before Notes, reject headings") {
    let b = "\n## Description\nold\n\n## Project Files\n\n## Notes\n### 2026-11-02\n- n\n"
    let r = try ReadmeBody.setSection(b, heading: "Description", text: "new\n\n- a")
    eq(ReadmeBody.section(r, "Description"), "new\n\n- a")
    eq(ReadmeBody.notes(r).count, 1)
    let c = try ReadmeBody.setSection("\n## Notes\n### 2026-11-02\n- n\n", heading: "Project Files", text: "files")
    eq(c, "\n## Project Files\nfiles\n\n## Notes\n### 2026-11-02\n- n\n")
    var threw = false
    do { _ = try ReadmeBody.setSection(b, heading: "Description", text: "## evil") } catch { threw = true }
    check(threw, "rejects headings")
}

test("tasks: identical output to projkit/ops.py (same literals as tests/test_tasks.py)") {
    let body = "\n## Description\nx\n\n## Project Files\n\n## Notes\n### 2026-11-02\n- n\n"
    var b = try ReadmeBody.addTask(body, text: "Order scanner")
    eq(b, "\n## Description\nx\n\n## Project Files\n\n## Tasks\n- [ ] Order scanner\n\n## Notes\n### 2026-11-02\n- n\n")
    b = try ReadmeBody.addTask(b, text: "Pick storage\nlocation  ")
    check(b.contains("## Tasks\n- [ ] Order scanner\n- [ ] Pick storage location\n\n## Notes"), "append")
    eq(try ReadmeBody.addTask("\n## Description\nx\n", text: "a"), "\n## Description\nx\n\n## Tasks\n- [ ] a\n")
    eq(try ReadmeBody.addTask("\n## Tasks\nThings to do:\n\n## Notes\n", text: "a"),
       "\n## Tasks\nThings to do:\n- [ ] a\n\n## Notes\n")

    var c = "\n## Tasks\n- [ ] one\n  indented detail\n- [X] two\n* [ ] not a task\n\n## Notes\n"
    eq(ReadmeBody.tasks(c).map(\.text), ["one", "two"])
    eq(ReadmeBody.tasks(c).map(\.done), [false, true])
    c = try ReadmeBody.setTask(c, index: 0, done: true)
    c = try ReadmeBody.setTask(c, index: 1, done: false)
    eq(c, "\n## Tasks\n- [x] one\n  indented detail\n- [ ] two\n* [ ] not a task\n\n## Notes\n")
    c = try ReadmeBody.editTask(c, index: 0, text: "one, renamed")
    check(c.contains("- [x] one, renamed\n"), "edit keeps checkbox")
    c = try ReadmeBody.removeTask(c, index: 1)
    eq(c, "\n## Tasks\n- [x] one, renamed\n  indented detail\n* [ ] not a task\n\n## Notes\n")
    var threw = 0
    do { _ = try ReadmeBody.removeTask(c, index: 5) } catch { threw += 1 }
    do { _ = try ReadmeBody.editTask(c, index: 0, text: "   ") } catch { threw += 1 }
    eq(threw, 2, "bad index / empty text rejected")
}

test("task attachments: identical output to projkit/ops.py (same literals as tests/test_tasks.py)") {
    let att = "\n## Tasks\n- [ ] A\n  note\n- [x] B\n\n## Notes\n"
    var b = try ReadmeBody.addTaskFile(att, task: 0, name: "Quote", target: "Documents/Q/x y.pdf")
    b = try ReadmeBody.addTaskFile(b, task: 0, name: nil, target: "https://epson.com/ff")
    eq(b, "\n## Tasks\n- [ ] A\n  note\n  - [Quote](<Documents/Q/x y.pdf>)\n  - [epson.com](https://epson.com/ff)\n- [x] B\n\n## Notes\n")
    let t = ReadmeBody.tasks(b)
    eq(t[0].files.map(\.name), ["Quote", "epson.com"])
    eq(t[0].files.map(\.target), ["Documents/Q/x y.pdf", "https://epson.com/ff"])
    eq(t[0].files.map(\.isURL), [false, true])
    eq(t[1].files.count, 0)
    b = try ReadmeBody.addTask(b, text: "C")
    check(b.hasSuffix("- [x] B\n- [ ] C\n\n## Notes\n"), "task appended after last block")
    b = try ReadmeBody.addTaskFile(b, task: 1, name: "Manual", target: "Documents/M.pdf")
    check(b.contains("- [x] B\n  - [Manual](<Documents/M.pdf>)\n- [ ] C\n"), "attach to B")
    b = try ReadmeBody.editTaskFile(b, task: 0, index: 1, name: "Epson [site]", target: nil)
    check(b.contains("  - [Epson (site)](https://epson.com/ff)\n"), "edit name")
    b = try ReadmeBody.removeTaskFile(b, task: 0, index: 0)
    check(b.hasPrefix("\n## Tasks\n- [ ] A\n  note\n  - [Epson (site)](https://epson.com/ff)\n- [x] B\n"), "remove")
    var threw = 0
    do { _ = try ReadmeBody.addTaskFile(b, task: 9, name: nil, target: "https://x.org") } catch { threw += 1 }
    do { _ = try ReadmeBody.removeTaskFile(b, task: 2, index: 0) } catch { threw += 1 }
    do { _ = try ReadmeBody.addTaskFile(b, task: 0, name: nil, target: "Documents/../etc/passwd") } catch { threw += 1 }
    eq(threw, 3)
    eq(try ReadmeBody.addTask("\n## Tasks\n- [ ] A\n  - [x](https://x.org)\n\n## Notes\n", text: "B"),
       "\n## Tasks\n- [ ] A\n  - [x](https://x.org)\n- [ ] B\n\n## Notes\n")
    let mv = "\n## Tasks\n- [ ] A\n  - [a](https://a.org)\n- [ ] B\n  - [b](<Documents/b.pdf>)\n"
    eq(try ReadmeBody.moveTask(mv, index: 1, to: 0), "\n## Tasks\n- [ ] B\n  - [b](<Documents/b.pdf>)\n- [ ] A\n  - [a](https://a.org)\n")
    eq(try ReadmeBody.removeTask(mv, index: 0), "\n## Tasks\n- [ ] B\n  - [b](<Documents/b.pdf>)\n")
}

test("task notes: identical output to projkit/ops.py (same literals as tests/test_tasks.py)") {
    let note = "\n## Tasks\n- [ ] A\n  - [Q](<Documents/q.pdf>)\n- [x] B\n  hand-written\n\n## Notes\n"
    var b = try ReadmeBody.addTaskNote(note, task: 0, text: "Call\nfirst")
    b = try ReadmeBody.addTaskNote(b, task: 0, text: "  Then email  ")
    eq(b, "\n## Tasks\n- [ ] A\n  - Call first\n  - Then email\n  - [Q](<Documents/q.pdf>)\n- [x] B\n  hand-written\n\n## Notes\n")
    let t = ReadmeBody.tasks(b)
    eq(t[0].notes.map(\.text), ["Call first", "Then email"])
    eq(t[0].files.map(\.name), ["Q"])
    eq(t[1].notes.map(\.text), ["hand-written"])
    b = try ReadmeBody.addTaskNote(b, task: 1, text: "Second")
    check(b.contains("- [x] B\n  hand-written\n  - Second\n\n## Notes\n"), "note after hand-written note")
    b = try ReadmeBody.editTaskNote(b, task: 1, index: 0, text: "Edited *note*")
    check(b.contains("- [x] B\n  - Edited *note*\n  - Second\n"), "edit note")
    b = try ReadmeBody.removeTaskNote(b, task: 0, index: 0)
    check(b.hasPrefix("\n## Tasks\n- [ ] A\n  - Then email\n  - [Q](<Documents/q.pdf>)\n- [x] B\n"), "remove note")
    let moved = try ReadmeBody.moveTask(b, index: 1, to: 0)
    check(moved.hasPrefix("\n## Tasks\n- [x] B\n  - Edited *note*\n  - Second\n- [ ] A\n"), "move carries notes")
    eq(try ReadmeBody.removeTask(b, index: 1), "\n## Tasks\n- [ ] A\n  - Then email\n  - [Q](<Documents/q.pdf>)\n\n## Notes\n")
    var threw = 0
    do { _ = try ReadmeBody.addTaskNote(b, task: 9, text: "x") } catch { threw += 1 }
    do { _ = try ReadmeBody.addTaskNote(b, task: 0, text: " \n ") } catch { threw += 1 }
    do { _ = try ReadmeBody.editTaskNote(b, task: 0, index: 5, text: "x") } catch { threw += 1 }
    do { _ = try ReadmeBody.removeTaskNote(b, task: 1, index: 2) } catch { threw += 1 }
    do { _ = try ReadmeBody.addTaskNote(b, task: 0, text: "[link](https://x.org)") } catch { threw += 1 }
    eq(threw, 5, "bad task / note / empty / bare link rejected")
}

test("today links: identical output to projkit (same literals as tests/test_today.py)") {
    let link = "\n## Tasks\n- [ ] Get quotes <!-- task:ab12cd34 -->\n- [x] Hire roofer\n\n## Notes\n"
    eq(ReadmeBody.splitTaskText("Get quotes <!-- task:ab12cd34 -->").0, "Get quotes")
    eq(ReadmeBody.splitTaskText("Get quotes <!-- task:ab12cd34 -->").1, "ab12cd34")
    eq(ReadmeBody.splitTaskText("Plain").1, nil)
    let t = ReadmeBody.tasks(link)
    eq(t.map(\.text), ["Get quotes", "Hire roofer"])
    eq(t.map(\.linkID), ["ab12cd34", nil])
    var b = try ReadmeBody.editTask(link, index: 0, text: "Get 3 quotes")
    eq(b, "\n## Tasks\n- [ ] Get 3 quotes <!-- task:ab12cd34 -->\n- [x] Hire roofer\n\n## Notes\n")
    b = try ReadmeBody.setTask(b, index: 0, done: true)
    check(b.hasPrefix("\n## Tasks\n- [x] Get 3 quotes <!-- task:ab12cd34 -->\n"), "tick keeps id")
    b = try ReadmeBody.setTaskID(b, index: 1, id: "zz99yy88")
    check(b.contains("- [x] Hire roofer <!-- task:zz99yy88 -->\n"), "set id")
    b = try ReadmeBody.addTask(b, text: "Call bank", linkID: "qq77ww66")
    check(b.hasSuffix("- [x] Hire roofer <!-- task:zz99yy88 -->\n- [ ] Call bank <!-- task:qq77ww66 -->\n\n## Notes\n"), "add with id")
    eq(Ops.newTaskID().count, 8)
}

test("today: copy, two-way done sync, clear") {
    let ws = try tempWorkspace()
    let p = try Ops.newProject(ws, title: "Roof Repair", area: "House")
    try Ops.addTask(ws, p, "Get quotes")
    try Ops.addTask(ws, p, "Hire roofer")
    eq(ws.today() == nil, true)
    eq(try Ops.copyToToday(ws, p, index: 0), true)
    eq(try Ops.copyToToday(ws, ws.load(p.url), index: 0), false, "no duplicates")
    let id = ws.load(p.url).tasks[0].linkID
    check(id != nil && ws.today()!.tasks[0].linkID == id, "shared id")
    try Ops.setTask(ws, ws.today()!, index: 0, done: true)
    eq(ws.load(p.url).tasks.map { "\($0.text) \($0.done)" }, ["Hire roofer false", "Get quotes true"],
       "done in Today ticks the project task, which moves below the open ones")
    try Ops.setTask(ws, ws.load(p.url), index: 1, done: false)
    eq(ws.today()!.tasks[0].done, false, "undone in project unticks Today")
    eq(ws.load(p.url).tasks.map(\.text), ["Hire roofer", "Get quotes"])
    try Ops.setTask(ws, ws.load(p.url), index: 0, done: true)
    eq(ws.today()!.tasks.map(\.done), [false], "unlinked task leaves Today alone")
    try Ops.addTask(ws, ws.today()!, "Call bank")
    try Ops.setTask(ws, ws.today()!, index: 0, done: true)
    eq(try Ops.clearTodayDone(ws), 1)
    eq(ws.today()!.tasks.map(\.text), ["Call bank"])
    eq(ws.load(p.url).tasks.map { "\($0.text) \($0.done)" }, ["Hire roofer true", "Get quotes true"], "original kept")
    check(!ws.areas().contains(todayDirName) && !ws.projects().contains { ws.isToday($0) }, "Today is not an area project")
    var threw = false
    do { try Ops.copyToToday(ws, ws.today()!, index: 0) } catch { threw = true }
    check(threw, "can't copy Today into Today")
}

test("tasks: done tasks settle at the bottom (same steps as tests/test_today.py)") {
    let ws = try tempWorkspace()
    let p = try Ops.newProject(ws, title: "Garden", area: "House")
    for t in ["Dig", "Plant", "Water"] { try Ops.addTask(ws, ws.load(p.url), t) }
    let texts = { ws.load(p.url).tasks.map { "\($0.text) \($0.done)" } }
    try Ops.setTask(ws, ws.load(p.url), index: 0, done: true)
    eq(texts(), ["Plant false", "Water false", "Dig true"], "ticked: to the bottom")
    try Ops.setTask(ws, ws.load(p.url), index: 0, done: true)
    eq(texts(), ["Water false", "Dig true", "Plant true"], "the latest done goes last")
    try Ops.addTask(ws, ws.load(p.url), "Weed")
    eq(texts(), ["Water false", "Weed false", "Dig true", "Plant true"], "new tasks go above the done ones")
    try Ops.setTask(ws, ws.load(p.url), index: 3, done: false)
    eq(texts(), ["Water false", "Weed false", "Plant false", "Dig true"], "unticked: just above the done ones")
}

test("status: all tasks done → completed-on-hold (same steps as tests/test_today.py)") {
    let ws = try tempWorkspace()
    let p = try Ops.newProject(ws, title: "Garden", area: "House")
    for t in ["Dig", "Plant"] { try Ops.addTask(ws, ws.load(p.url), t) }
    try Ops.setTask(ws, ws.load(p.url), index: 0, done: true)
    eq(ws.load(p.url).status, "active", "one still open")
    try Ops.copyToToday(ws, ws.load(p.url), index: 0)
    try Ops.setTask(ws, ws.today()!, index: 0, done: true)
    eq(ws.load(p.url).status, "completed-on-hold", "the last one, ticked from Today")
    check(ws.today()!.document!.frontMatter["status"]?.string != "completed-on-hold", "Today itself is never completed")
    try Ops.setTask(ws, ws.load(p.url), index: 0, done: false)
    eq(ws.load(p.url).status, "completed-on-hold", "unticking leaves the status alone")
    try Ops.setStatus(ws, ws.load(p.url), "active")
    try Ops.setTask(ws, ws.load(p.url), index: 0, done: true)
    eq(ws.load(p.url).status, "completed-on-hold", "ticking again sets it again")
    eq(statusLabel("completed-on-hold"), "Completed – On Hold")
    eq(projectStatuses.map(statusLabel), ["Idea", "Backlog", "Active", "Blocked", "On Hold",
                                          "Completed – On Hold", "Closed"], "same labels as tests/test_today.py")
    let q = try Ops.newProject(ws, title: "Shed", area: "House")
    try Ops.addTask(ws, ws.load(q.url), "Paint")
    let c = try Ops.close(ws, ws.load(q.url))
    try Ops.setTask(ws, ws.load(c.url), index: 0, done: true)
    eq(ws.load(c.url).status, "closed", "closed projects stay closed")
}

test("all open tasks: by project in overview order, copy a selection to Today (same steps as tests/test_open_tasks.py)") {
    let ws = try tempWorkspace()
    try FileManager.default.createDirectory(at: ws.root.appendingPathComponent("House"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: ws.root.appendingPathComponent("Garden"), withIntermediateDirectories: true)
    let roof = try Ops.newProject(ws, title: "Roof", area: "House")
    for t in ["Get quotes", "Hire roofer", "Buy shingles"] { try Ops.addTask(ws, roof, t) }
    try Ops.setTask(ws, roof, index: 1, done: true)
    let fence = try Ops.newProject(ws, title: "Fence", area: "Garden")
    try Ops.addTask(ws, fence, "Paint fence")
    try Ops.setTask(ws, fence, index: 0, done: true)                 // nothing open: left out
    let shed = try Ops.newProject(ws, title: "Shed", area: "Garden")
    try Ops.addTask(ws, shed, "Fix shed door")
    let old = try Ops.newProject(ws, title: "Old Porch", area: "House")
    try Ops.addTask(ws, old, "Never mind")
    _ = try Ops.close(ws, old)                                       // closed: left out
    try Ops.moveArea(ws, "House", to: 0)                             // House first on the overview
    func shape() -> [String] {
        Ops.openTasks(ws).map { g in "\(g.area)/\(g.project.title): " + g.tasks.map { "\($0.index) \($0.text)" }.joined(separator: ", ") }
    }
    eq(shape(), ["House/Roof: 0 Get quotes, 1 Buy shingles", "Garden/Shed: 0 Fix shed door"])
    var g = Ops.openTasks(ws)
    eq(try Ops.copyManyToToday(ws, [(g[0].project, 1), (g[1].project, 0)]), 2)
    eq(ws.today()!.tasks.map(\.text), ["Buy shingles", "Fix shed door"])
    g = Ops.openTasks(ws)
    eq(try Ops.copyManyToToday(ws, [(g[0].project, 1), (g[0].project, 0)]), 1)   // one already there
    eq(ws.today()!.tasks.map(\.text), ["Buy shingles", "Fix shed door", "Get quotes"])
    try Ops.setTask(ws, ws.today()!, index: 1, done: true)          // ticked in Today: no longer open in Shed
    eq(shape(), ["House/Roof: 0 Get quotes, 1 Buy shingles"])
}

test("reminder marker: identical output to projkit (same literals as tests/test_reminders.py)") {
    let body = "\n## Tasks\n- [ ] Call plumber <!-- task:ab12cd34 -->\n  - Ask about warranty\n- [x] Order boards\n"
    let sr = ReadmeBody.splitReminder("Call <!-- reminder:2026-11-10T09:00 -->")
    eq([sr.0, sr.1 ?? ""], ["Call", "2026-11-10T09:00"])
    eq(ReadmeBody.splitReminder("Plain").1, nil)
    var b = try ReadmeBody.setTaskReminder(body, index: 0, when: "2026-11-10T09:00")
    eq(b, "\n## Tasks\n- [ ] Call plumber <!-- reminder:2026-11-10T09:00 --> <!-- task:ab12cd34 -->\n"
        + "  - Ask about warranty\n- [x] Order boards\n")
    let t = ReadmeBody.tasks(b)
    eq(t.map(\.text), ["Call plumber", "Order boards"])
    eq(t.map(\.reminder), ["2026-11-10T09:00", nil])
    eq(t.map(\.linkID), ["ab12cd34", nil])
    b = try ReadmeBody.editTask(b, index: 0, text: "Call the plumber")
    check(b.hasPrefix("\n## Tasks\n- [ ] Call the plumber <!-- reminder:2026-11-10T09:00 --> <!-- task:ab12cd34 -->\n"), "edit keeps reminder and id")
    b = try ReadmeBody.setTaskReminder(b, index: 0, when: "2026-11-12T14:30")
    check(b.contains("- [ ] Call the plumber <!-- reminder:2026-11-12T14:30 --> <!-- task:ab12cd34 -->\n"), "reschedule replaces")
    b = try ReadmeBody.setTaskArchived(b, index: 0, date: "2026-11-13", from: "House")
    check(b.contains("- [ ] Call the plumber <!-- reminder:2026-11-12T14:30 --> <!-- archived:2026-11-13 from:House -->"
        + " <!-- task:ab12cd34 -->\n"), "archive marker goes after it")
    eq(ReadmeBody.tasks(b)[0].reminder, "2026-11-12T14:30")
    b = try ReadmeBody.setTaskArchived(b, index: 0, date: nil, from: nil)
    b = try ReadmeBody.setTaskReminder(b, index: 0, when: nil)
    check(b.hasPrefix("\n## Tasks\n- [ ] Call the plumber <!-- task:ab12cd34 -->\n  - Ask about warranty\n"), "clear keeps id")
    var threw = false
    do { _ = try ReadmeBody.setTaskReminder(body, index: 0, when: "tomorrow") } catch { threw = true }
    check(threw, "refuses a malformed time")
}

test("archive marker: identical output to projkit (same literals as tests/test_archive.py)") {
    let arch = "\n## Tasks\n- [x] Get quotes <!-- archived:2026-11-05 from:Roof Repair --> <!-- task:ab12cd34 -->\n"
        + "  - Ask about warranty\n- [ ] Order boards <!-- archived:2026-10-01 from:Raised Beds -->\n"
    let sa = ReadmeBody.splitArchived("Get quotes <!-- archived:2026-11-05 from:Roof Repair -->")
    eq([sa.0, sa.1 ?? "", sa.2 ?? ""], ["Get quotes", "2026-11-05", "Roof Repair"])
    eq(ReadmeBody.splitArchived("Plain").1, nil)
    let t = ReadmeBody.tasks(arch)
    eq(t.map(\.text), ["Get quotes", "Order boards"])
    eq(t.map(\.archived), ["2026-11-05", "2026-10-01"])
    eq(t.map(\.archivedFrom), ["Roof Repair", "Raised Beds"])
    eq(t.map(\.linkID), ["ab12cd34", nil])
    var b = try ReadmeBody.editTask(arch, index: 0, text: "Get 3 quotes")
    check(b.hasPrefix("\n## Tasks\n- [x] Get 3 quotes <!-- archived:2026-11-05 from:Roof Repair --> <!-- task:ab12cd34 -->\n"), "edit keeps marker and id")
    b = try ReadmeBody.setTaskArchived(b, index: 1, date: "2026-10-01", from: "Garden Beds")
    check(b.contains("- [ ] Order boards <!-- archived:2026-10-01 from:Garden Beds -->\n"), "retarget")
    b = try ReadmeBody.setTaskArchived(b, index: 0, date: nil, from: nil)
    check(b.hasPrefix("\n## Tasks\n- [x] Get 3 quotes <!-- task:ab12cd34 -->\n  - Ask about warranty\n"), "clear keeps id")
    eq(try ReadmeBody.taskBlock(arch, index: 0),
       ["- [x] Get quotes <!-- archived:2026-11-05 from:Roof Repair --> <!-- task:ab12cd34 -->", "  - Ask about warranty"])
    eq(ReadmeBody.addTaskBlock("\n## Tasks\n- [ ] A\n\n## Notes\n", ["- [ ] B", "  - note"]),
       "\n## Tasks\n- [ ] A\n- [ ] B\n  - note\n\n## Notes\n")
    eq(ReadmeBody.addTaskBlock("\n## Notes\n", ["- [ ] B", "  - n"]), "\n## Tasks\n- [ ] B\n  - n\n\n## Notes\n")
    var threw = false
    do { _ = try ReadmeBody.setTaskArchived(arch, index: 0, date: "2026-11-05", from: "Bad --> name") } catch { threw = true }
    check(threw, "refuses a name that would end the comment")

    let items = ReadmeBody.tasks(arch + "- [ ] Apples <!-- archived:2026-11-05 from:raised beds -->\n")
    eq(Ops.filterArchived(items).map(\.text), ["Apples", "Get quotes", "Order boards"])
    eq(Ops.filterArchived(items, sort: .oldest).map(\.text), ["Order boards", "Get quotes", "Apples"])
    eq(Ops.filterArchived(items, sort: .name).map(\.text), ["Apples", "Get quotes", "Order boards"])
    eq(Ops.filterArchived(items, sort: .project).map(\.text), ["Apples", "Order boards", "Get quotes"])
    eq(Ops.filterArchived(items, project: "Raised Beds").map(\.text), ["Apples", "Order boards"])
    eq(Ops.filterArchived(items, since: "2026-11-01").map(\.text), ["Apples", "Get quotes"])
}

test("archive: archive, Today sync, rename, restore") {
    let ws = try tempWorkspace()
    var p = try Ops.newProject(ws, title: "Roof", area: "House")
    try Ops.addTask(ws, p, "Get quotes")
    try Ops.addTask(ws, p, "Hire roofer")
    try Ops.addTaskNote(ws, p, task: 0, text: "ask about warranty")
    try Ops.copyToToday(ws, ws.load(p.url), index: 0)
    let id = ws.load(p.url).tasks[0].linkID
    eq(ws.archive() == nil, true)
    try Ops.archiveTask(ws, ws.load(p.url), index: 0, date: "2026-11-05")
    let a = ws.archive()!.tasks[0]
    eq([a.text, a.archivedFrom ?? "", a.archived ?? ""], ["Get quotes", "Roof", "2026-11-05"])
    eq(a.notes.map(\.text), ["ask about warranty"])
    eq(a.linkID, id, "link id kept")
    eq(ws.load(p.url).tasks.map(\.text), ["Hire roofer"])
    eq(Ops.archiveProjects(ws.archive()), ["Roof"])
    var threw = 0
    do { try Ops.archiveTask(ws, ws.today()!, index: 0) } catch { threw += 1 }
    do { try Ops.archiveTask(ws, ws.archive()!, index: 0) } catch { threw += 1 }
    eq(threw, 2, "Today and Archive tasks can't be archived")
    try Ops.setTask(ws, ws.today()!, index: 0, done: true)
    eq(ws.archive()!.tasks[0].done, true, "Today copy still syncs")
    p = try Ops.rename(ws, ws.load(p.url), to: "Roof Repair")
    eq(ws.archive()!.tasks[0].archivedFrom, "Roof Repair", "rename follows")
    let q = try Ops.restoreTask(ws, index: 0)
    eq(q.folderName, "Roof Repair")
    eq(ws.load(p.url).tasks.map(\.text), ["Hire roofer", "Get quotes"])
    eq(ws.load(p.url).tasks[1].archived, nil)
    eq(ws.load(p.url).tasks[1].notes.map(\.text), ["ask about warranty"])
    eq(ws.archive()!.tasks.count, 0)
    try Ops.archiveTask(ws, ws.load(p.url), index: 0)
    try FileManager.default.removeItem(at: p.url)
    var gone = false
    do { try Ops.restoreTask(ws, index: 0) } catch { gone = true }
    check(gone, "can't restore into a missing project")
    check(!ws.areas().contains(archiveDirName) && !ws.projects().contains { ws.isArchive($0) }, "Archive is not an area project")
}

test("tasks: move and remove carry detail lines (same literals as tests/test_tasks.py)") {
    let m = "\n## Tasks\nIntro\n- [ ] a\n  a detail\n- [x] b\n- [ ] c\n  c1\n  c2\n\n## Notes\n"
    eq(try ReadmeBody.moveTask(m, index: 2, to: 0), "\n## Tasks\nIntro\n- [ ] c\n  c1\n  c2\n- [ ] a\n  a detail\n- [x] b\n\n## Notes\n")
    eq(try ReadmeBody.moveTask(m, index: 0, to: 2), "\n## Tasks\nIntro\n- [x] b\n- [ ] c\n  c1\n  c2\n- [ ] a\n  a detail\n\n## Notes\n")
    eq(try ReadmeBody.moveTask(m, index: 0, to: 1), "\n## Tasks\nIntro\n- [x] b\n- [ ] a\n  a detail\n- [ ] c\n  c1\n  c2\n\n## Notes\n")
    eq(try ReadmeBody.moveTask(m, index: 1, to: 1), m)
    eq(try ReadmeBody.moveTask(m, index: 1, to: 99), try ReadmeBody.moveTask(m, index: 1, to: 2))
    eq(try ReadmeBody.removeTask(m, index: 2), "\n## Tasks\nIntro\n- [ ] a\n  a detail\n- [x] b\n\n## Notes\n")
    eq(try ReadmeBody.removeTask(m, index: 0), "\n## Tasks\nIntro\n- [x] b\n- [ ] c\n  c1\n  c2\n\n## Notes\n")
    var threw = false
    do { _ = try ReadmeBody.moveTask(m, index: 3, to: 0) } catch { threw = true }
    check(threw, "bad index rejected")
}

test("project files: identical output to projkit/ops.py (same literals as tests/test_files.py)") {
    let body = "\n## Description\nx\n\n## Project Files\nSome notes about files.\n\n## Notes\n### 2026-11-02\n- n\n"
    let gdoc = "https://docs.google.com/document/d/1nkS9byPzwlKPAzqg9kLi-mdR3Z8tiebexaJj-OPYE3Q/edit?tab=t.0"
    var b = try ReadmeBody.addFile(body, name: "Scanner manual", target: "Documents/Manuals/Epson FF-680W.pdf")
    b = try ReadmeBody.addFile(b, name: "", target: gdoc)
    eq(b, "\n## Description\nx\n\n## Project Files\nSome notes about files.\n"
        + "- [Scanner manual](<Documents/Manuals/Epson FF-680W.pdf>)\n"
        + "- [docs.google.com](\(gdoc))\n\n## Notes\n### 2026-11-02\n- n\n")
    eq(ReadmeBody.files(b).map(\.name), ["Scanner manual", "docs.google.com"])
    eq(ReadmeBody.files(b).map(\.isURL), [false, true])
    eq(ReadmeBody.filesOtherText(b), "Some notes about files.")

    var c = try ReadmeBody.addFile("\n## Description\nx\n", name: nil, target: "Documents/Taxes/2025 [final].pdf")
    eq(c, "\n## Description\nx\n\n## Project Files\n- [2025 (final)](<Documents/Taxes/2025 [final].pdf>)\n")
    c = try ReadmeBody.addFile(c, name: "My (odd) [name]", target: "https://example.com/a b")
    check(c.hasSuffix("- [My (odd) (name)](<https://example.com/a b>)\n"), "angle brackets for spaces")
    eq(ReadmeBody.files(c)[1].target, "https://example.com/a b")

    var d = try ReadmeBody.addFile(body, name: "A", target: "Documents/a.pdf")
    d = try ReadmeBody.addFile(d, name: "B", target: "https://b.example")
    d = try ReadmeBody.editFile(d, index: 0, name: "Renamed", target: nil)
    d = try ReadmeBody.editFile(d, index: 1, name: nil, target: "https://c.example/x")
    check(d.contains("- [Renamed](<Documents/a.pdf>)\n- [B](https://c.example/x)\n"), "edit")
    d = try ReadmeBody.removeFile(d, index: 0)
    check(d.contains("Some notes about files.\n- [B](https://c.example/x)\n") && !d.contains("Renamed"), "remove")

    var rejected = 0
    for bad in ["/etc/passwd", "Downloads/x.pdf", "Documents/../x", "Documents/", "", "Documents/a<b"] {
        do { _ = try ReadmeBody.addFile(body, name: "x", target: bad) } catch { rejected += 1 }
    }
    eq(rejected, 6, "bad targets rejected")

    eq(try ReadmeBody.normalizeFilePath("~/Documents/a/b.pdf"), "Documents/a/b.pdf")
    eq(try ReadmeBody.normalizeFilePath("/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Documents/a.pdf"),
       "Documents/a.pdf")
    eq(try ReadmeBody.normalizeFilePath("/x/Docs/sub/f.txt", documentsRoot: URL(fileURLWithPath: "/x/Docs")),
       "Documents/sub/f.txt")
    eq(try ReadmeBody.normalizeFilePath("  'Documents/x y.txt' "), "Documents/x y.txt")
    eq(try ReadmeBody.normalizeFilePath(gdoc), gdoc)
    eq(ReadmeBody.defaultFileName(".bashrc"), ".bashrc")
    eq(ReadmeBody.defaultFileName("Documents/a.tar.gz"), "a.tar")
    eq(ReadmeBody.defaultFileName("https://www.example.com/x?y"), "example.com")
    let root = URL(fileURLWithPath: "/x/Docs")
    eq(Ops.fileURL(ProjectFile(index: 0, name: "", target: "Documents/a/b.pdf"), documentsRoot: root)?.path, "/x/Docs/a/b.pdf")
    eq(Ops.fileURL(ProjectFile(index: 0, name: "", target: gdoc), documentsRoot: root), nil)
}

test("statuses: backlog and blocked (same list as projkit/project.py STATUSES)") {
    eq(projectStatuses, ["idea", "backlog", "active", "blocked", "on-hold", "completed-on-hold", "closed"])
    let ws = try tempWorkspace()
    let p = try Ops.newProject(ws, title: "Roof Repair", area: "House", status: "backlog")
    eq(ws.load(p.url).status, "backlog")
    try Ops.setStatus(ws, p, "blocked")
    eq(ws.load(p.url).status, "blocked")
    var threw = 0
    do { try Ops.setStatus(ws, p, "stuck") } catch { threw += 1 }
    do { try Ops.setStatus(ws, p, "closed") } catch { threw += 1 }
    eq(threw, 2, "unknown status and closed rejected")
}

test("ops: new project, goals, close/reopen, rename, uniqueness") {
    let ws = try tempWorkspace()
    var p = try Ops.newProject(ws, title: "Roof Repair", area: "House")
    eq(p.goals.count, 0)
    check(FileManager.default.fileExists(atPath: p.url.appendingPathComponent("Receipts").path), "Receipts dir")
    eq(p.notes.last?.text, "- Project created")
    check(!(p.document!.body.contains("Initial template format")), "template notes dropped")
    try Ops.addGoal(ws, p, "Get quotes")
    try Ops.setGoal(ws, p, index: 0, done: true)
    p = ws.load(p.url)
    eq(p.goalProgress.done, 1)
    check(p.goals[0].doneOn != nil, "done_on set")
    try Ops.setGoal(ws, p, index: 0, done: false)
    eq(ws.load(p.url).goals[0].doneOn, nil)
    try Ops.addGoal(ws, p, "Pick a roofer")
    try Ops.addGoal(ws, p, "Schedule the work")
    try Ops.moveGoal(ws, ws.load(p.url), from: 2, to: 0)
    eq(ws.load(p.url).goals.map(\.text), ["Schedule the work", "Get quotes", "Pick a roofer"])
    try Ops.moveGoal(ws, ws.load(p.url), from: 0, to: 2)
    eq(ws.load(p.url).goals.map(\.text), ["Get quotes", "Pick a roofer", "Schedule the work"])
    for i in [2, 1] { try Ops.removeGoal(ws, ws.load(p.url), index: i) }
    p = ws.load(p.url)

    var threw = false
    do { try Ops.newProject(ws, title: "roof repair", area: "Personal") } catch { threw = true }
    check(threw, "duplicate name rejected across areas")

    p = try Ops.close(ws, p)
    check(ws.isInClosed(p), "moved to Closed")
    eq(p.status, "closed"); eq(p.area, "House")
    p = try Ops.reopen(ws, p, area: "Personal")
    eq(p.url.deletingLastPathComponent().lastPathComponent, "Personal")
    eq(p.document!.frontMatter["closed"], .null)
    p = try Ops.rename(ws, p, to: "Roof")
    eq(p.folderName, "Roof"); eq(p.title, "Roof")
    p = try Ops.rename(ws, p, to: "ROOF")                 // case-only rename
    eq(p.folderName, "ROOF")
}

test("ops: receipts are filed by year and referenced") {
    let ws = try tempWorkspace()
    let p = try Ops.newProject(ws, title: "R", area: "House")
    let rel = try Ops.addReceipt(ws, p, data: Data("%PDF".utf8), fileExtension: "PDF", description: "Shingles/roof",
                                 amount: 12.5, vendor: "Lowes", date: "2026-10-09")
    eq(rel, "2026/2026-10-09 Shingles-roof.pdf")
    let q = ws.load(p.url)
    eq(q.totalCost, 12.5)
    eq(q.receipts[0].vendor, "Lowes")
    check(Ops.receiptURL(ws, q.receipts[0]).map { FileManager.default.fileExists(atPath: $0.path) } ?? false, "file exists")
    try Ops.removeReceipt(ws, q, index: 0)
    eq(ws.load(p.url).receipts.count, 0)
    eq(Ops.receiptURL(ws, Receipt(index: 0, path: "../../etc/passwd", amount: nil, vendor: nil, date: nil)), nil)
}

test("ops: existing files are referenced by path, never copied") {
    let ws = try tempWorkspace()
    let p = try Ops.newProject(ws, title: "R", area: "House")
    let rec = ws.receiptsRoot!
    let inRoot = rec.appendingPathComponent("2026/invoice.pdf")
    try FileManager.default.createDirectory(at: inRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("%PDF".utf8).write(to: inRoot)
    let docs = rec.deletingLastPathComponent().appendingPathComponent("Documents")
    let elsewhere = docs.appendingPathComponent("Finance/Lowes.pdf")
    try FileManager.default.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("%PDF".utf8).write(to: elsewhere)
    let before = FileManager.default.enumerator(atPath: rec.path)?.allObjects.count
    let r1 = try Ops.receiptReference(ws, fileURL: inRoot, documentsRoot: docs)
    let r2 = try Ops.receiptReference(ws, fileURL: elsewhere, documentsRoot: docs)
    eq(r1, "2026/invoice.pdf")
    eq(r2, "Documents/Finance/Lowes.pdf")
    try Ops.addReceiptReference(ws, p, path: r1, amount: 1, vendor: nil, date: "2026-10-09")
    try Ops.addReceiptReference(ws, ws.load(p.url), path: r2, amount: 2, vendor: "Lowes", date: "2026-10-09")
    eq(FileManager.default.enumerator(atPath: rec.path)?.allObjects.count, before)   // nothing copied
    let q = ws.load(p.url)
    eq(q.receipts.map(\.path), [r1, r2])
    eq(Ops.receiptURL(ws, q.receipts[1], documentsRoot: docs)?.resolvingSymlinksInPath().path,
       elsewhere.resolvingSymlinksInPath().path)
    do { try Ops.addReceiptReference(ws, q, path: r1, amount: nil, vendor: nil); check(false, "duplicate allowed") } catch {}
}

test("ops: ideas and promote") {
    let ws = try tempWorkspace()
    try Ops.addIdea(ws, "Backyard Sequoia tree")
    try Ops.addIdea(ws, "Solar")
    eq(Ops.ideas(ws), ["Backyard Sequoia tree", "Solar"])
    let p = try Ops.promoteIdea(ws, index: 0, area: "House")
    eq(p.folderName, "Backyard Sequoia tree")
    eq(Ops.ideas(ws), ["Solar"])
    let backlog = try ws.fs.readText(ws.backlogURL)
    check(backlog.hasPrefix("# Idea Backlog\n\n- Solar\n"), "backlog format")
}

test("setup: empty folder becomes a workspace; areas") {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("projkit-setup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let ws = Workspace(root: base, receiptsRoot: base.appendingPathComponent(internalReceiptsDirName))
    check(ws.needsSetup, "empty folder needs setup")
    try Ops.setUpWorkspace(ws, areas: ["Home", "Personal", " ", "home"], receiptsInside: true)
    check(!ws.needsSetup, "set up")
    eq(ws.areas(), ["Home", "Personal"])                     // reserved "3 - Receipts" is not an area
    check(ws.fs.isDirectory(ws.internalReceiptsDir), "3 - Receipts created")
    eq(ws.template()?.title, "Project")
    eq(Ops.ideas(ws), [])
    try Ops.setUpWorkspace(ws, areas: ["Work"], receiptsInside: false)   // idempotent, adds new areas
    eq(ws.areas(), ["Home", "Personal", "Work"])
    let p = try Ops.newProject(ws, title: "Garden", area: "Home")
    eq(p.section("Description"), "")
    try Ops.addReceipt(ws, p, data: Data("%PDF".utf8), fileExtension: "pdf", description: "Seeds",
                       amount: 4, vendor: nil, date: "2026-11-03")
    eq(ws.load(p.url).receipts.first?.path, "2026/2026-11-03 Seeds.pdf")
    var threw = 0
    for bad in ["home", "4 - Stuff", "a/b", ""] {
        do { try Ops.newArea(ws, bad) } catch { threw += 1 }
    }
    eq(threw, 4, "bad area names rejected")
}

test("iCloud placeholder names map to real names") {
    let ws = try tempWorkspace()
    let dir = ws.root.appendingPathComponent("House/Ph")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data().write(to: dir.appendingPathComponent(".README.md.icloud"))
    let names = try ws.fs.children(of: dir).map(\.lastPathComponent)
    eq(names, ["README.md"])
    check(ws.fs.exists(dir.appendingPathComponent("README.md")), "exists via placeholder")
}

test("overview: project order, area order, collapsed areas, format") {
    let ws = try tempWorkspace()
    for t in ["Roof", "Fence", "Attic"] { _ = try Ops.newProject(ws, title: t, area: "House") }
    _ = try Ops.newProject(ws, title: "Taxes", area: "Personal")
    func names() -> [String] { ws.areaProjects("House").map(\.folderName) }
    func p(_ n: String) -> Project { ws.project(named: n)! }
    try Ops.setStatus(ws, p("Attic"), "on-hold")
    eq(names(), ["Fence", "Roof", "Attic"], "status, then name")
    check(!ws.fs.exists(ws.overviewURL), "no file until something is changed")
    try Ops.moveProject(ws, p("Roof"), to: 0)
    eq(names(), ["Roof", "Fence", "Attic"])
    try Ops.moveProject(ws, p("Attic"), before: "Fence")
    eq(names(), ["Roof", "Attic", "Fence"])
    try Ops.moveProject(ws, p("Roof"), after: "Fence")
    eq(names(), ["Attic", "Fence", "Roof"])
    try Ops.setStatus(ws, p("Attic"), "active")
    _ = try Ops.newProject(ws, title: "Barn", area: "House")
    eq(names(), ["Attic", "Fence", "Roof", "Barn"], "manual order kept; new projects last")
    var threw = 0
    do { try Ops.moveProject(ws, p("Roof"), to: 9) } catch { threw += 1 }
    do { try Ops.moveProject(ws, p("Roof"), before: "Taxes") } catch { threw += 1 }
    eq(threw, 2, "bad moves rejected")
    _ = try Ops.rename(ws, p("Fence"), to: "Fence Repair")
    eq(names(), ["Attic", "Fence Repair", "Roof", "Barn"], "rename keeps place")
    eq(ws.overviewAreas(), ["House", "Personal"])
    try Ops.moveArea(ws, "Personal", to: 0)
    eq(ws.overviewAreas(), ["Personal", "House"])
    try Ops.moveArea(ws, "Personal", after: "House")
    eq(ws.overviewAreas(), ["House", "Personal"])
    try FileManager.default.createDirectory(at: ws.root.appendingPathComponent("Cars"), withIntermediateDirectories: true)
    eq(ws.overviewAreas(), ["House", "Personal", "Cars"], "new areas follow ordered ones")
    try Ops.setCollapsed(ws, areas: ["House", "Cars"], true)
    try Ops.setCollapsed(ws, areas: ["Cars"], false)
    eq(ws.overview().collapsed, ["House"])
    do { try Ops.setCollapsed(ws, areas: ["Nope"], true); check(false, "unknown area") } catch {}
    try FileManager.default.removeItem(at: ws.root.appendingPathComponent("Cars"))
    try Ops.moveArea(ws, "Personal", to: 0)
    let text = try ws.fs.readText(ws.overviewURL)
    eq(text, "# Overview\n\nLayout of the Projects overview: area order, collapsed areas, and project order within areas. Written by proj; safe to edit."
        + "\n\n## Areas\n\n- Personal\n- House\n\n## Collapsed\n\n- House\n\n## Order\n\n### House\n- Attic\n- Fence Repair\n- Roof\n")
    eq(Overview.parse(text + "\n## Mine\nkept\n").serialize(), text + "\n## Mine\nkept\n", "round trip")
    try Ops.resetAreaOrder(ws)
    eq(ws.overviewAreas(), ["House", "Personal"])
    try Ops.resetOrder(ws, area: "House")
    eq(names(), ["Attic", "Barn", "Fence Repair", "Roof"])
}

test("photos: body format matches projkit") {
    let body = "## Description\nx\n\n## Notes\n### 2026-11-06\n- hi\n"
    var b = try ReadmeBody.addPhoto(body, note: "Before [1]\nfront", path: "Photos/a.jpg")
    eq(b, "## Description\nx\n\n## Photos\n- ![Before (1) front](<Photos/a.jpg>)\n\n## Notes\n### 2026-11-06\n- hi\n")
    b = try ReadmeBody.addPhoto(b, note: "", path: "Photos/b.jpg")
    check(b.contains("- ![Before (1) front](<Photos/a.jpg>)\n- ![](<Photos/b.jpg>)\n\n## Notes"), "second photo after first")
    eq(try ReadmeBody.editPhoto(b, index: 1, note: "After"),
       b.replacingOccurrences(of: "![](<Photos/b.jpg>)", with: "![After](<Photos/b.jpg>)"))
    eq(try ReadmeBody.removePhoto(b, index: 0), b.replacingOccurrences(of: "- ![Before (1) front](<Photos/a.jpg>)\n", with: ""))
    let t = try ReadmeBody.addTaskPhoto("## Tasks\n- [ ] One\n  - note\n  - [F](<Documents/f.pdf>)\n- [ ] Two\n", task: 0,
                                        note: "Leak", path: "Photos/c.jpg")
    eq(t, "## Tasks\n- [ ] One\n  - note\n  - [F](<Documents/f.pdf>)\n  - ![Leak](<Photos/c.jpg>)\n- [ ] Two\n")
    let task = ReadmeBody.tasks(t)[0]
    eq(task.notes.map(\.text), ["note"], "photos aren't notes")
    eq(task.photos.map(\.path), ["Photos/c.jpg"])
    eq(try ReadmeBody.removeTaskPhoto(t, task: 0, index: 0), "## Tasks\n- [ ] One\n  - note\n  - [F](<Documents/f.pdf>)\n- [ ] Two\n")
    for line in ["- ![x](<Documents/a.jpg>)", "- ![x](<Photos/sub/a.jpg>)", "- [x](<Photos/a.jpg>)", "- ![x](<Photos/>)"] {
        check(ReadmeBody.parsePhotoLine(line) == nil, "not a photo: \(line)")
    }
}

test("photos: files, archive and restore, delete") {
    let ws = try tempWorkspace()
    var p = try Ops.newProject(ws, title: "Roof", area: "House")
    try Ops.addTask(ws, p, "Patch the leak")
    let jpeg = Data([0xff, 0xd8, 0xff, 0xe0])
    let ph = try Ops.addPhoto(ws, p, data: jpeg, ext: "JPG", note: "Front")
    p = ws.load(p.url)
    eq(p.photos.map(\.note), ["Front"])
    eq(try Data(contentsOf: Ops.photoURL(p, ph)), jpeg)
    let tph = try Ops.addPhoto(ws, p, data: jpeg, ext: "png", note: "Leak", task: 0)
    try Ops.editPhotoNote(ws, p, index: 0, note: "Leak (fixed)", task: 0)
    eq(ws.load(p.url).tasks[0].photos.map(\.note), ["Leak (fixed)"])
    try Ops.archiveTask(ws, ws.load(p.url), index: 0, date: "2026-11-06")
    let a = ws.archive()!
    check(FileManager.default.fileExists(atPath: a.url.appendingPathComponent(tph.path).path), "photo moved to Archive")
    check(!FileManager.default.fileExists(atPath: p.url.appendingPathComponent(tph.path).path), "photo left the project")
    p = try Ops.restoreTask(ws, index: 0)
    check(FileManager.default.fileExists(atPath: p.url.appendingPathComponent(tph.path).path), "photo restored")
    try Ops.removePhoto(ws, p, index: 0)
    check(!FileManager.default.fileExists(atPath: Ops.photoURL(p, ph).path), "removing a photo deletes its file")
    try Ops.removeTask(ws, ws.load(p.url), index: 0)
    check(!FileManager.default.fileExists(atPath: p.url.appendingPathComponent(tph.path).path), "task photos go with the task")
    var threw = false
    do { try Ops.addPhoto(ws, p, data: jpeg, ext: "pdf", note: nil) } catch { threw = true }
    check(threw, "non-image refused")
}

test("move a task to another project") {
    let ws = try tempWorkspace()
    var roof = try Ops.newProject(ws, title: "Roof", area: "House")
    var shed = try Ops.newProject(ws, title: "Shed", area: "Personal")
    try Ops.addTask(ws, roof, "Patch the leak")
    try Ops.addTask(ws, roof, "Buy shingles")
    try Ops.addTaskNote(ws, roof, task: 1, text: "30-year ones")
    try Ops.addTaskFile(ws, roof, task: 1, target: "https://example.com/q", name: "Quote")
    let ph = try Ops.addPhoto(ws, ws.load(roof.url), data: Data([0xff, 0xd8]), ext: "jpg", note: "Old", task: 1)
    try Ops.addTask(ws, shed, "Paint it")
    try Ops.copyToToday(ws, ws.load(roof.url), index: 1)
    let before = ws.load(roof.url).document!.body
    try Ops.moveTaskTo(ws, ws.load(roof.url), index: 1, to: ws.load(shed.url))
    roof = ws.load(roof.url); shed = ws.load(shed.url)
    eq(roof.tasks.map(\.text), ["Patch the leak"])
    eq(shed.tasks.map(\.text), ["Paint it", "Buy shingles"])
    eq(shed.tasks[1].notes.map(\.text), ["30-year ones"])
    eq(shed.tasks[1].files.map(\.name), ["Quote"])
    check(FileManager.default.fileExists(atPath: shed.url.appendingPathComponent(ph.path).path), "photo moved along")
    check(!FileManager.default.fileExists(atPath: roof.url.appendingPathComponent(ph.path).path), "photo left the source")
    let block = try ReadmeBody.taskBlock(before, index: 1).joined(separator: "\n")
    check(shed.document!.body.contains("- [ ] Paint it\n" + block + "\n"), "block moved verbatim, after the last task")
    try Ops.setTask(ws, ws.today()!, index: 0, done: true)       // Today copy still linked
    check(ws.load(shed.url).tasks[1].done, "Today tick reaches the moved task")
    var threw = 0
    do { try Ops.moveTaskTo(ws, shed, index: 0, to: shed) } catch { threw += 1 }
    do { try Ops.moveTaskTo(ws, shed, index: 0, to: ws.today()!) } catch { threw += 1 }
    do { try Ops.moveTaskTo(ws, ws.today()!, index: 0, to: shed) } catch { threw += 1 }
    do { try Ops.moveTaskTo(ws, shed, index: 9, to: roof) } catch { threw += 1 }
    eq(threw, 4, "refusals")
    eq(ws.load(shed.url).tasks.count, 2, "refusals change nothing")
}

print("\n\(passed) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
