import SwiftUI
import ProjKitCore

/// Picks the project a task moves to: projects by area in overview order (closed ones last),
/// searchable. The task goes to the end of that project's tasks, with its notes, attachments and photos.
struct MoveTaskSheet: View {
    let task: ProjectTask
    let from: Project
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var moving = false
    @State private var selection: String?          // Mac: the selected project, moved with Move/Return

    private var groups: [(label: String, projects: [Project])] {
        let candidates = model.projects.filter { q in
            q.folderName != from.folderName && !q.isLegacy
                && (search.isEmpty || q.title.localizedCaseInsensitiveContains(search)
                    || model.displayArea(q).localizedCaseInsensitiveContains(search))
        }
        var byArea: [String: [Project]] = [:]
        var closed: [Project] = []
        for q in candidates {
            if q.status == "closed" { closed.append(q) } else { byArea[model.displayArea(q), default: []].append(q) }
        }
        let order = model.workspace?.overviewAreas(overview: model.overview) ?? byArea.keys.sorted()
        var out = order.compactMap { a in byArea[a].map { (a, model.overview.sorted($0, area: a)) } }
        out += byArea.keys.filter { !order.contains($0) }.sorted().map { ($0, byArea[$0]!) }
        if !closed.isEmpty {
            out.append(("Closed", closed.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }))
        }
        return out
    }

    #if os(macOS)
    static let help = "Click a project and then Move, or double-click it. You can also type to filter, use ↑↓, and press Return. The task goes to the end of the project’s tasks, with its notes, attachments and photos. A copy in Today stays linked."
    #else
    static let help = "It goes to the end of the project’s tasks, with its notes, attachments and photos. A copy in Today stays linked."
    #endif

    var body: some View {
        NavigationStack {
            #if os(macOS)
            macBody
            #else
            iosBody
            #endif
        }
        .sheetSize(width: 460, height: 560)
    }

    private func row(_ q: Project) -> some View {
        HStack {
            Text(q.title).foregroundStyle(.primary)
            Spacer()
            if q.status != "active" { StatusBadge(status: q.status) }
        }
        .contentShape(Rectangle())
    }

    private var emptyText: String {
        search.isEmpty ? "There’s no other project to move it to." : "No matching projects."
    }

    #if os(macOS)
    /// Mac: click a project to select it, then Move (or Return, or double-click). Buttons in Mac list
    /// rows don't get clicks reliably, and the search field keeps Return, so this uses a plain field.
    private var macBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(task.text).font(.headline)
            Text(Self.help).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Filter projects", text: $search)
                .textFieldStyle(.roundedBorder)
                .onSubmit(pickOnly)
                .onKeyPress(.downArrow) { step(1); return .handled }
                .onKeyPress(.upArrow) { step(-1); return .handled }
                .onChange(of: search) { _, _ in
                    let hits = groups.flatMap(\.projects)
                    if hits.count == 1 { selection = hits[0].folderName }
                    else if let s = selection, !hits.contains(where: { $0.folderName == s }) { selection = nil }
                }
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                        ForEach(groups, id: \.label) { g in
                            Text(g.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.top, 8)
                            ForEach(g.projects, id: \.folderName) { q in
                                let on = selection == q.folderName
                                row(q)
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .foregroundStyle(on ? Color.white : Color.primary)
                                    .background(on ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { move(to: q) }
                                    .onTapGesture { selection = q.folderName }
                                    .id(q.folderName)
                                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                                    .accessibilityAction { move(to: q) }
                            }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selection) { _, f in if let f { scroller.scrollTo(f) } }
            }
            .overlay { if groups.isEmpty { Text(emptyText).foregroundStyle(.secondary) } }
            .background(Color.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
        }
        .padding(16)
        .navigationTitle("Move Task To")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Move") { if let f = selection, let q = project(f) { move(to: q) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil || moving)
            }
        }
    }
    #else
    private var iosBody: some View {
        List {
            Section {
                Text(task.text).foregroundStyle(.secondary)
            } footer: {
                Text(Self.help)
            }
            ForEach(groups, id: \.label) { g in
                Section(g.label) {
                    ForEach(g.projects, id: \.folderName) { q in
                        Button { move(to: q) } label: { row(q) }
                            .disabled(moving)
                            .accessibilityLabel("Move to \(q.title)")
                    }
                }
            }
            if groups.isEmpty { Text(emptyText).foregroundStyle(.secondary) }
        }
        .searchable(text: $search, prompt: "Projects")
        .onSubmit(of: .search, pickOnly)
        .navigationTitle("Move Task To")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
    }
    #endif

    /// Arrow keys in the filter field move the selection through the visible projects.
    private func step(_ by: Int) {
        let all = groups.flatMap(\.projects).map(\.folderName)
        guard !all.isEmpty else { return }
        let i = selection.flatMap { all.firstIndex(of: $0) } ?? (by > 0 ? -1 : all.count)
        selection = all[min(max(i + by, 0), all.count - 1)]
    }

    private func project(_ folder: String) -> Project? { groups.flatMap(\.projects).first { $0.folderName == folder } }

    /// Return picks the project when the filter leaves just one.
    private func pickOnly() {
        let hits = groups.flatMap(\.projects)
        if hits.count == 1 { move(to: hits[0]) }
        else if let f = selection, let q = project(f) { move(to: q) }
    }

    private func move(to dest: Project) {
        moving = true
        let (p, i) = (from, task.index)
        Task {
            await model.perform { try Ops.moveTaskTo($0, p, index: i, to: dest) }
            dismiss()
        }
    }
}
