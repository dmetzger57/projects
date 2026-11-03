import Foundation

public let templateDirName = "1 - Template"
public let closedDirName = "2 - Closed"
public let backlogFileName = "0 - Idea Backlog.md"
/// Optional receipts folder inside the projects root (for people without ~/Documents/Receipts).
public let internalReceiptsDirName = "3 - Receipts"

/// The projects root (e.g. iCloud Drive/Documents/Projects) and the receipts root.
public struct Workspace: Sendable {
    public let root: URL
    public let receiptsRoot: URL?
    public let fs: FileSystem

    public init(root: URL, receiptsRoot: URL?, fs: FileSystem = CoordinatedFileSystem()) {
        self.root = root
        self.receiptsRoot = receiptsRoot
        self.fs = fs
    }

    public var templateDir: URL { root.appendingPathComponent(templateDirName) }
    public var closedDir: URL { root.appendingPathComponent(closedDirName) }
    public var backlogURL: URL { root.appendingPathComponent(backlogFileName) }
    public var internalReceiptsDir: URL { root.appendingPathComponent(internalReceiptsDirName) }

    /// True for a folder that has no template and no areas yet (e.g. a new family member's).
    public var needsSetup: Bool { !fs.isDirectory(templateDir) && areas().isEmpty }

    public static func isReserved(_ name: String) -> Bool {
        name.range(of: #"^\d+ - "#, options: .regularExpression) != nil
    }

    func dirs(in dir: URL) -> [URL] {
        ((try? fs.children(of: dir)) ?? []).filter { fs.isDirectory($0) }
    }

    public func areaDirs() -> [URL] { dirs(in: root).filter { !Self.isReserved($0.lastPathComponent) } }
    public func areas() -> [String] { areaDirs().map(\.lastPathComponent) }

    public func load(_ dir: URL) -> Project {
        let readme = dir.appendingPathComponent(readmeName)
        guard fs.exists(readme) else { return Project(url: dir, document: nil) }
        do {
            return Project(url: dir, document: ProjectDocument.parse(try fs.readText(readme)))
        } catch {
            return Project(url: dir, document: nil, parseError: error.localizedDescription)
        }
    }

    public func projectDirs(includeClosed: Bool = true) -> [URL] {
        var out = areaDirs().flatMap { dirs(in: $0) }
        if includeClosed { out += dirs(in: closedDir) }
        return out
    }

    public func projects(includeClosed: Bool = true) -> [Project] {
        projectDirs(includeClosed: includeClosed).map(load)
    }

    public func project(named folder: String) -> Project? {
        projectDirs().first { $0.lastPathComponent == folder }.map(load)
    }

    public func template() -> Project? { fs.isDirectory(templateDir) ? load(templateDir) : nil }

    public func isInClosed(_ p: Project) -> Bool {
        p.url.deletingLastPathComponent().standardizedFileURL == closedDir.standardizedFileURL
    }

    /// Area implied by the folder location (nil when in Closed).
    public func locationArea(_ p: Project) -> String? {
        isInClosed(p) ? nil : p.url.deletingLastPathComponent().lastPathComponent
    }

    public func displayArea(_ p: Project) -> String { p.area ?? locationArea(p) ?? "—" }

    public func save(_ p: Project) throws {
        guard let doc = p.document else { throw OpError("project has no README.md") }
        try fs.writeText(doc.serialize(), to: p.readmeURL)
    }
}
