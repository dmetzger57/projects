import SwiftUI
import ProjKitCore

/// The Open Tasks tab (a peer of Today): every open task of every project that isn't closed, grouped by
/// project in overview order. Tap tasks to select them, then Copy to Today (linked, like the ☀ action).
/// Each task can also be edited, given a note, photo, link or Apple Reminder here (the ⋯ menu, a left swipe
/// or long-press), or opened in its project (scrolled to and highlighted).
/// Mirrors the web UI's /tasks page and `proj tasks`.
struct OpenTasksView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Set<Pick> = []
    @State private var search = ""
    @State private var copiedMessage: String?
    @State private var path = NavigationPath()
    @State private var sheet: TaskSheet?
    @State private var photoRequest: PhotoRequest?
    @State private var photoProject: Project?

    /// A task of a project, by folder and index (indexes don't change when a task is copied to Today).
    /// Also the navigation value for "open this task in its project".
    struct Pick: Hashable { let folder: String; let index: Int }

    /// A sheet for one task: edit its text, add a note, add a link, or schedule a reminder.
    struct TaskSheet: Identifiable {
        enum Kind: String { case edit, note, link, remind }
        let kind: Kind
        let project: Project
        let task: ProjectTask
        var id: String { "\(kind)-\(project.folderName)#\(task.index)" }
    }

    private var groups: [OpenTaskGroup] {
        let all = Ops.openTasks(projects: model.projects, areas: model.areas, overview: model.overview,
                                area: model.displayArea, isClosed: model.isClosed)
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.compactMap { g in
            if g.project.title.localizedCaseInsensitiveContains(q) { return g }
            let hits = g.tasks.filter { $0.text.localizedCaseInsensitiveContains(q) }
            return hits.isEmpty ? nil : OpenTaskGroup(area: g.area, project: g.project, tasks: hits)
        }
    }

    private func inToday(_ t: ProjectTask) -> Bool { t.linkID.map(model.todayIDs.contains) ?? false }

    var body: some View {
        NavigationStack(path: $path) {
            let groups = groups
            List {
                if let copiedMessage {
                    Section { Label(copiedMessage, systemImage: "sun.max.fill").foregroundStyle(.orange) }
                }
                ForEach(groups) { g in
                    Section {
                        ForEach(g.tasks) { t in row(g, t) }
                    } header: {
                        header(g)
                    }
                }
            }
            .overlay {
                if groups.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No Open Tasks" : "No Matching Tasks",
                                           systemImage: "checklist",
                                           description: Text(search.isEmpty ? "Every task of every open project is done." : "Try other words."))
                }
            }
            .searchable(text: $search, prompt: "Filter tasks or projects")
            .navigationTitle("Open Tasks")
            .refreshable { await model.reload() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await copySelected() } } label: {
                        Label(selected.isEmpty ? "Copy to Today" : "Copy \(selected.count) to Today", systemImage: "sun.max")
                            .labelStyle(.titleAndIcon)
                    }
                    .disabled(selected.isEmpty)
                }
                if !selected.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Deselect") { selected = [] }
                    }
                }
            }
            .navigationDestination(for: String.self) { ProjectDetailView(folder: $0) }
            .navigationDestination(for: Pick.self) { ProjectDetailView(folder: $0.folder, focusTask: $0.index) }
            .sheet(item: $sheet) { s in taskSheet(s) }
            .photoAdding($photoRequest) { jpeg, note, task in
                guard let p = photoProject else { return }
                await model.perform { try Ops.addPhoto($0, p, data: jpeg, ext: "jpg", note: note, task: task) }
            }
        }
        .onChange(of: model.projects) { _, _ in
            // drop picks that are no longer open (ticked or moved elsewhere)
            let open = Set(groups.flatMap { g in g.tasks.map { Pick(folder: g.project.folderName, index: $0.index) } })
            selected.formIntersection(open)
        }
    }

    @ViewBuilder
    private func taskSheet(_ s: TaskSheet) -> some View {
        let p = s.project, i = s.task.index
        switch s.kind {
        case .edit:
            TextEditSheet(title: "Edit Task", initial: s.task.text,
                          hint: "One line (line breaks become spaces). Markdown: **bold**, *italic*.") { text in
                await model.perform { try Ops.editTask($0, p, index: i, text: text) }
            }
        case .note:
            TextEditSheet(title: "Add Task Note", initial: "",
                          hint: "One line, shown under “\(s.task.text)”. Markdown: **bold**, *italic*.") { text in
                await model.perform { try Ops.addTaskNote($0, p, task: i, text: text) }
            }
        case .link:
            FileEntrySheet(sheet: FileSheet(mode: .add, isLink: true, task: i), documentsRoot: model.documentsRoot) { name, target in
                await model.perform { try Ops.addTaskFile($0, p, task: i, target: target, name: name) } != nil
            }
        case .remind:
            ReminderSheet(task: s.task, project: p)
        }
    }

    private func addPhoto(_ g: OpenTaskGroup, _ t: ProjectTask, _ source: PhotoRequest.Source) {
        photoProject = g.project
        photoRequest = PhotoRequest(task: t.index, source: source)
    }

    /// Every action for one task (the ⋯ menu and the long-press menu share it).
    @ViewBuilder
    private func actions(_ g: OpenTaskGroup, _ t: ProjectTask, _ pick: Pick) -> some View {
        Button { sheet = TaskSheet(kind: .edit, project: g.project, task: t) } label: { Label("Edit…", systemImage: "pencil") }
        Button { sheet = TaskSheet(kind: .note, project: g.project, task: t) } label: {
            Label("Add Note…", systemImage: "note.text.badge.plus")
        }
        if Camera.isAvailable {
            Button { addPhoto(g, t, .camera) } label: { Label("Take Photo…", systemImage: "camera") }
        }
        Button { addPhoto(g, t, .library) } label: { Label("Choose Photo…", systemImage: "photo.on.rectangle") }
        Button { sheet = TaskSheet(kind: .link, project: g.project, task: t) } label: {
            Label("Add Link…", systemImage: "link.badge.plus")
        }
        Button { sheet = TaskSheet(kind: .remind, project: g.project, task: t) } label: {
            Label("Add Reminder…", systemImage: "bell.badge")
        }
        Divider()
        if inToday(t) {
            Label("In Today", systemImage: "sun.max.fill")
        } else {
            Button { Task { await copy([pick]) } } label: { Label("Copy to Today", systemImage: "sun.max") }
        }
        Button { path.append(pick) } label: { Label("Open in \(g.project.title)", systemImage: "arrow.up.forward.square") }
    }

    private func header(_ g: OpenTaskGroup) -> some View {
        let picks = g.tasks.filter { !inToday($0) }.map { Pick(folder: g.project.folderName, index: $0.index) }
        let all = !picks.isEmpty && picks.allSatisfy(selected.contains)
        return HStack {
            NavigationLink(value: g.project.folderName) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(g.project.title).font(.headline).foregroundStyle(.primary)
                    Text(g.project.status == "active" ? g.area : "\(g.area) · \(statusLabel(g.project.status))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if !picks.isEmpty {
                Button(all ? "Deselect All" : "Select All") {
                    if all { selected.subtract(picks) } else { selected.formUnion(picks) }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                .accessibilityLabel(all ? "Deselect all tasks of \(g.project.title)" : "Select all tasks of \(g.project.title)")
            }
        }
        .textCase(nil)
    }

    @ViewBuilder
    private func row(_ g: OpenTaskGroup, _ t: ProjectTask) -> some View {
        let pick = Pick(folder: g.project.folderName, index: t.index)
        let today = inToday(t)
        let on = selected.contains(pick)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
        Button {
            guard !today else { return }
            if on { selected.remove(pick) } else { selected.insert(pick) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: today ? "sun.max.fill" : (on ? "checkmark.circle.fill" : "circle"))
                    .foregroundStyle(today ? Color.orange : (on ? Color.accentColor : Color.secondary))
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 3) {
                    Text(markdown(t.text)).foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if today {
                        Text("In Today").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    }
                    if let when = t.reminder {
                        Label("Reminder \(Reminders.label(when))", systemImage: "bell.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                    }
                    ForEach(t.notes) { n in
                        Text("– ").foregroundStyle(.secondary) + Text(markdown(n.text)).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    ForEach(t.files) { f in
                        Label(f.name, systemImage: f.isURL ? "link" : "paperclip")
                            .font(.callout).foregroundStyle(Color.accentColor)
                    }
                    if !t.photos.isEmpty {
                        Label(t.photos.count == 1 ? "1 photo" : "\(t.photos.count) photos", systemImage: "photo")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .tint(.primary)
        .accessibilityLabel(today ? "\(t.text), in Today" : t.text)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(today ? "" : (on ? "Double-tap to deselect" : "Double-tap to select"))
        Menu { actions(g, t, pick) } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Edit, add a note, photo, link or reminder")
        .accessibilityLabel("Actions for “\(t.text)”")
        Button { path.append(pick) } label: {
            Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Open in \(g.project.title)")
        .accessibilityLabel("Open “\(t.text)” in \(g.project.title)")
        }
        .swipeActions(edge: .trailing) {
            Button { path.append(pick) } label: { Label("Open", systemImage: "arrow.up.forward.square") }
                .tint(.teal)
            Button { sheet = TaskSheet(kind: .remind, project: g.project, task: t) } label: { Label("Remind", systemImage: "bell") }
                .tint(.purple)
            Button { sheet = TaskSheet(kind: .note, project: g.project, task: t) } label: { Label("Note", systemImage: "note.text") }
                .tint(.indigo)
            Button { sheet = TaskSheet(kind: .edit, project: g.project, task: t) } label: { Label("Edit", systemImage: "pencil") }
                .tint(.accentColor)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !today {
                Button { Task { await copy([pick]) } } label: { Label("Today", systemImage: "sun.max") }
                    .tint(.orange)
            }
        }
        .contextMenu { actions(g, t, pick) }
    }

    private func copySelected() async {
        // in list order, so Today gets them in the order shown
        let order = groups.flatMap { g in g.tasks.map { Pick(folder: g.project.folderName, index: $0.index) } }
        await copy(order.filter(selected.contains))
    }

    private func copy(_ picks: [Pick]) async {
        guard !picks.isEmpty else { return }
        let pairs = picks.compactMap { pk in model.projects.first { $0.folderName == pk.folder }.map { ($0, pk.index) } }
        let added = await model.perform { ws in try Ops.copyManyToToday(ws, pairs) }
        guard let added else { return }
        selected.subtract(picks)
        let skipped = pairs.count - added
        copiedMessage = "Copied \(added) task\(added == 1 ? "" : "s") to Today" + (skipped > 0 ? " (\(skipped) already there)" : "")
        Task {
            try? await Task.sleep(for: .seconds(4))
            copiedMessage = nil
        }
    }
}
