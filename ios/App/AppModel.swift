import Foundation
import Observation
import ProjKitCore

/// App state. Folder access comes from user-picked folders (Files app → iCloud Drive),
/// remembered as bookmarks — no iCloud entitlement needed, so it works with a free Apple ID.
@MainActor @Observable
final class AppModel {
    private(set) var projectsRoot: URL?
    private(set) var receiptsRoot: URL?
    private(set) var projects: [Project] = []
    private(set) var ideas: [String] = []
    private(set) var areas: [String] = []
    private(set) var isLoading = false
    private(set) var lastLoaded: Date?
    var errorMessage: String?

    private static let projectsKey = "projectsBookmark"
    private static let receiptsKey = "receiptsBookmark"

    var workspace: Workspace? { projectsRoot.map { Workspace(root: $0, receiptsRoot: receiptsRoot) } }

    init() {
        projectsRoot = Self.restore(Self.projectsKey)
        receiptsRoot = Self.restore(Self.receiptsKey)
    }

    // MARK: folders

    #if os(macOS)
    private static let createOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let createOptions: URL.BookmarkCreationOptions = []
    private static let resolveOptions: URL.BookmarkResolutionOptions = []
    #endif

    private static func restore(_ key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: resolveOptions, relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()   // held for the app's lifetime
        if stale, let fresh = try? url.bookmarkData(options: createOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: key)
        }
        return url
    }

    private func remember(_ url: URL, key: String) throws -> URL {
        _ = url.startAccessingSecurityScopedResource()
        let data = try url.bookmarkData(options: Self.createOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: key)
        return url
    }

    func setProjectsFolder(_ url: URL) async {
        do {
            projectsRoot = try remember(url, key: Self.projectsKey)
            await reload()
        } catch {
            errorMessage = "Couldn't remember that folder: \(error.localizedDescription)"
        }
    }

    func setReceiptsFolder(_ url: URL) async {
        do {
            receiptsRoot = try remember(url, key: Self.receiptsKey)
            await reload()
        } catch {
            errorMessage = "Couldn't remember that folder: \(error.localizedDescription)"
        }
    }

    // MARK: loading

    func reload() async {
        guard let ws = workspace else { return }
        isLoading = true
        defer { isLoading = false }
        let result = await Task.detached(priority: .userInitiated) { () -> ([Project], [String], [String]) in
            (ws.projects(), Ops.ideas(ws), ws.areas())
        }.value
        (projects, ideas, areas) = result
        lastLoaded = Date()
    }

    func project(_ folder: String) -> Project? { projects.first { $0.folderName == folder } }

    /// Runs one file operation off the main thread, then reloads. Returns its result or nil on error.
    @discardableResult
    func perform<T: Sendable>(_ action: @escaping @Sendable (Workspace) throws -> T) async -> T? {
        guard let ws = workspace else { return nil }
        let r = await Task.detached(priority: .userInitiated) { Result { try action(ws) } }.value
        await reload()
        switch r {
        case let .success(v): return v
        case let .failure(e):
            errorMessage = e.localizedDescription
            return nil
        }
    }

    /// Makes sure an iCloud file is downloaded (coordinated read) before Quick Look opens it.
    func prepareForViewing(_ url: URL) async -> URL? {
        let ok = await Task.detached {
            var err: NSError?
            var done = false
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &err) { _ in done = true }
            return done && err == nil
        }.value
        if !ok { errorMessage = "Couldn't open \(url.lastPathComponent)" }
        return ok ? url : nil
    }

    var isConfigured: Bool { projectsRoot != nil }

    func displayArea(_ p: Project) -> String { workspace?.displayArea(p) ?? (p.area ?? "—") }
    func isClosed(_ p: Project) -> Bool { workspace?.isInClosed(p) ?? false }
}
