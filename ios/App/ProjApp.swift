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
                #if os(macOS)
                .frame(minWidth: 760, minHeight: 480)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await model.reload() }      // back from Terminal, Finder or the web UI
                }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 800)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.reload() } }
                    .keyboardShortcut("r")
            }
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 560, height: 520)
        }
        #endif
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: String = {
        #if DEBUG
        // Simulator testing: PROJ_DEBUG_TAB=projects|ideas|archive|settings picks the starting tab;
        // PROJ_DEBUG_OPEN (open a project) implies the Projects tab.
        let env = ProcessInfo.processInfo.environment
        if let t = env["PROJ_DEBUG_TAB"], !t.isEmpty { return t }
        if let f = env["PROJ_DEBUG_OPEN"], !f.isEmpty { return "projects" }
        #endif
        return "today"
    }()

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isConfigured && model.needsSetup {
                SetupView()
            } else if model.isConfigured {
                TabView(selection: $tab) {
                    TodayView()
                        .tabItem { Label("Today", systemImage: "sun.max") }
                        .tag("today")
                    ProjectsView()
                        .tabItem { Label("Projects", systemImage: "folder") }
                        .tag("projects")
                    IdeasView()
                        .tabItem { Label("Ideas", systemImage: "lightbulb") }
                        .tag("ideas")
                    ArchiveView()
                        .tabItem { Label("Archive", systemImage: "archivebox") }
                        .tag("archive")
                    #if os(iOS)
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag("settings")
                    #endif
                }
                #if os(macOS)
                .tabViewStyle(.sidebarAdaptable)      // a sidebar on the Mac; Settings is in the app menu (⌘,)
                #endif
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

    #if os(macOS)
    static let intro: LocalizedStringKey = "Choose your Projects folder to get started.\nIn the panel, select **Documents › Projects** and click **Open**.\nNew to Proj? Create an empty folder (e.g. “Projects”) in the panel and choose it — Proj sets it up for you."
    static let footnote: LocalizedStringKey = "Proj edits the README.md files in place, so changes show up in `proj` and the web UI too."
    #else
    static let intro: LocalizedStringKey = "Choose your Projects folder to get started.\nIn the picker, open **iCloud Drive › Documents › Projects** and tap **Open**.\nNew to Proj? Create an empty folder (e.g. “Projects”) in the picker and choose it — Proj sets it up for you."
    static let footnote: LocalizedStringKey = "Proj edits the README.md files in place, so changes show up in `proj` on your Mac."
    #endif

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Proj").font(.largeTitle.bold())
            Text(Self.intro)
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
            Text(Self.footnote)
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
