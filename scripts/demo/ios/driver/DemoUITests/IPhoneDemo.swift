import XCTest

/// Drives Proj through a feature tour while `simctl io recordVideo` records the screen.
/// Prints `EVT|<epoch>|…` lines: SCENE (captions) and TAP/SWIPE/HOLD (touch indicators), in points.
final class IPhoneDemo: XCTestCase {
    var app: XCUIApplication!

    // MARK: logging
    func now() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }
    func scene(_ title: String, _ sub: String) { print("EVT|\(now())|SCENE|\(title)|\(sub)") }
    func center(_ e: XCUIElement) -> CGPoint { CGPoint(x: e.frame.midX, y: e.frame.midY) }

    override func record(_ issue: XCTIssue) {
        print("FAILTREE\n" + (app?.debugDescription ?? "nil") + "\nENDFAILTREE")
        super.record(issue)
    }

    // MARK: gestures (all logged)
    func pause(_ s: Double) { Thread.sleep(forTimeInterval: s) }
    func tap(_ e: XCUIElement, wait: Double = 1.2) {
        XCTAssert(e.waitForExistence(timeout: 5), "missing \(e)")
        let p = center(e); print("EVT|\(now())|TAP|\(p.x)|\(p.y)")
        e.tap(); pause(wait)
    }
    func tapAt(_ x: CGFloat, _ y: CGFloat, wait: Double = 1.0) {
        print("EVT|\(now())|TAP|\(x)|\(y)")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap(); pause(wait)
    }
    func hold(_ e: XCUIElement, wait: Double = 1.8) {
        XCTAssert(e.waitForExistence(timeout: 5))
        let p = center(e); print("EVT|\(now())|HOLD|\(p.x)|\(p.y)")
        e.press(forDuration: 1.4); pause(wait)
    }
    func swipe(_ e: XCUIElement, dx: CGFloat, wait: Double = 1.6) {
        XCTAssert(e.waitForExistence(timeout: 5))
        let p = center(e)
        let x0 = dx > 0 ? 60.0 : 340.0
        print("EVT|\(now())|SWIPE|\(x0)|\(p.y)|\(x0 + dx)|\(p.y)")
        let a = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x0, dy: p.y))
        let b = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x0 + dx, dy: p.y))
        a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0.1); pause(wait)
    }
    func scroll(_ dy: CGFloat, wait: Double = 1.2) {   // dy < 0 scrolls content up (finger moves up)
        let y0: CGFloat = dy < 0 ? 640 : 260
        print("EVT|\(now())|SWIPE|200|\(y0)|200|\(y0 + dy)")
        let a = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 200, dy: y0))
        let b = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 200, dy: y0 + dy))
        a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .default, thenHoldForDuration: 0.15); pause(wait)
    }
    func scrollTo(_ e: XCUIElement, maxTries: Int = 6) {
        var n = 0
        while (!e.exists || e.frame.maxY > 760 || !e.isHittable) && n < maxTries { scroll(-300, wait: 0.8); n += 1 }
    }
    func type(_ field: XCUIElement, _ text: String, submit: Bool = true) {
        tap(field, wait: 0.6)
        field.typeText(text)
        if submit { field.typeText("\n") }
        pause(1.0)
    }
    func tab(_ name: String) { tap(app.tabBars.buttons[name], wait: 1.5) }
    func text(_ s: String) -> XCUIElement { app.staticTexts[s].firstMatch }

    // MARK: the tour
    func testTour() throws {
        app = XCUIApplication(bundleIdentifier: "com.dmetzger57.proj")
        app.activate()
        pause(2.0)

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
        tab("Open Tasks")
        scene("Open Tasks", "Every open task of every project, grouped by project.")
        pause(3.0)
        scene("Open Tasks", "Swipe right to mark a task done or copy it to Today…")
        swipe(text("Order cabinet hardware"), dx: 170, wait: 2.2)
        swipe(text("Order cabinet hardware"), dx: -120, wait: 1.0)  // close it again
        scene("Open Tasks", "…swipe left to edit it, add a note, set a reminder or open its project.")
        swipe(text("Schedule electrician for lighting"), dx: -150, wait: 2.6)
        swipe(text("Schedule electrician for lighting"), dx: 140, wait: 1.0)
        scene("Open Tasks", "Touch and hold for every action: notes, photos, links, reminders, Today.")
        hold(text("Clear the gutters"), wait: 3.0)
        tap(app.buttons["Copy to Today"].firstMatch, wait: 1.8)
        scene("Open Tasks", "Or tap Select, pick several tasks and copy them to Today at once.")
        tap(app.navigationBars["Open Tasks"].buttons["Select"])
        tap(text("Install wall shelving"), wait: 0.8)
        tap(text("Donate old bikes"), wait: 1.0)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Copy '")).firstMatch, wait: 2.0)
        let done = app.navigationBars["Open Tasks"].buttons["Done"]
        if done.exists { tap(done) }
        pause(1.0)

        // 3. Projects
        tab("Projects")
        scene("Projects", "Projects by area, with status, goal and task progress, and spending.")
        pause(3.5)
        scroll(-420, wait: 1.5)
        scroll(-420, wait: 1.5)
        scroll(700, wait: 0.6); scroll(700, wait: 1.0)
        scene("Projects", "Collapse every area to just its name, or tap one area to fold it.")
        tap(app.buttons["Collapse All"], wait: 2.0)
        tap(app.buttons["Expand All"], wait: 2.0)
        tap(app.buttons["Collapse Home"], wait: 2.0)
        tap(app.buttons["Expand Home"], wait: 1.5)
        scene("Projects", "Filter open, closed or all projects.")
        tap(app.buttons["All"], wait: 1.5)
        tap(app.buttons["Closed"], wait: 2.0)
        tap(app.buttons["Open"], wait: 1.2)

        // 4. A project
        scene("A project", "Status, description, goals, tasks, photos, notes, files, links and receipts.")
        tap(text("Kitchen Remodel"), wait: 2.5)
        scene("A project", "Change the status from a menu.")
        tap(app.buttons["Status, Active"], wait: 1.5)
        tap(app.buttons["Blocked"], wait: 1.8)
        tap(app.buttons["Status, Blocked"], wait: 1.2)
        tap(app.buttons["Active"], wait: 1.5)
        scene("A project", "Tick off goals as you reach them.")
        tap(app.buttons["Finish before the holidays"], wait: 2.0)
        scroll(-330, wait: 1.2)
        scene("A project", "The Tasks checklist: tick, add, edit, add notes, drag to reorder. ☀ = in Today.")
        tap(app.buttons["Mark “Order cabinet hardware” done"], wait: 2.0)
        type(app.textFields["Add a task"], "Pick paint colors")
        scene("A project", "Photos with notes, dated notes, Project Files and links.")
        scroll(-380, wait: 2.0)
        scroll(-380, wait: 2.2)
        scroll(-380, wait: 2.5)
        scene("A project", "Receipts add up to the project's spending.")
        scroll(-380, wait: 3.0)
        tap(app.navigationBars.buttons["Projects"], wait: 1.5)

        // 5. New project
        scene("New project", "Create a project in any area; it starts from your template.")
        tap(app.buttons["Add"], wait: 1.2)
        tap(app.buttons["New Project"], wait: 1.2)
        type(app.textFields["Name"], "Patio Furniture", submit: false)
        tap(app.buttons["Area, Garden"], wait: 1.2)
        tap(app.buttons["Home"], wait: 1.2)
        tap(app.buttons["Create"], wait: 2.5)
        tap(app.navigationBars.buttons["Projects"], wait: 1.5)

        // 6. Ideas
        tab("Ideas")
        scene("Ideas", "An idea backlog for someday-maybe projects.")
        pause(2.0)
        type(app.textFields.firstMatch, "Plant a pollinator garden")
        pause(2.0)

        // 7. Archive
        tab("More")
        tap(text("Archive"), wait: 2.0)
        scene("Archive", "Archived tasks keep their notes and attachments, and can be restored.")
        pause(3.5)

        // 8. Back to Today
        tab("More")
        tab("Today")
        scene("Today", "Everything you copied is waiting in Today.")
        pause(4.0)
        print("EVT|\(now())|END")
    }
}
