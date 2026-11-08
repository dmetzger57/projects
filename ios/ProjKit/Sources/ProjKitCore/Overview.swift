import Foundation

/// `0 - Overview.md` at the projects root: area order, collapsed areas, and project order per area.
/// Same format as projkit `ops.parse_overview` / `format_overview` (see SPEC.md).
public let overviewFileName = "0 - Overview.md"

public let projectStatusOrder = ["active": 0, "blocked": 1, "on-hold": 2, "completed-on-hold": 3, "backlog": 4, "idea": 5, "closed": 6]

public struct Overview: Sendable, Equatable {
    public static let defaultHead =
        "# Overview\n\nLayout of the Projects overview: area order, collapsed areas, and project order within areas. Written by proj; safe to edit."

    /// Area order, top first.
    public var areas: [String] = []
    /// Areas shown as just their heading.
    public var collapsed: [String] = []
    /// Areas in file order, each with project folder names top first.
    public var order: [(area: String, names: [String])] = []
    public var head = Overview.defaultHead
    /// Other `## ` sections, kept as is.
    public var extra = ""

    public init() {}

    public static func == (a: Overview, b: Overview) -> Bool {
        a.order.map(\.area) == b.order.map(\.area) && a.order.map(\.names) == b.order.map(\.names)
            && a.areas == b.areas && a.collapsed == b.collapsed && a.head == b.head && a.extra == b.extra
    }

    public func names(in area: String) -> [String] { order.first { $0.area == area }?.names ?? [] }
    public func hasOrder(_ area: String) -> Bool { !names(in: area).isEmpty }

    public func isCollapsed(_ area: String) -> Bool {
        let a = area.lowercased()
        return collapsed.contains { $0.lowercased() == a }
    }

    /// Manually ordered areas first (in their order), then the rest by name.
    public func sortedAreas(_ names: [String]) -> [String] {
        var rank: [String: Int] = [:]
        for (i, a) in areas.enumerated() where rank[a.lowercased()] == nil { rank[a.lowercased()] = i }
        func key(_ a: String) -> (Int, Int, String) {
            if let r = rank[a.lowercased()] { return (0, r, "") }
            return (1, 0, a.lowercased())
        }
        return names.sorted { key($0) < key($1) }
    }

    public mutating func setNames(_ names: [String], in area: String) {
        if let i = order.firstIndex(where: { $0.area == area }) { order[i].names = names }
        else { order.append((area, names)) }
    }

    public mutating func removeOrder(_ area: String) { order.removeAll { $0.area == area } }

    /// Manually ordered projects first (in their order), then the rest by status and title.
    public func sorted(_ projects: [Project], area: String) -> [Project] {
        var rank: [String: Int] = [:]
        for (i, n) in names(in: area).enumerated() where rank[n.lowercased()] == nil { rank[n.lowercased()] = i }
        func key(_ p: Project) -> (Int, Int, Int, String) {
            if let r = rank[p.folderName.lowercased()] { return (0, r, 0, "") }
            return (1, 0, projectStatusOrder[p.status] ?? 9, p.title.lowercased())
        }
        return projects.sorted { key($0) < key($1) }
    }

    public static func parse(_ text: String) -> Overview {
        var ov = Overview()
        var head: [String] = [], extra: [String] = []
        var section: String?, area: String?
        func bullet(_ l: String) -> String? {
            guard l.hasPrefix("- ") || l.hasPrefix("* ") else { return nil }
            let t = l.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        for line in text.components(separatedBy: "\n") {
            let l = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if l.hasPrefix("## ") {
                section = l.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                area = nil
                if !["areas", "collapsed", "order"].contains(section!) { extra.append(l) }
                continue
            }
            switch section {
            case nil: head.append(l)
            case "areas":
                if let n = bullet(l) { ov.areas.append(n) }
            case "order":
                if l.hasPrefix("### ") {
                    let a = l.dropFirst(4).trimmingCharacters(in: .whitespaces)
                    area = a
                    if !ov.order.contains(where: { $0.area == a }) { ov.order.append((a, [])) }
                } else if let a = area, let n = bullet(l), let i = ov.order.firstIndex(where: { $0.area == a }) {
                    ov.order[i].names.append(n)
                }
            case "collapsed":
                if let n = bullet(l) { ov.collapsed.append(n) }
            default: extra.append(l)
            }
        }
        let h = head.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        ov.head = h.isEmpty ? defaultHead : h
        ov.extra = extra.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ov
    }

    public func serialize() -> String {
        var out = [head]
        for (heading, items) in [("Areas", areas), ("Collapsed", collapsed)] {
            out += ["", "## \(heading)"] + (items.isEmpty ? [] : [""] + items.map { "- \($0)" })
        }
        out += ["", "## Order"]
        for (area, names) in order where !names.isEmpty {
            out += ["", "### \(area)"] + names.map { "- \($0)" }
        }
        if !extra.isEmpty { out += ["", extra] }
        var s = out.joined(separator: "\n")
        while s.hasSuffix("\n") || s.hasSuffix(" ") { s.removeLast() }
        return s + "\n"
    }
}

extension Workspace {
    public var overviewURL: URL { root.appendingPathComponent(overviewFileName) }

    public func overview() -> Overview {
        (try? fs.readText(overviewURL)).map(Overview.parse) ?? Overview()
    }

    /// Every area on the overview (folders, plus areas only closed projects still name), in order.
    public func overviewAreas(overview ov: Overview? = nil) -> [String] {
        var names = areas()
        for p in projects() where !names.contains(displayArea(p)) { names.append(displayArea(p)) }
        return (ov ?? overview()).sortedAreas(names)
    }

    /// Every project of an area (closed ones included), in overview order.
    public func areaProjects(_ area: String, overview ov: Overview? = nil) -> [Project] {
        (ov ?? overview()).sorted(projects().filter { displayArea($0) == area }, area: area)
    }
}

extension Ops {
    static func writeOverview(_ ws: Workspace, _ ov: Overview) throws {
        try ws.fs.writeText(ov.serialize(), to: ws.overviewURL)
    }

    /// Moves a project to `position` (0-based) among its area's projects, closed ones included,
    /// and writes the area's whole order (so later status changes no longer reorder it).
    public static func moveProject(_ ws: Workspace, _ p: Project, to position: Int) throws {
        let area = ws.displayArea(p)
        var ov = ws.overview()
        var rest = ws.areaProjects(area, overview: ov).map(\.folderName)
            .filter { $0.lowercased() != p.folderName.lowercased() }
        guard (0...rest.count).contains(position) else { throw OpError("position must be 1–\(rest.count + 1)") }
        rest.insert(p.folderName, at: position)
        ov.setNames(rest, in: area)
        try writeOverview(ws, ov)
    }

    /// Moves a project just before (or after) another project of the same area.
    public static func moveProject(_ ws: Workspace, _ p: Project, before other: String? = nil, after: String? = nil) throws {
        let area = ws.displayArea(p)
        let rest = ws.areaProjects(area).map(\.folderName).filter { $0.lowercased() != p.folderName.lowercased() }
        let ref = (other ?? after ?? "").lowercased()
        guard let i = rest.firstIndex(where: { $0.lowercased() == ref }) else {
            throw OpError("no project '\(other ?? after ?? "")' in area '\(area)'")
        }
        try moveProject(ws, p, to: i + (after != nil ? 1 : 0))
    }

    /// Back to the default order (status, then name) for one area, or for all.
    public static func resetOrder(_ ws: Workspace, area: String? = nil) throws {
        var ov = ws.overview()
        if let area { ov.removeOrder(area) } else { ov.order = [] }
        try writeOverview(ws, ov)
    }

    /// Moves an area to `position` (0-based) on the overview; writes the whole area order.
    public static func moveArea(_ ws: Workspace, _ area: String, to position: Int) throws {
        var ov = ws.overview()
        let all = ws.overviewAreas(overview: ov)
        guard all.contains(area) else { throw OpError("no area '\(area)'") }
        var rest = all.filter { $0 != area }
        guard (0...rest.count).contains(position) else { throw OpError("position must be 1–\(rest.count + 1)") }
        rest.insert(area, at: position)
        ov.areas = rest
        try writeOverview(ws, ov)
    }

    /// Moves an area just before (or after) another area.
    public static func moveArea(_ ws: Workspace, _ area: String, before other: String? = nil, after: String? = nil) throws {
        let rest = ws.overviewAreas().filter { $0 != area }
        let ref = other ?? after ?? ""
        guard let i = rest.firstIndex(of: ref) else { throw OpError("no area '\(ref)'") }
        try moveArea(ws, area, to: i + (after != nil ? 1 : 0))
    }

    /// Areas back to alphabetical.
    public static func resetAreaOrder(_ ws: Workspace) throws {
        var ov = ws.overview()
        ov.areas = []
        try writeOverview(ws, ov)
    }

    /// Collapses areas to just their heading (or expands them again).
    public static func setCollapsed(_ ws: Workspace, areas: [String], _ collapsed: Bool) throws {
        var ov = ws.overview()
        let existing = ws.overviewAreas(overview: ov)
        if let bad = areas.first(where: { !existing.contains($0) }) { throw OpError("no area '\(bad)'") }
        let names = Set(areas.map { $0.lowercased() })
        var keep = ov.collapsed.filter { !names.contains($0.lowercased()) }
        if collapsed { keep += areas }
        let have = Set(existing.map { $0.lowercased() })
        ov.collapsed = keep.filter { have.contains($0.lowercased()) }   // forget deleted areas
        try writeOverview(ws, ov)
    }

    /// After a project rename, keeps its place.
    static func retargetOverview(_ ws: Workspace, from old: String, to new: String) throws {
        guard ws.fs.exists(ws.overviewURL) else { return }
        var ov = ws.overview()
        let swap = { (n: String) in n.lowercased() == old.lowercased() ? new : n }
        ov.order = ov.order.map { ($0.area, $0.names.map(swap)) }
        try writeOverview(ws, ov)
    }
}

// MARK: - All Open Tasks

/// One project's open tasks on the All Open Tasks view.
public struct OpenTaskGroup: Identifiable, Hashable, Sendable {
    public let area: String
    public let project: Project
    public let tasks: [ProjectTask]          // open ones only; `index` is the task's place in the project
    public var id: String { project.folderName }

    public init(area: String, project: Project, tasks: [ProjectTask]) {
        self.area = area; self.project = project; self.tasks = tasks
    }
}

extension Ops {
    /// All Open Tasks: every not-done task of every project that isn't closed (Today and the Archive
    /// aren't projects here), grouped by project in overview order (areas, then projects in each area);
    /// projects with no open tasks are left out. Mirrors projkit `ops.open_tasks`.
    /// Pure, so the app can build it from what it has loaded; `areas` are the area folders.
    public static func openTasks(projects: [Project], areas: [String], overview ov: Overview,
                                 area: (Project) -> String, isClosed: (Project) -> Bool) -> [OpenTaskGroup] {
        var names = areas
        for p in projects where !names.contains(area(p)) { names.append(area(p)) }
        return ov.sortedAreas(names).flatMap { a in
            ov.sorted(projects.filter { area($0) == a }, area: a).compactMap { p -> OpenTaskGroup? in
                guard !p.isLegacy, p.parseError == nil, p.status != "closed", !isClosed(p) else { return nil }
                let open = p.tasks.filter { !$0.done }
                return open.isEmpty ? nil : OpenTaskGroup(area: a, project: p, tasks: open)
            }
        }
    }

    public static func openTasks(_ ws: Workspace) -> [OpenTaskGroup] {
        openTasks(projects: ws.projects(), areas: ws.areas(), overview: ws.overview(),
                  area: ws.displayArea, isClosed: ws.isInClosed)
    }

    /// Copies several tasks ((project, 0-based index) pairs) into Today, linked; returns how many were
    /// new there (ones already in Today are skipped). Mirrors projkit `ops.copy_many_to_today`.
    @discardableResult
    public static func copyManyToToday(_ ws: Workspace, _ picks: [(Project, Int)]) throws -> Int {
        var added = 0
        for (p, i) in picks where try copyToToday(ws, p, index: i) { added += 1 }
        return added
    }
}
