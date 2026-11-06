import SwiftUI
import ProjKitCore

struct IdeasView: View {
    @Environment(AppModel.self) private var model
    @State private var newIdea = ""
    @State private var promoting: Int?
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    TextField("New idea", text: $newIdea)
                        .submitLabel(.done)
                        .onSubmit {
                            let t = newIdea
                            newIdea = ""
                            Task { await model.perform { try Ops.addIdea($0, t) } }
                        }
                }
                Section {
                    ForEach(Array(model.ideas.enumerated()), id: \.offset) { i, idea in
                        Text(idea)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await model.perform { try Ops.removeIdea($0, index: i) } }
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                            .swipeActions(edge: .leading) {
                                Button { promoting = i } label: { Label("Make Project", systemImage: "folder.badge.plus") }
                                    .tint(.accentColor)
                            }
                            .contextMenu {
                                Button { promoting = i } label: { Label("Make Project…", systemImage: "folder.badge.plus") }
                            }
                    }
                } footer: {
                    if !model.ideas.isEmpty { Text("Swipe right to turn an idea into a project.") }
                }
            }
            .readableWidth()
            .navigationTitle("Ideas")
            .refreshable { await model.reload() }
            .overlay {
                if model.ideas.isEmpty {
                    ContentUnavailableView("No ideas yet", systemImage: "lightbulb",
                                           description: Text("Jot one down above."))
                        .allowsHitTesting(false)
                }
            }
            .confirmationDialog("Make a project in…", isPresented: Binding(get: { promoting != nil },
                                                                         set: { if !$0 { promoting = nil } }),
                                titleVisibility: .visible, presenting: promoting) { i in
                ForEach(model.areas, id: \.self) { area in
                    Button(area) {
                        Task {
                            if let p = await model.perform({ try Ops.promoteIdea($0, index: i, area: area) }) {
                                path.append(p.folderName)
                            }
                        }
                    }
                }
            }
            .navigationDestination(for: String.self) { ProjectDetailView(folder: $0) }
        }
    }
}
