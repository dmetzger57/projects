import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import ProjKitCore

struct TextEdit: Identifiable {
    enum Kind { case section(String), note }
    let kind: Kind
    let initial: String
    var id: String {
        switch kind {
        case let .section(s): "section-\(s)"
        case .note: "note"
        }
    }
    var title: String {
        switch kind {
        case let .section(s): s
        case .note: "New Note"
        }
    }
}

struct PendingReceipt: Identifiable {
    let id = UUID()
    let data: Data
    let fileExtension: String
    let suggestedName: String
}

struct ProjectDetailView: View {
    @Environment(AppModel.self) private var model
    @State var folder: String

    @State private var edit: TextEdit?
    @State private var newGoal = ""
    @State private var showAddLink = false
    @State private var importingReceipt = false
    @State private var scanning = false
    @State private var pendingReceipt: PendingReceipt?
    @State private var preview: URL?
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmClose = false
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
        let closed = model.isClosed(p)
        List {
            if p.isLegacy {
                Section {
                    Label("This project has no README.md yet. Run `proj migrate` on the Mac.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else {
                overview(p, closed: closed)
                goals(p)
                notes(p)
                ForEach(ReadmeBody.editableSections, id: \.self) { name in textSection(p, name) }
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
            TextEditSheet(title: e.title, initial: e.initial) { text in
                switch e.kind {
                case let .section(name): await model.perform { try Ops.setSection($0, p, name, text) }
                case .note: await model.perform { try Ops.addNote($0, p, text) }
                }
            }
        }
        .sheet(isPresented: $showAddLink) {
            AddLinkSheet { url, title in await model.perform { try Ops.addLink($0, p, url: url, title: title) } }
        }
        .sheet(item: $pendingReceipt) { r in
            ReceiptDetailsSheet(pending: r) { desc, vendor, amount, date in
                await model.perform {
                    try Ops.addReceipt($0, p, data: r.data, fileExtension: r.fileExtension, description: desc,
                                       amount: amount, vendor: vendor, date: date)
                }
            }
        }
        .fileImporter(isPresented: $importingReceipt, allowedContentTypes: [.pdf, .image]) { result in
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                pendingReceipt = PendingReceipt(data: data, fileExtension: url.pathExtension.isEmpty ? "pdf" : url.pathExtension,
                                                suggestedName: url.deletingPathExtension().lastPathComponent)
            } catch {
                model.errorMessage = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
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
        .confirmationDialog("Close “\(p.title)”?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close Project") { Task { await model.perform { try Ops.close($0, p) } } }
        } message: {
            Text("It moves to “2 - Closed” and keeps its area so it can be reopened.")
        }
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
                    guard let ws = model.workspace, let url = Ops.receiptURL(ws, r) else {
                        model.errorMessage = "Choose the Receipts folder in Settings to view receipts."
                        return
                    }
                    Task { preview = await model.prepareForViewing(url) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.fileName).foregroundStyle(.primary)
                        Text([r.date.map(shortDate), r.vendor, r.amount?.formatted(.currency(code: "USD"))]
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
                Button { importingReceipt = true } label: { Label("Choose File", systemImage: "folder") }
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
                if !p.receipts.isEmpty { Text(p.totalCost.formatted(.currency(code: "USD"))) }
            }
        } footer: {
            if !p.receipts.isEmpty { Text("Swipe to detach. Files stay in the Receipts folder.") }
        }
    }
}
