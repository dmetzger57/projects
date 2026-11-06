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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(task.text).foregroundStyle(.secondary)
                } footer: {
                    Text("It goes to the end of the project’s tasks, with its notes, attachments and photos. A copy in Today stays linked.")
                }
                ForEach(groups, id: \.label) { g in
                    Section(g.label) {
                        ForEach(g.projects, id: \.folderName) { q in
                            Button { move(to: q) } label: {
                                HStack {
                                    Text(q.title).foregroundStyle(.primary)
                                    Spacer()
                                    if q.status != "active" { StatusBadge(status: q.status) }
                                }
                                .contentShape(Rectangle())
                            }
                            .disabled(moving)
                        }
                    }
                }
                if groups.isEmpty {
                    Text(search.isEmpty ? "There’s no other project to move it to." : "No matching projects.")
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $search, prompt: "Projects")
            .navigationTitle("Move Task To")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
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
