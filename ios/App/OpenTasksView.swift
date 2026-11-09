import SwiftUI
import ProjKitCore

/// The Open Tasks tab (a peer of Today): every open task of every project that isn't closed, grouped by
/// project in overview order. Tap a task's circle to tick it done (in its project and its Today copy, with
/// Undo); tap Select, then tasks, to Copy them to Today (linked, like the ☀ action).
/// Each task can also be edited, given a note, photo, link or Apple Reminder here (the ⋯ menu, a left swipe
/// or long-press), have its links and photos removed, or be opened in its project (scrolled to and highlighted).
/// Mirrors the web UI's /tasks page and `proj tasks`.
struct OpenTasksView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Set<Pick> = []
    @State private var selecting = false                  // Select mode: circles pick tasks for Copy to Today
    @State private var completing: Set<Pick> = []         // ticked, waiting for the write (shows the checkmark)
    @State private var search = ""
    @State private var status: Status?

    /// The line above the list after an action: what happened, and for a tick, how to undo it.
    struct Status: Equatable {
        enum Kind { case copied, completed }
        let kind: Kind
        let text: String
        var undo: Undo? = nil
        struct Undo: Equatable { let folder: String; let taskText: String }
    }
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
                if let status { Section { statusRow(status) } }
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
                if selecting {
                    ToolbarItem(placement: .primaryAction) {
                        Button { Task { await copySelected() } } label: {
                            Label(selected.isEmpty ? "Copy to Today" : "Copy \(selected.count) to Today", systemImage: "sun.max")
                                .labelStyle(.titleAndIcon)
                        }
                        .disabled(selected.isEmpty)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { selecting = false; selected = [] }
                    }
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        Button { selecting = true } label: { Label("Select", systemImage: "checklist") .labelStyle(.titleAndIcon) }
                            .help("Select tasks to copy to Today")
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
        if !t.files.isEmpty || !t.photos.isEmpty {
            Divider()
            let p = g.project
            if !t.files.isEmpty {       // same as the project page's "Remove Attachment"
                Menu {
                    ForEach(t.files) { f in
                        Button(role: .destructive) {
                            Task { await model.perform { try Ops.removeTaskFile($0, p, task: t.index, index: f.index) } }
                        } label: { Label(f.name, systemImage: f.isURL ? "link" : "doc") }
                    }
                } label: { Label("Remove Link", systemImage: "minus.circle") }
            }
            if !t.photos.isEmpty {      // deletes the file too, like Delete Photo on the project page
                Menu {
                    ForEach(t.photos) { ph in
                        Button(role: .destructive) {
                            Task { await model.perform { try Ops.removePhoto($0, p, index: ph.index, task: t.index) } }
                        } label: {
                            Label(ph.note.isEmpty ? "Photo \(ph.index + 1)" : "Photo \(ph.index + 1): \(ph.note)", systemImage: "photo")
                        }
                    }
                } label: { Label("Delete Photo", systemImage: "trash") }
            }
        }
        Divider()
        Button { complete(g, t) } label: { Label("Mark Done", systemImage: "checkmark.circle") }
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
            if selecting && !picks.isEmpty {
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
        let ticking = completing.contains(pick)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
        Button {
            if selecting {
                guard !today else { return }
                if on { selected.remove(pick) } else { selected.insert(pick) }
            } else {
                complete(g, t)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Group {
                    if selecting {      // selection: a filled blue check, or ☀ when it's already in Today
                        Image(systemName: today ? "sun.max.fill" : (on ? "checkmark.circle.fill" : "circle.dashed"))
                            .foregroundStyle(today ? Color.orange : (on ? Color.accentColor : Color.secondary))
                    } else {            // the task's own checkbox, like on the project page
                        Image(systemName: ticking ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(ticking ? Color.green : Color.secondary)
                    }
                }
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
        .accessibilityAddTraits(selecting && on ? .isSelected : [])
        .accessibilityHint(selecting ? (today ? "" : (on ? "Double-tap to deselect" : "Double-tap to select"))
                                     : "Double-tap to mark done")
        Menu { actions(g, t, pick) } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Edit; add a note, photo, link or reminder; remove links and photos")
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
            Button { complete(g, t) } label: { Label("Done", systemImage: "checkmark") }
                .tint(.green)
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
        selecting = false
        let skipped = pairs.count - added
        show(Status(kind: .copied, text: "Copied \(added) task\(added == 1 ? "" : "s") to Today"
                    + (skipped > 0 ? " (\(skipped) already there)" : "")))
    }

    /// Ticks a task done, the same as its checkbox on the project page: its Today copy is ticked too, and
    /// ticking a project's last open task makes it Completed (On Hold). It then leaves this list.
    private func complete(_ g: OpenTaskGroup, _ t: ProjectTask) {
        let pick = Pick(folder: g.project.folderName, index: t.index)
        guard !completing.contains(pick) else { return }
        withAnimation { _ = completing.insert(pick) }
        let p = g.project
        Task {
            try? await Task.sleep(for: .milliseconds(250))      // let the checkmark show
            let ok = await model.perform { try Ops.setTask($0, p, index: t.index, done: true) } != nil
            completing.remove(pick)
            selected.remove(pick)
            if ok {
                show(Status(kind: .completed, text: "Done: \(t.text) · \(p.title)",
                            undo: .init(folder: p.folderName, taskText: t.text)), seconds: 8)
            }
        }
    }

    /// Unticks a task just ticked here. A ticked task settles among the done ones, so it's found by its text
    /// (the first done task with that text is the one ticked last).
    private func undo(_ u: Status.Undo) async {
        status = nil
        guard let p = model.project(u.folder),
              let t = p.tasks.first(where: { $0.done && $0.text == u.taskText }) else {
            model.errorMessage = "Couldn't find “\(u.taskText)” to undo. Untick it on its project page."
            return
        }
        await model.perform { try Ops.setTask($0, p, index: t.index, done: false) }
    }

    private func show(_ s: Status, seconds: Double = 4) {
        withAnimation { status = s }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if status == s { withAnimation { status = nil } }
        }
    }

    @ViewBuilder
    private func statusRow(_ s: Status) -> some View {
        HStack {
            switch s.kind {
            case .copied: Label(s.text, systemImage: "sun.max.fill").foregroundStyle(.orange)
            case .completed: Label(s.text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Spacer()
            if let u = s.undo {
                Button("Undo") { Task { await undo(u) } }
                    .buttonStyle(.borderless)
                    .font(.body.weight(.semibold))
            }
        }
    }
}
