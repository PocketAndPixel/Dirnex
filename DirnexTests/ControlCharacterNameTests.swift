import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A name holding a control character, drawn in the pane and renamed with F2.
///
/// The row that showed it is `Icon\r`, the custom-icon file OneDrive leaves in the root of its folder
/// (seen 2026-11-17): its name drew on two lines in a row one line high, the visible half riding up
/// and clipped. The row now draws ``FileNameDisplay``'s form, `Icon␍`, and the half of this suite that
/// matters more is the second test, because the inline rename reads that text back: committed
/// untouched, the field holds `Icon␍`, which is not the file's name, so Return renamed the file to
/// its own picture.
///
/// The rename is driven through the real `controlTextDidEndEditing` with a plain field rather than
/// through `beginRename`, because opening a real field editor in this suite's retained windows
/// crashes the test host (`ArchiveNameEncodingGestureTests` records the measurement).
@MainActor
@Suite("A name holding a control character")
struct ControlCharacterNameTests {
    private static let folder = "/tmp/ControlCharacterNameTests"
    private static let icon = Handoff.local("\(folder)/Icon\r")
    private static let witness = Handoff.local("\(folder)/witness")

    @Test("its row draws the name on one line, the control character as its picture")
    func rowDrawsThePicture() throws {
        let pane = Self.pane(recording: MoveLog())
        let cell = try #require(Self.nameCell(for: Self.icon, in: pane))
        let label = try #require(cell.textField)
        #expect(label.stringValue == "Icon\u{240D}")
        // The measured symptom, not only the string: the real name lays out two lines tall.
        let oneLine = NSTextField(labelWithString: "Icon").fittingSize.height
        #expect(label.fittingSize.height == oneLine)
    }

    @Test("committing the field as it opened renames nothing, and a real edit still renames")
    func unchangedCommitRenamesNothing() async throws {
        let log = MoveLog()
        let pane = Self.pane(recording: log)

        // The field as F2 opens it on this row, committed with nothing typed.
        Self.commit("Icon\u{240D}", renaming: Self.icon, in: pane)
        // The witness: a rename that must issue, committed after. Its work is dispatched after any
        // the first commit started, and each one opens with a `stat` of its destination, so once the
        // witness's move is in the log, a rename the first commit started is in it too.
        Self.commit("witness renamed", renaming: Self.witness, in: pane)
        try await settleUntil { log.destinations.contains("witness renamed") }
        #expect(!log.destinations.contains("Icon\u{240D}"), "renamed the file to its own picture")

        // Deleting the picture is how a user takes the control character out of a name.
        Self.commit("Icon", renaming: Self.icon, in: pane)
        try await settleUntil { log.moves.contains { $0.to.lastComponent == "Icon" } }
        #expect(log.moves.last?.from == Self.icon.path)
    }

    // MARK: - Fixtures

    /// A pane on the folder, in a window that is never closed (`windowedPane` has the reason).
    private static func pane(recording log: MoveLog) -> PanelViewController {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        RetainedWindows.all.append(window)
        let directory = VFSPath.local(folder)
        let entries = [icon, witness]
        let pane = PanelViewController(
            backend: RecordingBackend(log: log, listing: entries),
            restoration: nil,
            defaultPath: directory,
            restorationKey: nil
        )
        let host = StubPanelHost()
        hosts.append(host)
        pane.host = host
        window.contentViewController = pane
        pane.loadViewIfNeeded()
        pane.panel = Panel(
            model: DirectoryModel(listing: DirectoryListing(path: directory, entries: entries))
        )
        pane.tableView.reloadData()
        return pane
    }

    /// Held for the run, since `PanelViewController.host` is `weak`.
    private static var hosts: [StubPanelHost] = []

    private static func nameCell(for entry: FileEntry, in pane: PanelViewController) -> FileCellView? {
        guard let index = pane.panel.displayedEntries.firstIndex(where: { $0.path == entry.path }),
              let column = pane.tableView.tableColumns.first(where: {
                  $0.identifier.rawValue == PanelViewController.Column.name.rawValue
              }) else { return nil }
        return pane.tableView(pane.tableView, viewFor: column, row: pane.parentRowCount + index) as? FileCellView
    }

    /// What Return in the inline field does: the cursor on the row being renamed, the field ending
    /// its edit with `text` in it.
    private static func commit(
        _ text: String,
        renaming entry: FileEntry,
        in pane: PanelViewController
    ) {
        if let index = pane.panel.displayedEntries.firstIndex(where: { $0.path == entry.path }) {
            pane.panel.moveCursor(to: index)
        }
        pane.renamingEntryID = entry.path
        pane.controlTextDidEndEditing(
            Notification(
                name: NSControl.textDidEndEditingNotification,
                object: NSTextField(string: text)
            )
        )
    }
}

/// Every destination the pane asked about and every move it made, in the order they reached the
/// backend.
private final class MoveLog: @unchecked Sendable {
    struct Move: Equatable {
        let from: VFSPath
        let to: VFSPath
    }

    private let lock = NSLock()
    private var touched: [String] = []
    private var made: [Move] = []

    /// The last path component of each `stat` and move destination.
    var destinations: [String] { lock.withLock { touched } }
    var moves: [Move] { lock.withLock { made } }

    func touch(_ path: VFSPath) { lock.withLock { touched.append(path.lastComponent) } }

    func move(_ from: VFSPath, _ to: VFSPath) {
        lock.withLock {
            touched.append(to.lastComponent)
            made.append(Move(from: from, to: to))
        }
    }
}

/// Lists a fixed folder, answers every `stat` with "not found" so a rename meets no collision, and
/// records instead of moving.
private struct RecordingBackend: VFSBackend {
    let id: VFSBackendID = .local
    let capabilities: VFSCapabilities = [.read, .write, .rename]
    let log: MoveLog
    let listing: [FileEntry]

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { listing }

    func stat(at path: VFSPath) throws -> FileEntry {
        log.touch(path)
        throw VFSError.notFound(path)
    }

    func capabilities(for path: VFSPath) -> VFSCapabilities { capabilities }

    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        log.move(source, destination)
    }
}
