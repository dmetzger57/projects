import SwiftUI
import ProjKitCore

// MARK: - readable width

/// On wide screens (iPad, large iPhones in landscape), keeps list and form content to a readable
/// column centered in the window instead of stretching edge to edge. Compact width is left alone.
/// (The list itself is narrowed; content margins on the scroll view hid the Today large title.)
struct ReadableWidth: ViewModifier {
    var maxWidth: CGFloat = 720
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #else
    private let sizeClass: UserInterfaceSizeClass? = .regular     // the Mac always gets the wide layout
    #endif

    func body(content: Content) -> some View {
        if sizeClass == .regular {
            content
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
                .background(Color.groupedBackground)
        } else {
            content
        }
    }
}

extension View {
    func readableWidth(_ maxWidth: CGFloat = 720) -> some View { modifier(ReadableWidth(maxWidth: maxWidth)) }
}

// MARK: - overview grid (iPad)

/// The overview as tiles by area, like the web UI. Shown beside the project list on iPad when no
/// project is selected. Honors collapsed areas and the manual area/project order.
struct ProjectGridView: View {
    @Environment(AppModel.self) private var model
    let groups: [(area: String, items: [Project])]
    let summary: [Project]
    let select: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SummaryRow(projects: summary)
                    .padding(.horizontal, 4)
                ForEach(groups, id: \.area) { group in
                    areaSection(group.area, group.items)
                }
            }
            .padding(24)
            .frame(maxWidth: 1400)
            .frame(maxWidth: .infinity)
        }
        .background(Color.groupedBackground)
        .navigationTitle("Overview")
        .toolbar { ToolbarItem(placement: .primaryAction) { CollapseAllButton(shown: groups.map(\.area)) } }
        .refreshable { await model.reload() }
    }

    @ViewBuilder
    private func areaSection(_ area: String, _ items: [Project]) -> some View {
        let collapsed = model.overview.isCollapsed(area)
        VStack(alignment: .leading, spacing: 10) {
            Button { setCollapsed(area, !collapsed) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Text(area).font(.title3.weight(.semibold))
                    Text("\(items.count)").font(.title3).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? "Expand \(area)" : "Collapse \(area)")
            .contextMenu {
                Button { setCollapsed(area, !collapsed) } label: {
                    Label(collapsed ? "Expand" : "Collapse to Name",
                          systemImage: collapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                }
                CollapseAllMenuItems()
            }
            if !collapsed {
                if items.isEmpty {
                    Text("No projects").foregroundStyle(.secondary).italic().padding(.leading, 4)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(Array(items.enumerated()), id: \.element.folderName) { i, p in
                            tile(p, index: i, in: items)
                        }
                    }
                }
            }
        }
    }

    private func tile(_ p: Project, index i: Int, in items: [Project]) -> some View {
        Button { select(p.folderName) } label: {
            ProjectRow(project: p)
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                .background(Color.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .liftOnHover()
        .contextMenu {
            if model.isClosed(p) {
                Section { ReopenMenu(project: p) }
            }
            if items.count > 1 {
                Button { move(p, before: items[0]) } label: { Label("Move to Top", systemImage: "arrow.up.to.line") }
                    .disabled(i == 0)
                Button { move(p, before: items[max(i - 1, 0)]) } label: { Label("Move Earlier", systemImage: "arrow.left") }
                    .disabled(i == 0)
                Button { move(p, after: items[min(i + 1, items.count - 1)]) } label: { Label("Move Later", systemImage: "arrow.right") }
                    .disabled(i == items.count - 1)
                Button { move(p, after: items[items.count - 1]) } label: { Label("Move to Bottom", systemImage: "arrow.down.to.line") }
                    .disabled(i == items.count - 1)
            }
        }
    }

    private func setCollapsed(_ area: String, _ on: Bool) {
        Task { await model.perform { try Ops.setCollapsed($0, areas: [area], on) } }
    }

    private func move(_ p: Project, before other: Project) {
        guard other.folderName != p.folderName else { return }
        Task { await model.perform { try Ops.moveProject($0, p, before: other.folderName) } }
    }

    private func move(_ p: Project, after other: Project) {
        guard other.folderName != p.folderName else { return }
        Task { await model.perform { try Ops.moveProject($0, p, after: other.folderName) } }
    }
}
