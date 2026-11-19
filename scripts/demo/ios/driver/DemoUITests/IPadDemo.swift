import XCTest

/// iPad (landscape) feature tour; same EVT| logging as IPhoneDemo. Coordinates are landscape points (1210x834).
final class IPadDemo: XCTestCase {
    var app: XCUIApplication!

    func now() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }
    func scene(_ title: String, _ sub: String) { print("EVT|\(now())|SCENE|\(title)|\(sub)") }
    func center(_ e: XCUIElement) -> CGPoint { CGPoint(x: e.frame.midX, y: e.frame.midY) }
    func pause(_ s: Double) { Thread.sleep(forTimeInterval: s) }
    func origin() -> XCUICoordinate { app.coordinate(withNormalizedOffset: .zero) }

    func tap(_ e: XCUIElement, wait: Double = 1.2) {
        XCTAssert(e.waitForExistence(timeout: 5), "missing \(e)")
        let p = center(e); print("EVT|\(now())|TAP|\(p.x)|\(p.y)")
        origin().withOffset(CGVector(dx: p.x, dy: p.y)).tap(); pause(wait)
    }
    func hold(_ e: XCUIElement, wait: Double = 1.8) {
        XCTAssert(e.waitForExistence(timeout: 5))
        let p = center(e); print("EVT|\(now())|HOLD|\(p.x)|\(p.y)")
        e.press(forDuration: 1.4); pause(wait)
    }
    func swipe(_ e: XCUIElement, dx: CGFloat, wait: Double = 1.6) {
        XCTAssert(e.waitForExistence(timeout: 5))
        let p = center(e)
        let x0: CGFloat = dx > 0 ? 100 : 1100
        print("EVT|\(now())|SWIPE|\(x0)|\(p.y)|\(x0 + dx)|\(p.y)")
        origin().withOffset(CGVector(dx: x0, dy: p.y))
            .press(forDuration: 0.05, thenDragTo: origin().withOffset(CGVector(dx: x0 + dx, dy: p.y)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
        pause(wait)
    }
    func scroll(_ dy: CGFloat, x: CGFloat = 750, wait: Double = 1.2) {
        let y0: CGFloat = dy < 0 ? 700 : 260
        print("EVT|\(now())|SWIPE|\(x)|\(y0)|\(x)|\(y0 + dy)")
        origin().withOffset(CGVector(dx: x, dy: y0))
            .press(forDuration: 0.05, thenDragTo: origin().withOffset(CGVector(dx: x, dy: y0 + dy)),
                   withVelocity: .default, thenHoldForDuration: 0.15)
        pause(wait)
    }
    func type(_ field: XCUIElement, _ text: String, submit: Bool = true) {
        tap(field, wait: 0.6)
        field.typeText(text)
        if submit { field.typeText("\n") }
        pause(1.0)
    }
    func tab(_ icon: String) { tap(app.buttons.matching(identifier: icon).firstMatch, wait: 1.5) }
    func text(_ s: String) -> XCUIElement { app.staticTexts[s].firstMatch }
    func starts(_ s: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", s)).firstMatch }
    /// The matching button in the detail pane (right of the sidebar) or in the sidebar.
    func button(_ label: String, inDetail: Bool) -> XCUIElement {
        let all = app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
        return all.first { inDetail ? $0.frame.minX > 300 : $0.frame.minX < 300 } ?? all.first ?? app.buttons[label]
    }

    func testTour() throws {
        app = XCUIApplication(bundleIdentifier: "com.dmetzger57.proj")
        app.activate()
        XCUIDevice.shared.orientation = .landscapeLeft
        pause(2.5)

        // 1. Today
        scene("Today", "Your list for the day. Tasks copied from projects stay linked to them.")
        pause(3.0)
        tap(app.buttons["Mark “Pick up dry cleaning” done"])
        scene("Today", "Tick a project task here and it is ticked in its project too.")
        tap(app.buttons["Mark “Get three contractor quotes” done"], wait: 1.8)
        scene("Today", "Add tasks straight to Today.")
        type(app.textFields["Add a task"], "Renew library books")
        pause(1.5)

        // 2. Open Tasks
        tab("checklist")
        scene("Open Tasks", "Every open task of every project, grouped by project.")
        pause(3.0)
        scene("Open Tasks", "Filter the list by task or project name.")
        let filter = app.searchFields["Filter tasks or projects"]
        type(filter, "garage", submit: false)
        pause(2.0)
        tap(filter.buttons.firstMatch, wait: 1.0)          // clear
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { tap(cancel, wait: 1.0) }
        scene("Open Tasks", "Each task's ⋯ menu: edit, add a note, photo, link or reminder, copy to Today.")
        tap(app.buttons["Actions for “Clear the gutters”"], wait: 2.2)
        tap(app.buttons["Copy to Today"].firstMatch, wait: 1.8)
        scene("Open Tasks", "Swipe right to mark a task done or copy it to Today…")
        swipe(text("Order cabinet hardware"), dx: 170, wait: 2.2)
        swipe(text("Order cabinet hardware"), dx: -120, wait: 1.0)
        scene("Open Tasks", "…swipe left to edit it, add a note, set a reminder or open its project.")
        swipe(text("Schedule electrician for lighting"), dx: -105, wait: 2.6)
        swipe(text("Schedule electrician for lighting"), dx: 100, wait: 1.0)
        scene("Open Tasks", "Or tap Select, pick several tasks and copy them to Today at once.")
        tap(app.buttons["Select"].firstMatch)
        tap(text("Install wall shelving"), wait: 0.8)
        tap(text("Donate old bikes"), wait: 1.0)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Copy '")).firstMatch, wait: 2.0)
        let done = app.buttons["Done"].firstMatch
        if done.exists { tap(done) }
        pause(1.0)

        // 3. Projects
        tab("folder")
        scene("Projects", "On iPad, projects sit in a sidebar beside an overview of tiles by area.")
        pause(3.5)
        scroll(-380, wait: 2.0)
        scroll(340, wait: 1.5)
        scene("Projects", "Collapse every area to just its name, or fold one area at a time.")
        tap(button("Collapse All", inDetail: true), wait: 2.0)
        tap(button("Expand All", inDetail: true), wait: 2.0)
        tap(button("Collapse Home", inDetail: true), wait: 2.0)
        tap(button("Expand Home", inDetail: true), wait: 1.5)
        scene("Projects", "Touch and hold a tile to change the order of projects in its area.")
        hold(starts("Garage Organization, Backlog, Tasks"), wait: 2.2)
        tap(app.buttons["Move to Top"].firstMatch, wait: 2.0)
        scene("Projects", "Filter open, closed or all projects, or search names, goals and notes.")
        tap(app.buttons["All"].firstMatch, wait: 1.5)
        tap(app.buttons["Closed"].firstMatch, wait: 2.0)
        tap(app.buttons["Open"].firstMatch, wait: 1.2)
        let search = app.searchFields["Projects, goals, notes"]
        type(search, "holidays", submit: false)
        pause(2.2)
        tap(search.buttons.firstMatch, wait: 1.0)
        let cancel2 = app.buttons["Cancel"].firstMatch
        if cancel2.exists { tap(cancel2, wait: 1.0) }
        scene("Projects", "Hide the sidebar to give the overview the whole screen.")
        tap(app.buttons["Hide Sidebar"].firstMatch, wait: 2.5)
        tap(app.buttons["Show Sidebar"].firstMatch, wait: 1.8)

        // 4. A project
        scene("A project", "A project opens beside the list: status, goals, tasks, photos, notes, files, links, receipts.")
        tap(starts("Kitchen Remodel, Active, Goals"), wait: 3.0)
        scene("A project", "Change the status from a menu.")
        tap(app.buttons["Status, Active"], wait: 1.5)
        tap(app.buttons["Blocked"].firstMatch, wait: 1.8)
        tap(app.buttons["Status, Blocked"], wait: 1.2)
        tap(app.buttons["Active"].firstMatch, wait: 1.5)
        scene("A project", "Tick off goals as you reach them.")
        tap(app.buttons["Finish before the holidays"], wait: 2.0)
        scroll(-360, wait: 1.2)
        scene("A project", "The Tasks checklist: tick, add, edit, add notes, drag to reorder. ☀ = in Today.")
        tap(app.buttons["Mark “Order cabinet hardware” done"], wait: 2.0)
        let add = app.textFields["Add a task"]
        if !add.exists || add.frame.maxY > 740 { scroll(-260, wait: 1.0) }
        type(add, "Pick paint colors")
        scene("A project", "Photos with notes, dated notes, Project Files and links.")
        scroll(-360, wait: 2.0)
        scroll(-360, wait: 2.2)
        scroll(-360, wait: 2.5)
        scene("A project", "Receipts add up to the project's spending.")
        scroll(-360, wait: 3.0)
        scene("A project", "Switch projects straight from the sidebar.")
        tap(starts("Vegetable Beds, Active"), wait: 3.0)
        tap(app.buttons["Overview"].firstMatch, wait: 1.5)

        // 5. New project
        scene("New project", "Create a project in any area; it starts from your template.")
        tap(button("Add", inDetail: false), wait: 1.2)
        tap(app.buttons["New Project"], wait: 1.2)
        type(app.textFields["Name"], "Patio Furniture", submit: false)
        tap(app.buttons["Area, Garden"], wait: 1.2)
        tap(app.buttons["Home"].firstMatch, wait: 1.2)
        tap(app.buttons["Create"], wait: 3.0)
        let ov = app.buttons["Overview"].firstMatch
        if ov.exists { tap(ov, wait: 1.5) }

        // 6. Ideas
        tab("lightbulb")
        scene("Ideas", "An idea backlog for someday-maybe projects.")
        pause(2.0)
        type(app.textFields.firstMatch, "Plant a pollinator garden")
        pause(2.0)

        // 7. Archive
        tab("archivebox")
        scene("Archive", "Archived tasks keep their notes and attachments, and can be restored.")
        pause(3.5)

        // 8. Back to Today
        tab("sun.max")
        scene("Today", "Everything you copied is waiting in Today.")
        pause(4.0)
        print("EVT|\(now())|END")
    }
}
