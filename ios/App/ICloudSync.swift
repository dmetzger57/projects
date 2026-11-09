import Foundation
import ProjKitCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// iCloud Drive syncs on its own schedule, and there is no API that makes it sync "now". What the app can do:
//  - on open (launch, back to the foreground, pull to refresh / ⌘R): ask iCloud for the newest version of
//    every file Proj reads, wait (briefly) until the device has it, then reload;
//  - on close (to the background on iPhone/iPad, Quit on the Mac): let any save in progress finish first, so
//    iCloud has every change to upload. The upload itself is done by the system, not by the app.
// Proj's folders are user-picked (no iCloud container), so this uses per-file resource values rather than
// NSMetadataQuery, which only covers an app's own container.

enum ICloudSync {
    /// How long opening the app waits for newer versions before showing what it has.
    static let openTimeout: Duration = .seconds(15)

    /// The files Proj reads: root .md files (Overview, Idea Backlog), and README.md of every project
    /// (areas, Closed, Today, Archive). Listing goes through the coordinated file system, which also makes
    /// iCloud fetch entries this device hasn't seen yet.
    static func trackedFiles(_ ws: Workspace) -> [URL] {
        let fs = ws.fs
        var out: [URL] = []
        for top in (try? fs.children(of: ws.root)) ?? [] {
            if top.pathExtension.lowercased() == "md" { out.append(top); continue }
            guard fs.isDirectory(top) else { continue }
            let readme = top.appendingPathComponent("README.md")
            if fs.exists(readme) { out.append(readme) }                // Today, Archive, Template, legacy
            for sub in (try? fs.children(of: top)) ?? [] where fs.isDirectory(sub) {
                let r = sub.appendingPathComponent("README.md")
                if fs.exists(r) { out.append(r) }                      // a project (in an area or Closed)
            }
        }
        return out
    }

    /// True when iCloud knows of a newer version of `url` than the one on this device (or has none here).
    /// Files outside iCloud (a local folder, the simulator) never need it.
    static func needsDownload(_ url: URL) -> Bool {
        var u = url
        u.removeAllCachedResourceValues()
        guard let v = try? u.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              v.isUbiquitousItem == true else { return false }
        return v.ubiquitousItemDownloadingStatus != .current
    }

    struct Result: Sendable { let refreshed: Int; let stillDownloading: Int }

    /// Asks iCloud for the newest version of every tracked file that isn't current and waits until they are
    /// (or `timeout` passes). `started` is called with the number of files being fetched, if any.
    static func pull(_ ws: Workspace, timeout: Duration = openTimeout,
                     started: @Sendable (Int) async -> Void) async -> Result {
        var pending = trackedFiles(ws).filter(needsDownload)
        guard !pending.isEmpty else { return Result(refreshed: 0, stillDownloading: 0) }
        await started(pending.count)
        let total = pending.count
        for u in pending { try? FileManager.default.startDownloadingUbiquitousItem(at: u) }
        let deadline = ContinuousClock.now + timeout
        while !pending.isEmpty && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(400))
            pending = pending.filter(needsDownload)
        }
        return Result(refreshed: total - pending.count, stillDownloading: pending.count)
    }
}

extension AppModel {
    /// Open: show what's on the device right away, then fetch newer versions from iCloud and reload.
    func syncWithICloud() async {
        await reload()
        guard let ws = workspace, syncStatus == nil || syncStatus?.isFinished == true else { return }
        let r = await Task.detached(priority: .userInitiated) {
            await ICloudSync.pull(ws) { n in await MainActor.run { self.syncStatus = .downloading(n) } }
        }.value
        if r.refreshed > 0 { await reload() }
        if r.stillDownloading > 0 {
            syncStatus = .incomplete(r.stillDownloading)
            try? await Task.sleep(for: .seconds(5))
        }
        syncStatus = nil
    }

    /// Close: wait for saves in progress (bounded), so nothing is cut off when the app is suspended or quits.
    func finishPendingWrites(timeout: Duration = .seconds(20)) async {
        let deadline = ContinuousClock.now + timeout
        while writesInFlight > 0 && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    #if os(iOS)
    /// Going to the background: ask iOS for time to finish saving before the app is suspended.
    func appWillClose() {
        guard writesInFlight > 0 else { return }
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask(withName: "Finish saving to iCloud") {
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
        Task {
            await finishPendingWrites()
            if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
        }
    }
    #endif
}

/// What the iCloud sync on open is doing, shown at the bottom of the window while it runs.
enum SyncStatus: Equatable {
    case downloading(Int)          // newer versions of this many files are on their way
    case incomplete(Int)           // gave up waiting; this many are still downloading

    var isFinished: Bool { if case .incomplete = self { true } else { false } }

    var text: String {
        switch self {
        case .downloading(let n): "Getting the latest from iCloud (\(n) file\(n == 1 ? "" : "s"))…"
        case .incomplete(let n): "\(n) file\(n == 1 ? " is" : "s are") still downloading from iCloud; pull to refresh later."
        }
    }
}

#if os(macOS)
/// Quit waits for a save in progress, so the last change reaches iCloud.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.writesInFlight > 0 else { return .terminateNow }
        Task { @MainActor in
            await model.finishPendingWrites()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif
