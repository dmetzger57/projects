import SwiftUI
import ProjKitCore

enum ProjectFilter: String, CaseIterable, Identifiable {
    case open = "Open", closed = "Closed", all = "All"
    var id: String { rawValue }
}

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: ProjectFilter = .open
    @State private var search = ""
    @State private var showNew = false
    @State private var showNewArea = false
    @State private var newAreaName = ""
    @State private var showReorderAreas = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #else
    private let sizeClass: UserInterfaceSizeClass? = .regular     // the Mac always gets the wide layout
    #endif
    @State private var path: [String] = Self.debugOpen.map { [$0] } ?? []
    /// Selected project in the iPad sidebar (nil: the overview grid).
    @State private var selected: String? = Self.debugOpen

    private static var debugOpen: String? {
        #if DEBUG
        // Simulator testing: PROJ_DEBUG_OPEN=<project folder name> opens that project at launch.
        return ProcessInfo.processInfo.environment["PROJ_DEBUG_OPEN"].flatMap { $0.isEmpty ? nil : $0 }
        #else
        return nil
        #endif
    }

    private var filtered: [Project] {
        model.projects.filter { p in
            switch filter {
            case .open: if p.status == "closed" { return false }
            case .closed: if p.status != "closed" { return false }
            case .all: break
            }
            guard !search.isEmpty else { return true }
            let q = search.lowercased()
            return p.title.lowercased().contains(q)
                || p.goals.contains { $0.text.lowercased().contains(q) }
                || p.tasks.contains { $0.text.lowercased().contains(q) }
                || (p.document?.body.lowercased().contains(q) ?? false)
        }
    }

    private var grouped: [(area: String, items: [Project])] {
        var groups: [String: [Project]] = [:]
        for p in filtered { groups[model.displayArea(p), default: []].append(p) }
        let names = (filter == .open && search.isEmpty ? model.areas : []) + groups.keys.sorted()
        var seen = Set<String>()
        return model.overview.sortedAreas(names.filter { seen.insert($0).inserted }).map { area in
            (area, model.overview.sorted(groups[area] ?? [], area: area))   // manual order, else status then name
        }
    }

    var body: some View {
        if sizeClass == .regular {
            #if os(macOS)
            // The Mac window already has a sidebar (Today, Projects, …). A NavigationSplitView nested
            // in it insets its detail by that sidebar's width a second time, pushing the project off
            // the right edge, so the Mac uses a plain resizable split instead.
            HSplitView {
                decorated(List(selection: $selected) { listRows })
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
                detailPane
                    .frame(minWidth: 420, maxWidth: .infinity)
            }
            #else
            // iPad (and wide windows): projects in a sidebar, the project or the overview grid beside it
            NavigationSplitView {
                decorated(List(selection: $selected) { listRows })
                    .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
            } detail: {
                detailPane
            }
            #endif
        } else {
            NavigationStack(path: $path) {
                decorated(List { listRows })
                    .navigationDestination(for: String.self) { folder in
                        ProjectDetailView(folder: folder)
                    }
            }
        }
    }

    /// The Mac shows the open project's name in the window title; elsewhere the list is "Projects".
    private var windowTitle: String {
        #if os(macOS)
        if let f = selected, let p = model.projects.first(where: { $0.folderName == f }) { return p.title }
        #endif
        return "Projects"
    }

    /// The selected project, or the overview grid when none is selected.
    private var detailPane: some View {
        NavigationStack {
            Group {
                if let f = selected {
                    ProjectDetailView(folder: f)
                        .id(f)
                        .toolbar {
                            ToolbarItem(placement: .leadingBar) {
                                Button { selected = nil } label: { Label("Overview", systemImage: "square.grid.2x2") }
                            }
                        }
                } else {
                    ProjectGridView(groups: grouped, summary: filtered) { selected = $0 }
                }
            }
            .navigationDestination(for: String.self) { ProjectDetailView(folder: $0) }
        }
    }

    private func open(_ folder: String) {
        if sizeClass == .regular { selected = folder } else { path.append(folder) }
    }

    @ViewBuilder
    private var listRows: some View {
        Section {
            Picker("Show", selection: $filter) {
                ForEach(ProjectFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            if sizeClass != .regular { SummaryRow(projects: filtered) }   // iPad: shown on the overview
        }
        ForEach(grouped, id: \.area) { group in
            Section {
                if !model.overview.isCollapsed(group.area) {
                    if group.items.isEmpty {
                        Text("No projects").foregroundStyle(.secondary).italic()
                    }
                    ForEach(group.items) { p in
                        projectRow(p, in: group.items)
                    }
                    .onMove { source, destination in
                        // SwiftUI gives the destination as an offset in the list *before* removal
                        guard let from = source.first, from != destination, from + 1 != destination else { return }
                        let items = group.items
                        if destination < items.count { move(items[from], before: items[destination]) }
                        else { move(items[from], after: items[items.count - 1]) }
                    }
                }
            } header: {
                areaHeader(group.area, items: group.items, all: grouped.map(\.area))
            }
        }
    }

    private func decorated(_ list: some View) -> some View {
        list
            .navigationTitle(windowTitle)
            .searchable(text: $search, prompt: "Projects, goals, notes")
            .refreshable { await model.reload() }
            .overlay {
                if model.projects.isEmpty && !model.isLoading {
                    ContentUnavailableView("No projects found", systemImage: "folder",
                                           description: Text("Check the Projects folder in Settings."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showNew = true } label: { Label("New Project", systemImage: "doc.badge.plus") }
                            .disabled(model.areas.isEmpty)
                        Button { newAreaName = ""; showNewArea = true } label: { Label("New Area", systemImage: "folder.badge.plus") }
                        Divider()
                        Button { showReorderAreas = true } label: { Label("Reorder Areas", systemImage: "arrow.up.arrow.down") }
                        Button { setCollapsed(model.workspace?.overviewAreas(overview: model.overview) ?? model.areas, true) } label: {
                            Label("Collapse All Areas", systemImage: "rectangle.compress.vertical")
                        }
                        Button { setCollapsed(model.workspace?.overviewAreas(overview: model.overview) ?? model.areas, false) } label: {
                            Label("Expand All Areas", systemImage: "rectangle.expand.vertical")
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showReorderAreas) { ReorderAreasSheet() }
            .sheet(isPresented: $showNew) {
                NewProjectSheet { folder in open(folder) }
            }
            .alert("New Area", isPresented: $showNewArea) {
                TextField("Name", text: $newAreaName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let name = newAreaName
                    Task { await model.newArea(name) }
                }
            } message: {
                Text("Areas group related projects, e.g. Home or Garden.")
            }
    }

    private func projectRow(_ p: Project, in items: [Project]) -> some View {
        let i = items.firstIndex { $0.folderName == p.folderName } ?? 0
        return NavigationLink(value: p.folderName) {
            if sizeClass == .regular {
                CompactProjectRow(project: p)       // iPad sidebar: the tiles and the project show the details
            } else {
                ProjectRow(project: p)
            }
        }
            .contextMenu {
                if items.count > 1 {
                    Section("Move") {
                        Button { move(p, before: items[0]) } label: { Label("Move to Top", systemImage: "arrow.up.to.line") }
                            .disabled(i == 0)
                        Button { move(p, before: items[max(i - 1, 0)]) } label: { Label("Move Up", systemImage: "arrow.up") }
                            .disabled(i == 0)
                        Button { move(p, after: items[min(i + 1, items.count - 1)]) } label: { Label("Move Down", systemImage: "arrow.down") }
                            .disabled(i == items.count - 1)
                        Button { move(p, after: items[items.count - 1]) } label: { Label("Move to Bottom", systemImage: "arrow.down.to.line") }
                            .disabled(i == items.count - 1)
                    }
                }
            }
    }

    private func areaHeader(_ area: String, items: [Project], all: [String]) -> some View {
        let collapsed = model.overview.isCollapsed(area)
        let manual = model.overview.hasOrder(area)
        let i = all.firstIndex(of: area) ?? 0
        return HStack {
            Button { setCollapsed([area], !collapsed) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Text(area)
                    if collapsed { Text("\(items.count)").foregroundStyle(.tertiary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? "Expand \(area)" : "Collapse \(area)")
            Spacer()
            Menu {
                Button { setCollapsed([area], !collapsed) } label: {
                    Label(collapsed ? "Expand" : "Collapse to Name",
                          systemImage: collapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                }
                if all.count > 1 {
                    Section("Move Area") {
                        Button { moveArea(area, before: all[max(i - 1, 0)]) } label: { Label("Move Up", systemImage: "arrow.up") }
                            .disabled(i == 0)
                        Button { moveArea(area, after: all[min(i + 1, all.count - 1)]) } label: { Label("Move Down", systemImage: "arrow.down") }
                            .disabled(i == all.count - 1)
                        Button { showReorderAreas = true } label: { Label("Reorder Areas…", systemImage: "arrow.up.arrow.down") }
                    }
                }
                if manual {
                    Button { Task { await model.perform { try Ops.resetOrder($0, area: area) } } } label: {
                        Label("Sort Projects by Status", systemImage: "arrow.up.arrow.down")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("\(area) options")
            }
            #if os(macOS)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            #endif
        }
        .textCase(nil)
    }

    private func setCollapsed(_ areas: [String], _ on: Bool) {
        Task { await model.perform { try Ops.setCollapsed($0, areas: areas, on) } }
    }

    private func moveArea(_ area: String, before other: String) {
        guard other != area else { return }
        Task { await model.perform { try Ops.moveArea($0, area, before: other) } }
    }

    private func moveArea(_ area: String, after other: String) {
        guard other != area else { return }
        Task { await model.perform { try Ops.moveArea($0, area, after: other) } }
    }

    private func move(_ p: Project, before other: Project) {
        guard other.folderName != p.folderName else { return }
        Task { await model.perform { try Ops.moveProject($0, p, before: other.folderName) } }
    }

    private func move(_ p: Project, after other: Project) {
        guard other.folderName != p.folderName else { return }
        Task { await model.perform { try Ops.moveProject($0, p, after: other.folderName) } }
    }
}

/// Drag areas into order (the same order as the web overview).
struct ReorderAreasSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let areas = model.workspace?.overviewAreas(overview: model.overview) ?? model.areas
        NavigationStack {
            List {
                ForEach(areas, id: \.self) { Text($0) }
                    .onMove { source, destination in
                        guard let from = source.first, from != destination, from + 1 != destination else { return }
                        let area = areas[from]
                        let to = destination > from ? destination - 1 : destination
                        Task { await model.perform { try Ops.moveArea($0, area, to: to) } }
                    }
            }
            .alwaysEditing()
            .navigationTitle("Reorder Areas")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !model.overview.areas.isEmpty {
                        Button("A–Z") { Task { await model.perform { try Ops.resetAreaOrder($0) } } }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .sheetSize(width: 380, height: 460)
    }
}

struct SummaryRow: View {
    let projects: [Project]
    var body: some View {
        let open = projects.reduce(0) { $0 + $1.goalProgress.total - $1.goalProgress.done }
        let openTasks = projects.reduce(0) { $0 + $1.taskProgress.total - $1.taskProgress.done }
        let cost = projects.reduce(0) { $0 + $1.totalCost }
        HStack(spacing: 18) {
            stat("\(projects.count)", "projects")
            stat("\(open)", "open goals")
            stat("\(openTasks)", "open tasks")
            stat(money(cost), "spent")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(v).font(.headline.monospacedDigit())
            Text(l).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ProjectRow: View {
    let project: Project
    var body: some View {
        let (done, total) = project.goalProgress
        let (tdone, ttotal) = project.taskProgress
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(project.title).font(.body.weight(.semibold))
                Spacer()
                StatusBadge(status: project.status)
            }
            if total > 0 { ProgressLine(label: "Goals", done: done, total: total, tint: .accentColor) }
            if ttotal > 0 { ProgressLine(label: "Tasks", done: tdone, total: ttotal, tint: .blue) }
            HStack(spacing: 12) {
                if total == 0 && ttotal == 0 { Text("No goals or tasks") }
                if !project.receipts.isEmpty { Text(money(project.totalCost)) }
                if let last = project.notes.last(where: { !$0.text.isEmpty }) { Text(shortDate(last.date)) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Sidebar row on iPad: name and status only.
struct CompactProjectRow: View {
    let project: Project
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(project.title).lineLimit(2)
            Spacer(minLength: 8)
            StatusBadge(status: project.status)
        }
    }
}

/// "Goals ▬▬▬▭▭ 2/8" — labelled progress bar used for goals and tasks.
struct ProgressLine: View {
    let label: String
    let done: Int
    let total: Int
    let tint: Color
    var body: some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 40, alignment: .leading)
            ProgressView(value: Double(done), total: Double(total)).tint(tint)
            Text("\(done)/\(total)").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(done) of \(total) done")
    }
}

struct StatusBadge: View {
    let status: String
    var color: Color {
        switch status {
        case "active": .green
        case "blocked": .red
        case "on-hold": .purple
        case "backlog": .gray
        case "idea": .blue
        case "legacy": .orange
        default: .gray
        }
    }
    var body: some View {
        Text(status)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

func parseISO(_ s: String) -> Date? {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: s)
}

func shortDate(_ iso: String) -> String {
    parseISO(iso)?.formatted(.dateTime.month(.abbreviated).day()) ?? iso
}

func longDate(_ iso: String) -> String {
    parseISO(iso)?.formatted(date: .complete, time: .omitted) ?? iso
}

/// Amounts in the phone's local currency (receipts store plain numbers).
func money(_ amount: Double) -> String {
    amount.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
}

/// Inline markdown (bold, italics, links, code) with line breaks and list dashes preserved.
func markdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(s)
}
