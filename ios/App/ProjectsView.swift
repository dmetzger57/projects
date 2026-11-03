import SwiftUI
import ProjKitCore

enum ProjectFilter: String, CaseIterable, Identifiable {
    case open = "Open", closed = "Closed", all = "All"
    var id: String { rawValue }
}

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: ProjectFilter = .open
    @State private var search = ""
    @State private var showNew = false
    @State private var showNewArea = false
    @State private var newAreaName = ""
    @State private var path: [String] = []

    private var filtered: [Project] {
        model.projects.filter { p in
            switch filter {
            case .open: if p.status == "closed" { return false }
            case .closed: if p.status != "closed" { return false }
            case .all: break
            }
            guard !search.isEmpty else { return true }
            let q = search.lowercased()
            return p.title.lowercased().contains(q)
                || p.goals.contains { $0.text.lowercased().contains(q) }
                || p.tasks.contains { $0.text.lowercased().contains(q) }
                || (p.document?.body.lowercased().contains(q) ?? false)
        }
    }

    private var grouped: [(area: String, items: [Project])] {
        let order = ["active": 0, "on-hold": 1, "idea": 2, "closed": 3]
        var groups: [String: [Project]] = [:]
        for p in filtered { groups[model.displayArea(p), default: []].append(p) }
        let names = (filter == .open && search.isEmpty ? model.areas : []) + groups.keys.sorted()
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }.map { area in
            (area, (groups[area] ?? []).sorted {
                (order[$0.status] ?? 9, $0.title.lowercased()) < (order[$1.status] ?? 9, $1.title.lowercased())
            })
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Picker("Show", selection: $filter) {
                        ForEach(ProjectFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    SummaryRow(projects: filtered)
                }
                ForEach(grouped, id: \.area) { group in
                    Section(group.area) {
                        if group.items.isEmpty {
                            Text("No projects").foregroundStyle(.secondary).italic()
                        }
                        ForEach(group.items) { p in
                            NavigationLink(value: p.folderName) { ProjectRow(project: p) }
                        }
                    }
                }
            }
            .navigationTitle("Projects")
            .navigationDestination(for: String.self) { folder in
                ProjectDetailView(folder: folder)
            }
            .searchable(text: $search, prompt: "Projects, goals, notes")
            .refreshable { await model.reload() }
            .overlay {
                if model.projects.isEmpty && !model.isLoading {
                    ContentUnavailableView("No projects found", systemImage: "folder",
                                           description: Text("Check the Projects folder in Settings."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showNew = true } label: { Label("New Project", systemImage: "doc.badge.plus") }
                            .disabled(model.areas.isEmpty)
                        Button { newAreaName = ""; showNewArea = true } label: { Label("New Area", systemImage: "folder.badge.plus") }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showNew) {
                NewProjectSheet { folder in path.append(folder) }
            }
            .alert("New Area", isPresented: $showNewArea) {
                TextField("Name", text: $newAreaName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let name = newAreaName
                    Task { await model.newArea(name) }
                }
            } message: {
                Text("Areas group related projects, e.g. Home or Garden.")
            }
        }
    }
}

struct SummaryRow: View {
    let projects: [Project]
    var body: some View {
        let open = projects.reduce(0) { $0 + $1.goalProgress.total - $1.goalProgress.done }
        let cost = projects.reduce(0) { $0 + $1.totalCost }
        HStack(spacing: 18) {
            stat("\(projects.count)", "projects")
            stat("\(open)", "open goals")
            stat(money(cost), "spent")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(v).font(.headline.monospacedDigit())
            Text(l).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ProjectRow: View {
    let project: Project
    var body: some View {
        let (done, total) = project.goalProgress
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(project.title).font(.body.weight(.semibold))
                Spacer()
                StatusBadge(status: project.status)
            }
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total))
            }
            HStack(spacing: 12) {
                Text(total > 0 ? "\(done)/\(total) goals" : "No goals")
                let openTasks = project.tasks.filter { !$0.done }.count
                if openTasks > 0 { Text("\(openTasks) task\(openTasks == 1 ? "" : "s")") }
                if !project.receipts.isEmpty { Text(money(project.totalCost)) }
                if let last = project.notes.last(where: { !$0.text.isEmpty }) { Text(shortDate(last.date)) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct StatusBadge: View {
    let status: String
    var color: Color {
        switch status {
        case "active": .green
        case "on-hold": .purple
        case "idea": .blue
        case "legacy": .orange
        default: .gray
        }
    }
    var body: some View {
        Text(status)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

func parseISO(_ s: String) -> Date? {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: s)
}

func shortDate(_ iso: String) -> String {
    parseISO(iso)?.formatted(.dateTime.month(.abbreviated).day()) ?? iso
}

func longDate(_ iso: String) -> String {
    parseISO(iso)?.formatted(date: .complete, time: .omitted) ?? iso
}

/// Amounts in the phone's local currency (receipts store plain numbers).
func money(_ amount: Double) -> String {
    amount.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
}

/// Inline markdown (bold, italics, links, code) with line breaks and list dashes preserved.
func markdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(s)
}
