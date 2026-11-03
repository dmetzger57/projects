import SwiftUI
import ProjKitCore

@main
struct ProjApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.reload() }
                .onChange(of: scenePhase) { _, phase in
                    // pick up edits made on the Mac (or other devices) when returning to the app
                    if phase == .active { Task { await model.reload() } }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isConfigured && model.needsSetup {
                SetupView()
            } else if model.isConfigured {
                TabView {
                    ProjectsView()
                        .tabItem { Label("Projects", systemImage: "folder") }
                    IdeasView()
                        .tabItem { Label("Ideas", systemImage: "lightbulb") }
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                }
            } else {
                OnboardingView()
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil },
                                                             set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var picking = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Proj").font(.largeTitle.bold())
            Text("Choose your Projects folder to get started.\nIn the picker, open **iCloud Drive › Documents › Projects** and tap **Open**.\nNew to Proj? Create an empty folder (e.g. “Projects”) in the picker and choose it — Proj sets it up for you.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                picking = true
            } label: {
                Text("Choose Projects Folder").frame(maxWidth: 280)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
            Text("Proj edits the README.md files in place, so changes show up in `proj` on your Mac.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result { Task { await model.setProjectsFolder(url) } }
        }
    }
}
