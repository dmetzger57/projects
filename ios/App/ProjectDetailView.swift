import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import ProjKitCore

struct TextEdit: Identifiable {
    enum Kind { case section(String), note, taskNote(task: Int, index: Int?) }   // index nil = new task note
    let kind: Kind
    let initial: String
    var id: String {
        switch kind {
        case let .section(s): "section-\(s)"
        case .note: "note"
        case let .taskNote(t, i): "task-\(t)-note-\(i.map(String.init) ?? "new")"
        }
    }
    var title: String {
        switch kind {
        case let .section(s): s
        case .note: "New Note"
        case let .taskNote(_, i): i == nil ? "Add Task Note" : "Edit Task Note"
        }
    }
    var hint: String {
        switch kind {
        case let .taskNote(_, i): "One line, shown under the task. Markdown: **bold**, *italic*."
                                  + (i == nil ? "" : " Clear it to delete the note.")
        default: "Markdown: **bold**, *italic*, `- item` for lists."
        }
    }
}

struct FileSheet: Identifiable {
    enum Mode { case add, edit(Int) }
    let id = UUID()
    let mode: Mode
    var isLink: Bool
    var task: Int? = nil          // set when attaching to a task instead of Project Files
    var name: String = ""
    var target: String = ""
}

/// A receipt waiting for its details: either a fresh scan (`data`, saved as a new file) or an
/// existing file (`reference`, recorded by path and never copied).
struct PendingReceipt: Identifiable {
    let id = UUID()
    var data: Data? = nil
    var reference: String? = nil
    let fileExtension: String
    let suggestedName: String
}

struct ProjectDetailView: View {
    @Environment(AppModel.self) private var model
    @State var folder: String

    @State private var edit: TextEdit?
    @State private var newGoal = ""
    @State private var newTask = ""
    @State private var editingTask: ProjectTask?
    @State private var editTaskText = ""
    @State private var showAddLink = false
    @State private var importing = false
    @State private var importingDocumentsFolder = false   // the single file importer is shared
    @State private var pendingOpen: ProjectFile?           // file to open once the Documents folder is chosen
    @State private var scanning = false
    @State private var pendingReceipt: PendingReceipt?
    @State private var preview: URL?
    @State private var fileSheet: FileSheet?
    @AppStorage("showPaths") private var showPaths = false
    @Environment(\.openURL) private var openURL
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmClose = false
    @State private var confirmClearDone = false
    @FocusState private var goalFieldFocused: Bool

    var body: some View {
        if let p = model.project(folder) {
            content(p)
        } else {
            ContentUnavailableView("Project not found", systemImage: "questionmark.folder",
                                   description: Text("It may have been renamed or moved on another device."))
        }
    }

    // MARK: content

    @ViewBuilder
    private func content(_ p: Project) -> some View {
        if model.isToday(p) { todayContent(p) } else { projectContent(p) }
    }

    /// Today: just its task list (copied tasks show where they came from).
    private func todayContent(_ p: Project) -> some View {
        let done = p.taskProgress.done
        return List {
            Section {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
            tasks(p)
            if p.tasks.isEmpty {
                Section {
                    Label("Swipe right on a task in any project (or long-press › Copy to Today) to add it here.",
                          systemImage: "sun.max")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Today")
        .refreshable { await model.reload() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear Done") { confirmClearDone = true }
                    .disabled(done == 0)
            }
        }
        .confirmationDialog("Remove \(done) done task\(done == 1 ? "" : "s") from Today?", isPresented: $confirmClearDone,
                            titleVisibility: .visible) {
            Button("Clear Done", role: .destructive) { Task { await model.perform { try Ops.clearTodayDone($0) } } }
        } message: {
            Text("Their originals stay in their projects.")
        }
        .sheet(item: $edit) { e in
            TextEditSheet(title: e.title, initial: e.initial, hint: e.hint) { text in await saveTextEdit(e, p, text) }
        }
        .sheet(item: $fileSheet) { s in fileEntrySheet(s, p) }
        .quickLookPreview($preview)
        .alert("Edit Task", isPresented: Binding(get: { editingTask != nil }, set: { if !$0 { editingTask = nil } })) {
            editTaskAlertContent(p)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result else { return }
            Task {
                let ok = await model.setDocumentsFolder(url)
                if let f = pendingOpen { pendingOpen = nil; if ok { open(f) } }
            }
        }
        .alert("Allow Access to Documents", isPresented: Binding(get: { pendingOpen != nil && !importing },
                                                                set: { if !$0 && !importing { pendingOpen = nil } })) {
            Button("Choose Documents Folder") { importing = true }
            Button("Cancel", role: .cancel) { pendingOpen = nil }
        } message: {
            Text("To open “\(pendingOpen?.name ?? "this file")”, choose iCloud Drive › Documents.")
        }
    }

    @ViewBuilder
    private func projectContent(_ p: Project) -> some View {
        let closed = model.isClosed(p)
        List {
            if p.isLegacy {
                Section {
                    Label("This project has no README.md yet. Run `proj migrate` on the Mac.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else {
                overview(p, closed: closed)
                textSection(p, "Description")
                goals(p)
                tasks(p)
                notes(p)
                ForEach(ReadmeBody.editableSections.filter { $0 != "Description" }, id: \.self) { name in
                    if name == "Project Files" { projectFiles(p) } else { textSection(p, name) }
                }
                links(p)
                receipts(p)
            }
        }
        .navigationTitle(p.title)
        .inlineTitle()
        .refreshable { await model.reload() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { actionsMenu(p, closed: closed) }
        }
        .sheet(item: $edit) { e in
            TextEditSheet(title: e.title, initial: e.initial, hint: e.hint) { text in await saveTextEdit(e, p, text) }
        }
        .sheet(isPresented: $showAddLink) {
            AddLinkSheet { url, title in await model.perform { try Ops.addLink($0, p, url: url, title: title) } }
        }
        .sheet(item: $pendingReceipt) { r in
            ReceiptDetailsSheet(pending: r) { desc, vendor, amount, date in
                await model.perform {
                    if let ref = r.reference {
                        try Ops.addReceiptReference($0, p, path: ref, amount: amount, vendor: vendor, date: date)
                    } else if let data = r.data {
                        try Ops.addReceipt($0, p, data: data, fileExtension: r.fileExtension, description: desc,
                                           amount: amount, vendor: vendor, date: date)
                    }
                }
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: importingDocumentsFolder ? [.folder] : [.pdf, .image]) { result in
            guard case let .success(url) = result else { return }
            if importingDocumentsFolder {
                importingDocumentsFolder = false
                Task {
                    let ok = await model.setDocumentsFolder(url)
                    if let f = pendingOpen { pendingOpen = nil; if ok { open(f) } }
                }
                return
            }
            // The picked file is the source of truth: record where it is, never copy it.
            guard let ws = model.workspace else { return }
            do {
                let ref = try Ops.receiptReference(ws, fileURL: url, documentsRoot: model.documentsRoot)
                model.rememberFile(url, as: ref)          // lets it open later without re-picking
                pendingReceipt = PendingReceipt(reference: ref, fileExtension: url.pathExtension,
                                                suggestedName: url.deletingPathExtension().lastPathComponent)
            } catch {
                model.errorMessage = "Can't use \(url.lastPathComponent) as a receipt: \(error.localizedDescription). "
                    + "Pick a file in iCloud Drive › Documents."
            }
        }
        .alert("Allow Access to Documents", isPresented: Binding(get: { pendingOpen != nil && !importing },
                                                                set: { if !$0 && !importing { pendingOpen = nil } })) {
            Button("Choose Documents Folder") { importingDocumentsFolder = true; importing = true }
            Button("Cancel", role: .cancel) { pendingOpen = nil }
        } message: {
            Text("To open “\(pendingOpen?.name ?? "this file")”, choose iCloud Drive › Documents. Proj remembers it for all Project Files.")
        }
        .sheet(item: $fileSheet) { s in fileEntrySheet(s, p) }
        .documentScanner(isPresented: $scanning) { pdf in
            pendingReceipt = PendingReceipt(data: pdf, fileExtension: "pdf", suggestedName: "")
        }
        .quickLookPreview($preview)
        .alert("Rename Project", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = renameText
                Task {
                    if let q = await model.perform({ try Ops.rename($0, p, to: name) }) { folder = q.folderName }
                }
            }
        } message: {
            Text("Renames the folder and the title.")
        }
        .alert("Edit Task", isPresented: Binding(get: { editingTask != nil },
                                                 set: { if !$0 { editingTask = nil } })) {
            editTaskAlertContent(p)
        }
        .confirmationDialog("Close “\(p.title)”?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close Project") { Task { await model.perform { try Ops.close($0, p) } } }
        } message: {
            Text("It moves to “2 - Closed” and keeps its area so it can be reopened.")
        }
    }

    // MARK: shared by the project and Today layouts

    private func saveTextEdit(_ e: TextEdit, _ p: Project, _ text: String) async {
        switch e.kind {
        case let .section(name): await model.perform { try Ops.setSection($0, p, name, text) }
        case .note: await model.perform { try Ops.addNote($0, p, text) }
        case let .taskNote(task, nil): await model.perform { try Ops.addTaskNote($0, p, task: task, text: text) }
        case let .taskNote(task, index?):
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {   // emptied = delete
                await model.perform { try Ops.removeTaskNote($0, p, task: task, index: index) }
            } else {
                await model.perform { try Ops.editTaskNote($0, p, task: task, index: index, text: text) }
            }
        }
    }

    private func fileEntrySheet(_ s: FileSheet, _ p: Project) -> some View {
        FileEntrySheet(sheet: s, documentsRoot: model.documentsRoot) { name, target in
            if let task = s.task {
                return await model.perform { try Ops.addTaskFile($0, p, task: task, target: target, name: name) } != nil
            }
            switch s.mode {
            case .add:
                return await model.perform { try Ops.addFile($0, p, target: target, name: name) } != nil
            case let .edit(i):
                return await model.perform { try Ops.editFile($0, p, index: i, name: name, target: target) } != nil
            }
        }
    }

    @ViewBuilder
    private func editTaskAlertContent(_ p: Project) -> some View {
        TextField("Task", text: $editTaskText)
        Button("Cancel", role: .cancel) {}
        Button("Save") {
            guard let t = editingTask else { return }
            let text = editTaskText
            Task { await model.perform { try Ops.editTask($0, p, index: t.index, text: text) } }
        }
    }

    private func copyToToday(_ p: Project, _ t: ProjectTask) {
        Task { await model.perform { try Ops.copyToToday($0, p, index: t.index) } }
    }

    private func actionsMenu(_ p: Project, closed: Bool) -> some View {
        Menu {
            Button { renameText = p.title; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                .disabled(p.isLegacy)
            if closed {
                Menu {
                    ForEach(model.areas, id: \.self) { area in
                        Button(area) { Task { await model.perform { try Ops.reopen($0, p, area: area) } } }
                    }
                } label: { Label("Reopen in…", systemImage: "arrow.uturn.backward") }
            } else {
                Button(role: .destructive) { confirmClose = true } label: { Label("Close Project", systemImage: "archivebox") }
                    .disabled(p.isLegacy)
            }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
    }

    // MARK: sections

    private func overview(_ p: Project, closed: Bool) -> some View {
        Section {
            LabeledContent("Area", value: model.displayArea(p))
            if closed {
                LabeledContent("Status") { StatusBadge(status: "closed") }
                if let c = p.closedOn { LabeledContent("Closed", value: longDate(c)) }
            } else {
                Picker("Status", selection: Binding(
                    get: { p.status },
                    set: { new in Task { await model.perform { try Ops.setStatus($0, p, new) } } })) {
                    ForEach(projectStatuses.filter { $0 != "closed" }, id: \.self) { Text($0).tag($0) }
                }
            }
            if let c = p.created { LabeledContent("Created", value: longDate(c)) }
        }
    }

    private func goals(_ p: Project) -> some View {
        let (done, total) = p.goalProgress
        return Section {
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total))
            }
            ForEach(p.goals) { g in
                Button {
                    Task { await model.perform { try Ops.setGoal($0, p, index: g.index, done: !g.done) } }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: g.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(g.done ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.text)
                                .strikethrough(g.done)
                                .foregroundStyle(g.done ? .secondary : .primary)
                            if let d = g.doneOn { Text(shortDate(d)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(g.done ? .isSelected : [])
                .contextMenu {
                    Button {
                        Task { await model.perform { try Ops.setGoal($0, p, index: g.index, done: !g.done) } }
                    } label: {
                        Label(g.done ? "Mark Not Done" : "Mark Done", systemImage: g.done ? "circle" : "checkmark.circle")
                    }
                    Button(role: .destructive) {
                        Task { await model.perform { try Ops.removeGoal($0, p, index: g.index) } }
                    } label: { Label("Delete Goal", systemImage: "trash") }
                }
            }
            .onDelete { idx in
                // delete from the end so earlier indices stay valid
                let indices = idx.map { p.goals[$0].index }.sorted(by: >)
                Task { await model.perform { ws in for i in indices { try Ops.removeGoal(ws, p, index: i) } } }
            }
            TextField("Add a goal", text: $newGoal)
                .focused($goalFieldFocused)
                .submitLabel(.done)
                .onSubmit {
                    let text = newGoal
                    newGoal = ""
                    Task { await model.perform { try Ops.addGoal($0, p, text) } }
                }
        } header: {
            HStack {
                Text("Goals")
                Spacer()
                if total > 0 { Text("\(done)/\(total)") }
            }
        }
    }

    private func tasks(_ p: Project) -> some View {
        let (done, total) = p.taskProgress
        let isToday = model.isToday(p)
        let inToday = isToday ? [] : model.todayIDs
        return Section {
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total)).tint(.blue)
            }
            ForEach(p.tasks) { t in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button {
                        Task { await model.perform { try Ops.setTask($0, p, index: t.index, done: !t.done) } }
                    } label: {
                        Image(systemName: t.done ? "checkmark.square.fill" : "square")
                            .foregroundStyle(t.done ? Color.accentColor : .secondary)
                            .imageScale(.large)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t.done ? "Mark “\(t.text)” not done" : "Mark “\(t.text)” done")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(markdown(t.text))
                            .strikethrough(t.done)
                            .foregroundStyle(t.done ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { startEditing(t) }
                            .accessibilityHint("Double-tap to edit")
                        if isToday, let src = model.taskSource(t.linkID) {
                            Text("from \(src.title)").font(.caption).foregroundStyle(.secondary)
                        } else if !isToday, let id = t.linkID, inToday.contains(id) {
                            Label("In Today", systemImage: "sun.max.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                                .accessibilityLabel("In Today. Ticking it here or in Today ticks both.")
                        }
                        ForEach(t.notes) { n in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("–").accessibilityHidden(true)
                                Text(markdown(n.text))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)
                            .contentShape(Rectangle())
                            .onTapGesture { edit = TextEdit(kind: .taskNote(task: t.index, index: n.index), initial: n.text) }
                            .contextMenu {
                                Button { edit = TextEdit(kind: .taskNote(task: t.index, index: n.index), initial: n.text) } label: {
                                    Label("Edit Note", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    Task { await model.perform { try Ops.removeTaskNote($0, p, task: t.index, index: n.index) } }
                                } label: { Label("Delete Note", systemImage: "trash") }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Note: \(n.text)")
                            .accessibilityHint("Double-tap to edit")
                        }
                        ForEach(t.files) { f in
                            Button { open(f) } label: {
                                Label(f.name, systemImage: f.isURL ? "link" : "paperclip")
                                    .font(.callout)
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityHint(f.isURL ? "Opens the link" : "Opens the file")
                        }
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if !isToday && !(t.linkID.map(inToday.contains) ?? false) {
                        Button { copyToToday(p, t) } label: { Label("Today", systemImage: "sun.max") }
                            .tint(.orange)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { await model.perform { try Ops.removeTask($0, p, index: t.index) } }
                    } label: { Label(isToday ? "Remove" : "Delete", systemImage: "trash") }
                    Button { startEditing(t) } label: { Label("Edit", systemImage: "pencil") }
                        .tint(.accentColor)
                }
                .contextMenu {
                    Button { startEditing(t) } label: { Label("Edit", systemImage: "pencil") }
                    if !isToday {
                        if t.linkID.map(inToday.contains) ?? false {
                            Label("In Today", systemImage: "sun.max.fill")
                        } else {
                            Button { copyToToday(p, t) } label: { Label("Copy to Today", systemImage: "sun.max") }
                        }
                    }
                    Section("Notes") {
                        Button { edit = TextEdit(kind: .taskNote(task: t.index, index: nil), initial: "") } label: {
                            Label("Add Note…", systemImage: "note.text.badge.plus")
                        }
                        if !t.notes.isEmpty {
                            Menu {
                                ForEach(t.notes) { n in
                                    Button(role: .destructive) {
                                        Task { await model.perform { try Ops.removeTaskNote($0, p, task: t.index, index: n.index) } }
                                    } label: { Text(n.text) }
                                }
                            } label: { Label("Delete Note", systemImage: "minus.circle") }
                        }
                    }
                    Section("Attachments") {
                        Button { fileSheet = FileSheet(mode: .add, isLink: false, task: t.index) } label: {
                            Label("Attach File…", systemImage: "paperclip")
                        }
                        Button { fileSheet = FileSheet(mode: .add, isLink: true, task: t.index) } label: {
                            Label("Attach Link…", systemImage: "link.badge.plus")
                        }
                        if !t.files.isEmpty {
                            Menu {
                                ForEach(t.files) { f in
                                    Button(role: .destructive) {
                                        Task { await model.perform { try Ops.removeTaskFile($0, p, task: t.index, index: f.index) } }
                                    } label: { Label(f.name, systemImage: f.isURL ? "link" : "doc") }
                                }
                            } label: { Label("Remove Attachment", systemImage: "minus.circle") }
                        }
                    }
                    if total > 1 {
                        Section("Move") {
                            Button { move(p, t.index, to: 0) } label: { Label("Move to Top", systemImage: "arrow.up.to.line") }
                                .disabled(t.index == 0)
                            Button { move(p, t.index, to: t.index - 1) } label: { Label("Move Up", systemImage: "arrow.up") }
                                .disabled(t.index == 0)
                            Button { move(p, t.index, to: t.index + 1) } label: { Label("Move Down", systemImage: "arrow.down") }
                                .disabled(t.index == total - 1)
                            Button { move(p, t.index, to: total - 1) } label: { Label("Move to Bottom", systemImage: "arrow.down.to.line") }
                                .disabled(t.index == total - 1)
                        }
                    }
                    Button(role: .destructive) {
                        Task { await model.perform { try Ops.removeTask($0, p, index: t.index) } }
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
            .onMove { source, destination in
                // SwiftUI gives the destination as an offset in the list *before* removal
                guard let from = source.first else { return }
                move(p, from, to: destination > from ? destination - 1 : destination)
            }
            TextField("Add a task", text: $newTask)
                .submitLabel(.done)
                .onSubmit {
                    let text = newTask
                    newTask = ""
                    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    Task { await model.perform { try Ops.addTask($0, p, text) } }
                }
        } header: {
            HStack {
                Text("Tasks")
                Spacer()
                if total > 0 { Text("\(done)/\(total)") }
            }
        }
    }

    private func move(_ p: Project, _ from: Int, to: Int) {
        guard from != to else { return }
        Task { await model.perform { try Ops.moveTask($0, p, from: from, to: to) } }
    }

    private func startEditing(_ t: ProjectTask) {
        editTaskText = t.text
        editingTask = t
    }

    private func notes(_ p: Project) -> some View {
        Section("Notes") {
            Button { edit = TextEdit(kind: .note, initial: "") } label: {
                Label("Add Note", systemImage: "square.and.pencil")
            }
            ForEach(p.notes.reversed().filter { !$0.text.isEmpty }) { n in
                VStack(alignment: .leading, spacing: 4) {
                    Text(longDate(n.date)).font(.subheadline.weight(.semibold))
                    Text(markdown(n.text)).textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func projectFiles(_ p: Project) -> some View {
        Section {
            ForEach(p.files) { f in
                Button { open(f) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: f.isURL ? "link" : "doc")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name).foregroundStyle(Color.accentColor)
                            if showPaths {
                                Text(displayPath(f)).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .lineLimit(4).textSelection(.enabled)
                            }
                        }
                    }
                }
                .accessibilityHint(f.isURL ? "Opens the link" : "Opens the file")
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { await model.perform { try Ops.removeFile($0, p, index: f.index) } }
                    } label: { Label("Remove", systemImage: "trash") }
                    Button { editFile(f) } label: { Label("Edit", systemImage: "pencil") }.tint(.accentColor)
                }
                .contextMenu {
                    Button { open(f) } label: { Label("Open", systemImage: f.isURL ? "safari" : "doc.text.magnifyingglass") }
                    Button { editFile(f) } label: { Label("Edit", systemImage: "pencil") }
                    Button { copyToClipboard(f.target) } label: {
                        Label(f.isURL ? "Copy URL" : "Copy Path", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        Task { await model.perform { try Ops.removeFile($0, p, index: f.index) } }
                    } label: { Label("Remove Link", systemImage: "trash") }
                }
            }
            let other = p.filesOtherText
            if !other.isEmpty {
                Text(markdown(other)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Menu {
                Button { fileSheet = FileSheet(mode: .add, isLink: false) } label: { Label("Add File…", systemImage: "doc.badge.plus") }
                Button { fileSheet = FileSheet(mode: .add, isLink: true) } label: { Label("Add Link…", systemImage: "link.badge.plus") }
                Divider()
                Button { edit = TextEdit(kind: .section("Project Files"), initial: p.section("Project Files") ?? "") } label: {
                    Label("Edit as Text", systemImage: "text.alignleft")
                }
            } label: {
                Label("Add File or Link", systemImage: "plus.circle")
            }
        } header: {
            HStack {
                Text("Project Files")
                Spacer()
                if !p.files.isEmpty {
                    Button(showPaths ? "Hide Paths" : "Show Paths") { showPaths.toggle() }
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                }
            }
        }
    }

    private func editFile(_ f: ProjectFile) {
        fileSheet = FileSheet(mode: .edit(f.index), isLink: f.isURL, name: f.name, target: f.target)
    }

    private func open(_ f: ProjectFile) {
        if f.isURL {
            if let u = URL(string: f.target) { openURL(u) } else { model.errorMessage = "Not a valid URL: \(f.target)" }
            return
        }
        guard let url = model.fileURL(for: f) else {
            if model.documentsRoot == nil {
                pendingOpen = f              // ask for the Documents folder, then open
            } else {
                model.errorMessage = "Can't open \(f.target)"
            }
            return
        }
        Task {
            if let ready = await model.prepareForViewing(url) {
                preview = ready
            } else {
                model.errorMessage = "Couldn't open “\(f.name)”. Check that \(displayPath(f)) exists, or try again once iCloud has downloaded it."
            }
        }
    }

    /// Full location as the user sees it in the Files app.
    private func displayPath(_ f: ProjectFile) -> String {
        f.isURL ? f.target : "iCloud Drive › " + f.target.split(separator: "/").joined(separator: " › ")
    }

    private func textSection(_ p: Project, _ name: String) -> some View {
        let text = p.section(name) ?? ""
        return Section {
            if text.isEmpty {
                Text("Nothing yet").foregroundStyle(.secondary).italic()
            } else {
                Text(markdown(text)).textSelection(.enabled)
            }
        } header: {
            HStack {
                Text(name)
                Spacer()
                Button("Edit") { edit = TextEdit(kind: .section(name), initial: text) }
                    .font(.caption.weight(.semibold))
                    .textCase(nil)
            }
        }
    }

    private func links(_ p: Project) -> some View {
        Section("Links") {
            ForEach(p.links) { l in
                if let url = URL(string: l.url), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    Link(destination: url) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l.title)
                            Text(url.host() ?? l.url).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(l.title)
                }
            }
            .onDelete { idx in
                let indices = idx.map { p.links[$0].index }.sorted(by: >)
                Task { await model.perform { ws in for i in indices { try Ops.removeLink(ws, p, index: i) } } }
            }
            Button { showAddLink = true } label: { Label("Add Link", systemImage: "link.badge.plus") }
        }
    }

    private func receipts(_ p: Project) -> some View {
        Section {
            ForEach(p.receipts) { r in
                Button {
                    guard let url = model.receiptURL(for: r) else {
                        model.errorMessage = r.path.hasPrefix("Documents/")
                            ? "Choose iCloud Drive › Documents in Settings to view \(r.fileName)."
                            : "Choose the Receipts folder in Settings to view receipts."
                        return
                    }
                    Task { preview = await model.prepareForViewing(url) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.fileName).foregroundStyle(.primary)
                        Text([r.date.map(shortDate), r.vendor, r.amount.map(money)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { idx in
                let indices = idx.map { p.receipts[$0].index }.sorted(by: >)
                Task { await model.perform { ws in for i in indices { try Ops.removeReceipt(ws, p, index: i) } } }
            }
            Menu {
                if DocumentScanner.isAvailable {
                    Button { scanning = true } label: { Label("Scan Document", systemImage: "doc.viewfinder") }
                }
                Button { importingDocumentsFolder = false; importing = true } label: { Label("Choose File", systemImage: "folder") }
            } label: {
                Label("Add Receipt", systemImage: "plus.circle")
            }
            .disabled(model.receiptsRoot == nil)
            if model.receiptsRoot == nil {
                Text("Choose the Receipts folder in Settings to add receipts.").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Receipts")
                Spacer()
                if !p.receipts.isEmpty { Text(money(p.totalCost)) }
            }
        } footer: {
            if !p.receipts.isEmpty { Text("Swipe to detach. The files themselves are not touched.") }
        }
    }
}
