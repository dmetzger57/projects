import Foundation
import Observation
import ProjKitCore

/// App state. Folder access comes from user-picked folders (Files app → iCloud Drive),
/// remembered as bookmarks — no iCloud entitlement needed, so it works with a free Apple ID.
@MainActor @Observable
final class AppModel {
    private(set) var projectsRoot: URL?
    private var pickedReceiptsRoot: URL?
    /// iCloud Drive › Documents — needed to open Project Files links ("Documents/…") on the phone.
    private(set) var documentsRoot: URL?
    /// Keep receipts in `3 - Receipts` inside the projects folder (for people without ~/Documents/Receipts).
    private(set) var receiptsInside = false
    private(set) var needsSetup = false
    private(set) var projects: [Project] = []
    private(set) var today: Project?
    private(set) var ideas: [String] = []
    private(set) var areas: [String] = []
    private(set) var isLoading = false
    private(set) var lastLoaded: Date?
    var errorMessage: String?

    private static let projectsKey = "projectsBookmark"
    private static let receiptsKey = "receiptsBookmark"
    private static let documentsKey = "documentsBookmark"
    private static let fileBookmarksKey = "fileBookmarks"     // [Project Files target: bookmark]
    private static let receiptsInsideKey = "receiptsInside"

    var receiptsRoot: URL? {
        receiptsInside ? projectsRoot?.appendingPathComponent(internalReceiptsDirName) : pickedReceiptsRoot
    }

    var workspace: Workspace? { projectsRoot.map { Workspace(root: $0, receiptsRoot: receiptsRoot) } }

    init() {
        projectsRoot = Self.restore(Self.projectsKey)
        pickedReceiptsRoot = Self.restore(Self.receiptsKey)
        documentsRoot = Self.restore(Self.documentsKey)
        if let d = documentsRoot, !Self.isDocumentsFolder(d) {
            // An earlier build accepted a folder inside Documents (e.g. Documents/Misc); every
            // "Documents/…" path then resolved to the wrong place. Forget it so the app asks again.
            documentsRoot = nil
            UserDefaults.standard.removeObject(forKey: Self.documentsKey)
        }
        receiptsInside = UserDefaults.standard.bool(forKey: Self.receiptsInsideKey)
        #if DEBUG
        // Simulator testing: PROJ_DEBUG_ROOT=<projects folder> skips the folder picker.
        if let r = ProcessInfo.processInfo.environment["PROJ_DEBUG_ROOT"] { projectsRoot = URL(fileURLWithPath: r) }
        #endif
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

    /// Project Files paths start with "Documents/", so the folder must be iCloud Drive › Documents itself.
    static func isDocumentsFolder(_ url: URL) -> Bool { url.standardizedFileURL.lastPathComponent == "Documents" }

    @discardableResult
    func setDocumentsFolder(_ url: URL) async -> Bool {
        guard Self.isDocumentsFolder(url) else {
            errorMessage = "Choose the Documents folder itself (iCloud Drive › Documents), not “\(url.lastPathComponent)”."
            return false
        }
        do {
            documentsRoot = try remember(url, key: Self.documentsKey)
            return true
        } catch {
            errorMessage = "Couldn't remember that folder: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: project files

    /// Remembers access to a file picked with Browse, so it opens even without the Documents folder chosen.
    func rememberFile(_ url: URL, as target: String) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: Self.createOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        var all = UserDefaults.standard.dictionary(forKey: Self.fileBookmarksKey) as? [String: Data] ?? [:]
        all[target] = data
        UserDefaults.standard.set(all, forKey: Self.fileBookmarksKey)
    }

    /// Where a Project Files entry lives on this phone: a remembered bookmark, else inside the Documents folder.
    func fileURL(for f: ProjectFile) -> URL? {
        guard !f.isURL else { return nil }
        return bookmarkedFile(f.target) ?? Ops.fileURL(f, documentsRoot: documentsRoot)
    }

    /// Where a receipt lives on this phone: a remembered bookmark, else the Documents or Receipts folder.
    func receiptURL(for r: Receipt) -> URL? {
        guard let ws = workspace else { return nil }
        return bookmarkedFile(r.path) ?? Ops.receiptURL(ws, r, documentsRoot: documentsRoot)
    }

    private func bookmarkedFile(_ target: String) -> URL? {
        guard let data = (UserDefaults.standard.dictionary(forKey: Self.fileBookmarksKey) as? [String: Data])?[target]
        else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: Self.resolveOptions, relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()   // held while the app runs
        if stale { rememberFile(url, as: target) }
        return url
    }

    func setReceiptsFolder(_ url: URL) async {
        do {
            pickedReceiptsRoot = try remember(url, key: Self.receiptsKey)
            setReceiptsInside(false)
            await reload()
        } catch {
            errorMessage = "Couldn't remember that folder: \(error.localizedDescription)"
        }
    }

    func setReceiptsInside(_ on: Bool) {
        receiptsInside = on
        UserDefaults.standard.set(on, forKey: Self.receiptsInsideKey)
    }

    /// Use `3 - Receipts` inside the projects folder (created if missing).
    func useReceiptsInside() async {
        setReceiptsInside(true)
        await perform { ws in
            if !ws.fs.isDirectory(ws.internalReceiptsDir) { try ws.fs.createDirectory(ws.internalReceiptsDir) }
        }
    }

    /// Turns the chosen (empty) folder into a projects workspace.
    func setUpWorkspace(areas: [String], receiptsInside inside: Bool) async {
        if inside { setReceiptsInside(true) }
        await perform { try Ops.setUpWorkspace($0, areas: areas, receiptsInside: inside) }
    }

    func newArea(_ name: String) async {
        await perform { try Ops.newArea($0, name) }
    }

    // MARK: loading

    func reload() async {
        guard let ws = workspace else { return }
        isLoading = true
        defer { isLoading = false }
        let result = await Task.detached(priority: .userInitiated) { () -> ([Project], [String], [String], Bool, Project?) in
            (ws.projects(), Ops.ideas(ws), ws.areas(), ws.needsSetup, ws.today())
        }.value
        (projects, ideas, areas, needsSetup, today) = result
        lastLoaded = Date()
    }

    func project(_ folder: String) -> Project? {
        folder == todayDirName ? today : projects.first { $0.folderName == folder }
    }

    func isToday(_ p: Project) -> Bool { p.folderName == todayDirName && today?.url == p.url }

    /// Link ids of the tasks in Today (a project task with one of these is "in Today").
    var todayIDs: Set<String> { Set(today?.tasks.compactMap(\.linkID) ?? []) }

    /// The project (not Today) whose task carries `id`.
    func taskSource(_ id: String?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.tasks.contains { $0.linkID == id } }
    }

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

    /// Downloads an iCloud file and hands Quick Look a local copy of its bytes.
    /// A file the phone hasn't synced yet (e.g. just added on the Mac) has no local data; a bare
    /// coordinated read "succeeds" on it and Quick Look then shows an empty "data" page. So: ask
    /// iCloud for it, copy it inside a coordinated read, and retry for a while until it arrives.
    func prepareForViewing(_ url: URL) async -> URL? {
        let copy = await Task.detached(priority: .userInitiated) { () -> URL? in
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("Preview", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            for attempt in 0..<20 {                          // up to ~10 s for iCloud to deliver it
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
                try? fm.startDownloadingUbiquitousItem(at: url)
                // Listing the folder makes iCloud materialize entries the phone hasn't seen yet.
                _ = try? fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
                var err: NSError?
                var result: URL?
                NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &err) { real in
                    guard let data = try? Data(contentsOf: real), !data.isEmpty || Self.isEmptyFile(real) else { return }
                    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    let dest = dir.appendingPathComponent(url.lastPathComponent)
                    if (try? data.write(to: dest)) != nil { result = dest }
                }
                if let result { return result }
            }
            return nil
        }.value
        if copy == nil {
            errorMessage = "Couldn't open “\(url.lastPathComponent)”. It may not have downloaded from iCloud yet — try again in a moment."
        }
        return copy
    }

    private nonisolated static func isEmptyFile(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1) == 0
    }

    var isConfigured: Bool { projectsRoot != nil }

    func displayArea(_ p: Project) -> String { workspace?.displayArea(p) ?? (p.area ?? "—") }
    func isClosed(_ p: Project) -> Bool { workspace?.isInClosed(p) ?? false }
}
