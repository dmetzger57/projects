import SwiftUI
import ProjKitCore

struct TextEditSheet: View {
    let title: String
    let initial: String
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
                    Text("Markdown: **bold**, *italic*, `- item` for lists.")
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                }
        }
        .onAppear { text = initial; focused = true }
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

    private var parsedAmount: Double? {
        let cleaned = amount.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : Double(cleaned)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Description", text: $desc)
                    TextField("Vendor", text: $vendor)
                    TextField("Amount", text: $amount).decimalField()
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                } footer: {
                    let name = Ops.receiptFileName(description: desc.isEmpty ? (vendor.isEmpty ? "Receipt" : vendor) : desc,
                                                   date: ISODate.string(date), ext: pending.fileExtension)
                    Text("Saved as Receipts/\(ISODate.string(date).prefix(4))/\(name)")
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
                    ForEach(projectStatuses.filter { $0 != "closed" }, id: \.self) { Text($0).tag($0) }
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
        .onAppear { if area.isEmpty { area = model.areas.first ?? "" } }
    }
}
