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
if args.count == 4, args[1] == "--mutate" {
    let ws = Workspace(root: URL(fileURLWithPath: args[2]), receiptsRoot: URL(fileURLWithPath: args[3]))
    do {
        guard var photo = ws.project(named: "Digital Photo Archive") else { throw OpError("photo project missing") }
        try Ops.setGoal(ws, photo, index: 0, done: true)
        try Ops.addGoal(ws, photo, "Buy a scanner: Epson FF-680W")
        try Ops.addNote(ws, photo, "Edited on iPhone\nsecond line")
        try Ops.addLink(ws, photo, url: "https://example.com/a?b=c#d", title: "Example: \"quoted\"")
        try Ops.setSection(ws, photo, "Description", "Consolidate **all** photos.\n\n- prints\n- slides")
        try Ops.addReceipt(ws, photo, data: Data("%PDF-1.4".utf8), fileExtension: "pdf",
                           description: "Epson scanner", amount: 649.99, vendor: "B&H", date: "2026-11-03")
        try Ops.setStatus(ws, photo, "on-hold")
        photo = try Ops.rename(ws, photo, to: "Photo Archive")
        let p = try Ops.newProject(ws, title: "Swift Made", area: "Digital Infrastructure")
        try Ops.addGoal(ws, p, "true")      // must stay a string, not a bool
        try Ops.close(ws, p)
        try Ops.addIdea(ws, "Idea from iPhone")
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

print("\n\(passed) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
