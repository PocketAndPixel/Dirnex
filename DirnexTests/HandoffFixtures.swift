import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Fixtures for the hand-off suites (PLAN.md §M24 Slice 3).
///
/// At file scope rather than on the suite for the reason `RemoteFetchFixtures` is: one funnel is
/// tested from two sides — what it *does* with a set, and which rows ever reach it — and the rows,
/// the panes and the windows belong to neither. It also keeps each suite under SwiftLint's
/// `type_body_length`, which the first version of this was 16 lines over.
enum Handoff {
    static let remoteID = VFSBackendID("sftp://user@host")

    /// A backend that lists nothing and stats nothing: every claim here is about the *gesture*, and
    /// a pane that could really list would only add I/O nobody is asserting on.
    struct StubBackend: VFSBackend {
        let id: VFSBackendID = .local
        let capabilities: VFSCapabilities = [.read, .write]

        func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }
        func stat(at path: VFSPath) throws -> FileEntry { throw VFSError.notFound(path) }
    }

    static func entry(
        _ path: VFSPath,
        kind: FileEntry.Kind = .file,
        size: Int64 = 512,
        isDataless: Bool = false
    ) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: kind,
            byteSize: size,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 11,
            isDataless: isDataless
        )
    }

    static func local(_ path: String, kind: FileEntry.Kind = .file) -> FileEntry {
        entry(.local(path), kind: kind)
    }

    static func remote(_ path: String, kind: FileEntry.Kind = .file) -> FileEntry {
        entry(VFSPath(backend: remoteID, path: path), kind: kind)
    }

    /// A real file on disk, so a URL handed over stands for something.
    static func temporaryFile(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("bytes".utf8).write(to: url)
        return url
    }

    /// A report standing for a job that landed `files` and failed on `failures`.
    static func report(
        landing files: [(FileEntry, URL)] = [],
        failing failures: [FileEntry] = [],
        cancelled: Bool = false
    ) -> OperationReport {
        OperationReport(
            completedItems: files.count,
            completedBytes: Int64(files.count) * 512,
            skipped: [],
            failures: failures.map {
                OperationItemFailure(path: $0.path, error: .notFound($0.path))
            },
            wasCancelled: cancelled,
            materialized: files.map {
                MaterializedFile(
                    source: $0.0.path,
                    localPath: $0.1.path,
                    revision: RemoteFileRevision($0.0)
                )
            }
        )
    }
}

/// A pane with a host, both returned so the caller can keep the host alive — `host` is `weak`, and
/// binding it to `_` deallocates it before anything is asked of it, after which every test silently
/// measures the no-host path instead of the one it named.
@MainActor
func hostedPane(showing entries: [FileEntry] = []) -> (PanelViewController, StubPanelHost) {
    let directory = VFSPath.local("/tmp")
    let pane = PanelViewController(
        backend: Handoff.StubBackend(),
        restoration: nil,
        defaultPath: directory,
        restorationKey: nil
    )
    let host = StubPanelHost()
    pane.host = host
    if !entries.isEmpty {
        pane.panel = Panel(
            model: DirectoryModel(listing: DirectoryListing(path: directory, entries: entries))
        )
    }
    return (pane, host)
}

/// The same, hosted in a window so an alert attaches as a **sheet** instead of falling back to
/// `runModal()`.
///
/// That fallback is right in the product — a hand-off is a gesture somebody made and is waiting on
/// — and in a test host it wedges the whole run on a dialog nobody can click. The window is **never
/// closed**: tearing one down while a sheet it carried is still settling segfaults the runner inside
/// AppKit's own animation teardown, and the crash lands on a *later* test that presented no sheet at
/// all (docs/NOTES.md ▸ Testing). A handful of retained windows costs nothing by comparison.
@MainActor
func windowedPane() -> WindowedPane {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    RetainedWindows.all.append(window)
    let (pane, host) = hostedPane()
    window.contentViewController = pane
    pane.loadViewIfNeeded()
    return WindowedPane(pane: pane, host: host, window: window)
}

/// A named triple rather than a tuple: SwiftLint caps a tuple at two members, and the three here are
/// each read by name in the tests that need a sheet to land somewhere.
@MainActor
struct WindowedPane {
    let pane: PanelViewController
    let host: StubPanelHost
    let window: NSWindow
}

@MainActor
enum RetainedWindows {
    static var all: [NSWindow] = []
}

/// Every piece of text the sheet is showing, so a test can say *which* sentence was raised. Walked
/// out of the window because `NSAlert` keeps no handle to itself once presented, and the wording is
/// the whole difference between the two things that can go wrong here.
@MainActor
func sheetText(in window: NSWindow) -> [String] {
    guard let content = window.attachedSheet?.contentView else { return [] }
    var found: [String] = []
    var stack = [content]
    while let view = stack.popLast() {
        if let field = view as? NSTextField { found.append(field.stringValue) }
        stack.append(contentsOf: view.subviews)
    }
    return found
}

/// A main-actor box for what the funnel handed back — an `@escaping @MainActor` closure cannot
/// mutate a captured `var`.
@MainActor
final class Handed {
    var urls: [URL]?
    var times = 0

    func take(_ urls: [URL]) {
        self.urls = urls
        times += 1
    }
}

/// Wording that must never be asked for: every path that evaluates it is a path that should have
/// handed the files over instead of reporting.
func neverAsked() -> String {
    Issue.record("the failure wording was evaluated on a path that should not report")
    return ""
}
