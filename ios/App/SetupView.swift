import SwiftUI
import ProjKitCore

/// First-run setup for a folder that isn't a projects workspace yet
/// (e.g. a family member starting with an empty iCloud Drive folder).
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var areas = ["Home", "Personal", "Work"]
    @State private var newArea = ""
    @State private var receiptsInside = true
    @State private var working = false
    @State private var picking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(model.projectsRoot?.lastPathComponent ?? "Folder", systemImage: "folder")
                        .font(.headline)
                } footer: {
                    Text("This folder isn't set up for Proj yet. Proj will add a template, a Closed folder, an idea backlog and the areas below. Nothing already in the folder is changed.")
                }

                Section {
                    ForEach(areas, id: \.self) { Text($0) }
                        .onDelete { areas.remove(atOffsets: $0) }
                    TextField("Add an area", text: $newArea)
                        .submitLabel(.done)
                        .onSubmit(addArea)
                } header: {
                    Text("Areas")
                } footer: {
                    Text("Areas group your projects, e.g. Home, Garden, Finances. Swipe to remove; you can add more later.")
                }

                Section {
                    Toggle("Keep receipts in this folder", isOn: $receiptsInside)
                } footer: {
                    Text(receiptsInside
                         ? "Receipts are saved in “\(internalReceiptsDirName)” inside this folder."
                         : "Choose a separate Receipts folder in Settings after setup.")
                }

                Section {
                    Button {
                        working = true
                        Task {
                            await model.setUpWorkspace(areas: areas, receiptsInside: receiptsInside)
                            working = false
                        }
                    } label: {
                        HStack {
                            Text("Set Up Folder")
                            if working { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(areas.isEmpty || working)
                    Button("Choose a Different Folder") { picking = true }
                }
            }
            .navigationTitle("Set Up Projects")
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                if case let .success(url) = result { Task { await model.setProjectsFolder(url) } }
            }
        }
    }

    private func addArea() {
        let a = newArea.trimmingCharacters(in: .whitespaces)
        newArea = ""
        guard !a.isEmpty, !areas.contains(where: { $0.lowercased() == a.lowercased() }) else { return }
        areas.append(a)
    }
}
