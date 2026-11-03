import SwiftUI
import ProjKitCore

struct SettingsView: View {
    enum Target { case projects, receipts }
    @Environment(AppModel.self) private var model
    @State private var picking: Target?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    folderRow("Projects", model.projectsRoot, target: .projects)
                    folderRow("Receipts", model.receiptsRoot, target: .receipts)
                } header: {
                    Text("Folders")
                } footer: {
                    Text("Pick iCloud Drive › Documents › Projects and › Receipts. Proj edits the files in place; changes appear in `proj` on the Mac.")
                }
                Section("Status") {
                    LabeledContent("Projects", value: "\(model.projects.count)")
                    LabeledContent("Ideas", value: "\(model.ideas.count)")
                    if let d = model.lastLoaded {
                        LabeledContent("Refreshed", value: d.formatted(date: .omitted, time: .shortened))
                    }
                    Button("Refresh Now") { Task { await model.reload() } }
                }
                Section {
                    Text("Receipts saved from the iPhone can't get the Finder tag “receipt”. Run `proj lint --fix` on the Mac to add it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: { Text("Note") }
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                          allowedContentTypes: [.folder]) { result in
                guard case let .success(url) = result, let target = picking else { return }
                Task {
                    switch target {
                    case .projects: await model.setProjectsFolder(url)
                    case .receipts: await model.setReceiptsFolder(url)
                    }
                }
            }
        }
    }

    private func folderRow(_ label: String, _ url: URL?, target: Target) -> some View {
        Button { picking = target } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).foregroundStyle(.primary)
                    Text(url.map(displayPath) ?? "Not chosen")
                        .font(.caption)
                        .foregroundStyle(url == nil ? .red : .secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                Text("Change").font(.callout)
            }
        }
    }

    private func displayPath(_ url: URL) -> String {
        let parts = url.pathComponents
        if let i = parts.lastIndex(of: "com~apple~CloudDocs") {
            return (["iCloud Drive"] + parts[(i + 1)...]).joined(separator: " › ")
        }
        return parts.suffix(3).joined(separator: " › ")
    }
}
