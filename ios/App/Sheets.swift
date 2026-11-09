import SwiftUI
import ProjKitCore

struct TextEditSheet: View {
    let title: String
    let initial: String
    var hint = "Markdown: **bold**, *italic*, `- item` for lists."
    let save: (String) async -> Void
    @State private var text = ""
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($focused)
                .padding(.horizontal, 12)
                .navigationTitle(title)
                .inlineTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            saving = true
                            Task { await save(text); dismiss() }
                        }
                        .disabled(saving || (initial.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Text(hint)
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                }
        }
        .sheetSize(width: 560, height: 420)
        .onAppear { text = initial; focused = true }
    }
}

/// Add or edit a Project Files entry: a file under Documents (typed or browsed) or a URL.
struct FileEntrySheet: View {
    let sheet: FileSheet
    let documentsRoot: URL?
    let save: (String?, String) async -> Bool
    @Environment(AppModel.self) private var model
    @State private var isLink = false
    @State private var name = ""
    @State private var target = ""
    @State private var browsing = false
    @State private var problem: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    private var isAdd: Bool { if case .add = sheet.mode { true } else { false } }

    /// The stored form of what's typed, or the reason it's not acceptable.
    private var normalized: Result<String, Error> {
        Result { try ReadmeBody.normalizeFilePath(target, documentsRoot: documentsRoot) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if isAdd {
                    Picker("Type", selection: $isLink) {
                        Text("File").tag(false)
                        Text("Link").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    if isLink {
                        TextField("https://…", text: $target, axis: .vertical).urlField()
                    } else {
                        TextField("Documents/Folder/file.pdf", text: $target, axis: .vertical).urlField()
                        Button { browsing = true } label: { Label("Browse Files…", systemImage: "folder") }
                    }
                } header: {
                    Text(isLink ? "URL" : "File")
                } footer: {
                    if !isLink { Text("Choose a file in iCloud Drive › Documents, or type its path starting with “Documents/”.") }
                }
                Section {
                    TextField(defaultName.isEmpty ? "Friendly name" : defaultName, text: $name)
                } header: {
                    Text("Name")
                } footer: {
                    Text("Shown instead of the \(isLink ? "URL" : "path"). Leave empty to use “\(defaultName.isEmpty ? "…" : defaultName)”.")
                }
                if let problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
            }
            .navigationTitle(isAdd ? (sheet.task != nil ? (isLink ? "Attach Link" : "Attach File")
                                                       : (isLink ? "Add Link" : "Add File")) : "Edit")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isAdd ? (sheet.task != nil ? "Attach" : "Add") : "Save") { submit() }
                        .disabled(saving || target.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .fileImporter(isPresented: $browsing, allowedContentTypes: [.item]) { result in
                guard case let .success(url) = result else { return }
                do {
                    target = try ReadmeBody.normalizeFilePath(url.path, documentsRoot: documentsRoot)
                    model.rememberFile(url, as: target)       // lets it open without the Documents folder
                    problem = nil
                } catch {
                    problem = "That file isn't inside iCloud Drive › Documents."
                }
            }
        }
        .sheetSize(width: 560, height: 520)
        .onAppear {
            isLink = sheet.isLink
            name = sheet.name
            target = sheet.target.isEmpty && sheet.isLink ? "https://" : sheet.target
        }
    }

    private var defaultName: String {
        (try? normalized.get()).map(ReadmeBody.defaultFileName) ?? ""
    }

    private func submit() {
        switch normalized {
        case let .failure(e):
            problem = e.localizedDescription
        case let .success(t):
            if isLink != ReadmeBody.isURL(t) {
                problem = isLink ? "Enter a full URL starting with https://" : "Enter a path starting with Documents/"
                return
            }
            saving = true
            let n = name.trimmingCharacters(in: .whitespaces)
            Task {
                if await save(n.isEmpty ? "" : n, t) { dismiss() }
                saving = false
            }
        }
    }
}

struct AddLinkSheet: View {
    let save: (String, String?) async -> Void
    @State private var url = "https://"
    @State private var title = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("URL", text: $url).urlField()
                TextField("Title (optional)", text: $title)
            }
            .navigationTitle("Add Link")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save(url, title.isEmpty ? nil : title); dismiss() } }
                        .disabled(URL(string: url)?.host() == nil)
                }
            }
        }
        .sheetSize(width: 480, height: 260)
        .presentationDetents([.medium])
    }
}

struct ReceiptDetailsSheet: View {
    let pending: PendingReceipt
    let save: (String, String?, Double?, String) async -> Void
    @State private var desc = ""
    @State private var vendor = ""
    @State private var amount = ""
    @State private var date = Date()
    @Environment(\.dismiss) private var dismiss

    /// The image, when the new receipt is a photo (not a scanned PDF or an existing file).
    private let photo: Image?

    init(pending: PendingReceipt, save: @escaping (String, String?, Double?, String) async -> Void) {
        self.pending = pending
        self.save = save
        if let data = pending.data, pending.fileExtension == "jpg" {
            #if os(iOS)
            photo = UIImage(data: data).map { Image(uiImage: $0) }
            #else
            photo = NSImage(data: data).map { Image(nsImage: $0) }
            #endif
        } else {
            photo = nil
        }
    }

    private var parsedAmount: Double? {
        let cleaned = amount.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : Double(cleaned)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let image = photo {      // a receipt from Photos: read the amount off it
                    Section {
                        image.resizable().scaledToFit()
                            .frame(maxHeight: 280).frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("The receipt photo")
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    if pending.reference == nil { TextField("Description", text: $desc) }
                    TextField("Vendor", text: $vendor)
                    TextField("Amount", text: $amount).decimalField()
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                } footer: {
                    if let ref = pending.reference {
                        Text("Links to \(ref.hasPrefix("Documents/") ? ref : "Receipts/" + ref). The file stays where it is — no copy is made.")
                    } else {
                        let name = Ops.receiptFileName(description: desc.isEmpty ? (vendor.isEmpty ? "Receipt" : vendor) : desc,
                                                       date: ISODate.string(date), ext: pending.fileExtension)
                        Text("Saved as Receipts/\(ISODate.string(date).prefix(4))/\(name)")
                    }
                }
            }
            .navigationTitle("Receipt")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await save(desc, vendor.isEmpty ? nil : vendor, parsedAmount, ISODate.string(date))
                            dismiss()
                        }
                    }
                    .disabled(!amount.isEmpty && parsedAmount == nil)
                }
            }
        }
        .sheetSize(width: 480, height: photo == nil ? 420 : 720)
        .onAppear { desc = pending.suggestedName }
    }
}

struct NewProjectSheet: View {
    let created: (String) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var area = ""
    @State private var status = "active"

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $title)
                Picker("Area", selection: $area) {
                    ForEach(model.areas, id: \.self) { Text($0).tag($0) }
                }
                Picker("Status", selection: $status) {
                    ForEach(projectStatuses.filter { $0 != "closed" }, id: \.self) { Text(statusLabel($0)).tag($0) }
                }
            }
            .navigationTitle("New Project")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let (t, a, s) = (title, area, status)
                        Task {
                            if let p = await model.perform({ try Ops.newProject($0, title: t, area: a, status: s) }) {
                                dismiss()
                                created(p.folderName)
                            }
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || area.isEmpty)
                }
            }
        }
        .sheetSize(width: 480, height: 380)
        .onAppear { if area.isEmpty { area = model.areas.first ?? "" } }
    }
}
