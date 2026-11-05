import SwiftUI
import ProjKitCore

/// The Today tab: the "0 - Today" project's task list (created on first visit).
struct TodayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ProjectDetailView(folder: todayDirName)
                .navigationDestination(for: String.self) { ProjectDetailView(folder: $0) }
        }
        .task {
            if model.today == nil { await model.perform { try Ops.ensureToday($0) } }
        }
    }
}
