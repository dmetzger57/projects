import Foundation

/// File access used by the workspace. The default implementation coordinates every
/// read/write with NSFileCoordinator, which is required for iCloud Drive: it triggers
/// downloads of evicted files and keeps other devices' writes from interleaving.
public protocol FileSystem: Sendable {
    func readText(_ url: URL) throws -> String
    func readData(_ url: URL) throws -> Data
    func writeText(_ text: String, to url: URL) throws
    func writeData(_ data: Data, to url: URL) throws
    /// Visible (non-hidden) children, iCloud placeholders reported under their real names.
    func children(of dir: URL) throws -> [URL]
    func isDirectory(_ url: URL) -> Bool
    func exists(_ url: URL) -> Bool
    func createDirectory(_ url: URL) throws
    func move(_ src: URL, to dst: URL) throws
    func copy(_ src: URL, to dst: URL) throws
    func removeItem(_ url: URL) throws
}

public struct CoordinatedFileSystem: FileSystem {
    public init() {}

    private var fm: FileManager { FileManager.default }

    /// `.Name.icloud` → `Name` (iCloud placeholder for a file not downloaded yet).
    static func realName(ofPlaceholder name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 else { return nil }
        return String(name.dropFirst().dropLast(7))
    }

    private func coordinate<T>(read url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            result = Result { try body(u) }
        }
        if let e = coordError { throw e }
        return try result!.get()
    }

    private func coordinate(write url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void) throws {
        var coordError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options, error: &coordError) { u in
            result = Result { try body(u) }
        }
        if let e = coordError { throw e }
        try result!.get()
    }

    public func readText(_ url: URL) throws -> String {
        try coordinate(read: url) { try String(contentsOf: $0, encoding: .utf8) }
    }

    public func readData(_ url: URL) throws -> Data {
        try coordinate(read: url) { try Data(contentsOf: $0) }
    }

    public func writeText(_ text: String, to url: URL) throws {
        try writeData(Data(text.utf8), to: url)
    }

    public func writeData(_ data: Data, to url: URL) throws {
        try coordinate(write: url, options: .forReplacing) { try data.write(to: $0, options: .atomic) }
    }

    public func children(of dir: URL) throws -> [URL] {
        let names = try coordinate(read: dir) { try fm.contentsOfDirectory(atPath: $0.path) }
        var out: [URL] = []
        for name in names {
            if let real = Self.realName(ofPlaceholder: name) {
                if real.hasPrefix(".") { continue }
                let placeholder = dir.appendingPathComponent(name)
                try? fm.startDownloadingUbiquitousItem(at: placeholder)
                out.append(dir.appendingPathComponent(real))
            } else if !name.hasPrefix(".") {
                out.append(dir.appendingPathComponent(name))
            }
        }
        return out.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    public func exists(_ url: URL) -> Bool {
        if fm.fileExists(atPath: url.path) { return true }
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        return fm.fileExists(atPath: placeholder.path)
    }

    public func createDirectory(_ url: URL) throws {
        try coordinate(write: url, options: []) { try fm.createDirectory(at: $0, withIntermediateDirectories: true) }
    }

    public func move(_ src: URL, to dst: URL) throws {
        var coordError: NSError?
        var result: Result<Void, Error>?
        let c = NSFileCoordinator(filePresenter: nil)
        c.coordinate(writingItemAt: src, options: .forMoving, writingItemAt: dst, options: .forReplacing,
                     error: &coordError) { s, d in
            result = Result {
                c.item(at: s, willMoveTo: d)
                try fm.moveItem(at: s, to: d)
                c.item(at: s, didMoveTo: d)
            }
        }
        if let e = coordError { throw e }
        try result!.get()
    }

    public func copy(_ src: URL, to dst: URL) throws {
        var coordError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: src, options: [], writingItemAt: dst,
                                                        options: .forReplacing, error: &coordError) { s, d in
            result = Result { try fm.copyItem(at: s, to: d) }
        }
        if let e = coordError { throw e }
        try result!.get()
    }

    public func removeItem(_ url: URL) throws {
        try coordinate(write: url, options: .forDeleting) { try fm.removeItem(at: $0) }
    }
}
