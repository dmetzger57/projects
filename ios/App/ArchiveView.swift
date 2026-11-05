import SwiftUI
import ProjKitCore

/// The Archive tab: the "0 - Archive" project's tasks with their original project (created on first visit).
struct ArchiveView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ProjectDetailView(folder: archiveDirName)
                .navigationDestination(for: String.self) { ProjectDetailView(folder: $0) }
        }
        .task {
            if model.archive == nil { await model.perform { try Ops.ensureArchive($0) } }
        }
    }
}
