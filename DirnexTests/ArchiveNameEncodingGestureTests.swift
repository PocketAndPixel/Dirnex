import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Which *gesture* reaches the code-page chooser (PLAN.md §M27).
///
/// The chooser shipped reachable from three writes — F8, paste, F5 copy-out — and from the File
/// menu. Every other gesture that wants a member's **bytes** meets the identical refusal and
/// reported it as an ordinary failure: ⏎ and F4 said *"Couldn't open this item"*, ⌘Y and ⌃Q said
/// *"Couldn't preview this item"*, ⏎ into a nested archive and every hand-off that stages members
/// first said their own version. Each sentence is true, useless, and names the wrong thing — the
/// archive is fine and only its code page is unknown. Reported by a user 2026-09-10.
///
/// **"A sheet appeared" is not the assertion**, which is the trap this suite is built around: the
/// branch it replaces *also* ends in a sheet, so a control that removed the offer would leave a
/// presence check passing exactly as well (docs/NOTES.md ▸ Testing, M24 Slice 4). What separates
/// them is structural and language-independent — the chooser carries a **popup** and two buttons,
/// a failure carries one lone OK — so every test below asserts *which* sheet is up.
///
/// The pane is hosted in a **retained** window, which is what makes driving the action possible at
/// all: with no window `ArchiveNameEncodingPrompt.ask` falls back to `runModal()` — correctly,
/// since it is a gesture somebody is waiting on — and would wedge the run instead of failing it.
/// Retained rather than closed, because tearing a window down while a sheet it carried is still
/// settling segfaults the host inside AppKit's own animation teardown, one test later.
@MainActor
@Suite("Which gesture reaches the code-page chooser", .serialized)
struct ArchiveNameEncodingGestureTests {
    private nonisolated static let cyrillic = "Панорама.txt"
    private nonisolated static let nestedArchiveName = "Архив.zip"

    // MARK: - Fixtures

    /// A real legacy zip: one member named in **CP866** with the UTF-8 flag clear, beside an ASCII
    /// `plain.txt` nothing is wrong with. `nesting` swaps the code-page member for an ordinary
    /// UTF-8 archive under a code-page name, so the only thing between a pane and its contents is
    /// the outer archive's names.
    private struct Fixture {
        let root: URL
        let path: String

        init(
            nesting: Bool = false,
            siblingName: String = "plain.txt",
            siblingContents: String = "readable contents"
        ) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("encoding_gesture_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            path = root.appendingPathComponent("outer.zip").path
            var members: [LegacyNameZip.Member] = [.text(siblingName, siblingContents)]
            if nesting {
                members.append(
                    LegacyNameZip.Member(name: nestedArchiveName, contents: try Self.innerArchive())
                )
            } else {
                members.append(.text(cyrillic, "original contents"))
            }
            try LegacyNameZip.write(members, to: path)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        private static func innerArchive() throws -> Data {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("gesture_inner_\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let source = staging.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("nested".utf8).write(to: source.appendingPathComponent("note.txt"))
            let archive = staging.appendingPathComponent("inner.zip").path
            try EncryptedArchiveWriter.write(
                items: try ArchiveSourceEnumerator.items(
                    inDirectory: source.path, names: ["note.txt"]
                ),
                toArchiveAt: archive, encryption: .none, passphrase: nil
            )
            return try Data(contentsOf: URL(fileURLWithPath: archive))
        }
    }

    /// An ordinary UTF-8 archive — the narrowness control's fixture, and the only thing that stops
    /// "offer the chooser" from being implemented as "offer it whenever anything went wrong".
    private static func ordinaryArchive() throws -> (root: URL, path: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ordinary_gesture_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: source.appendingPathComponent("one.txt"))
        let path = root.appendingPathComponent("ordinary.zip").path
        try EncryptedArchiveWriter.write(
            items: try ArchiveSourceEnumerator.items(inDirectory: source.path, names: ["one.txt"]),
            toArchiveAt: path, encryption: .none, passphrase: nil
        )
        return (root, path)
    }

    /// A pane really standing inside `archivePath`, in a window, with its view loaded so a sheet
    /// has somewhere to attach.
    @MainActor
    private struct Probe {
        let pane: PanelViewController
        let window: NSWindow
        /// Held because `PanelViewController.host` is `weak`, and every funnel here begins
        /// `guard let cache = host?.archivePreviewCache` — so a host that has been deallocated
        /// makes each gesture return having done nothing, and the test then measures the no-host
        /// path while still naming the one it was written for.
        let host: StubPanelHost

        init(insideArchiveAt archivePath: String) throws {
            let composite = CompositeBackend(local: LocalBackend())
            let root = VFSPath(backend: .archive(forArchiveAt: archivePath), path: "/")
            let entries = try composite.listDirectory(at: root)
            window = TrashlessProbe.window()
            host = StubPanelHost()
            pane = PanelViewController(
                backend: composite, restoration: nil, defaultPath: root, restorationKey: nil
            )
            pane.host = host
            window.contentViewController = pane
            pane.loadViewIfNeeded()
            pane.panel = Panel(model: DirectoryModel(
                listing: DirectoryListing(path: root, entries: entries)
            ))
        }

        /// The row the pane drew for a name it could not decode — what a cursor would be on.
        func unreadableRow() throws -> FileEntry {
            try #require(
                pane.panel.displayedEntries.first { $0.name.contains("\u{FFFD}") },
                "the fixture should draw one row nobody can name"
            )
        }

        func putCursor(on entry: FileEntry) {
            let index = pane.panel.displayedEntries.firstIndex { $0.path == entry.path } ?? 0
            pane.panel.moveCursor(to: index)
        }
    }

    /// Which sheet is up, said structurally so it survives the app test target inheriting the
    /// developer's own `AppleLanguages` pin (docs/NOTES.md ▸ Localization).
    private enum Sheet {
        /// The code-page chooser: Use, Cancel and the popup that picks the encoding.
        static let chooser = 3
        /// Any plain report: one lone OK.
        static let report = 1
    }

    private static func sheet(over window: NSWindow) async throws -> Int {
        try await settleUntil { window.attachedSheet != nil }
        return sheetButtonCount(in: window)
    }

    // MARK: - The gestures that had no route

    @Test("⏎ on a row nobody can name offers the chooser")
    func openingAnUnnameableMemberOffersTheChooser() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let probe = try Probe(insideArchiveAt: fixture.path)
        let row = try probe.unreadableRow()

        probe.pane.beginArchiveMemberOpen(for: row)

        #expect(try await Self.sheet(over: probe.window) == Sheet.chooser)
    }

    @Test("F4 on that row offers it too")
    func editingAnUnnameableMemberOffersTheChooser() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let probe = try Probe(insideArchiveAt: fixture.path)
        let row = try probe.unreadableRow()

        probe.pane.beginArchiveMemberEdit(for: row)

        #expect(try await Self.sheet(over: probe.window) == Sheet.chooser)
    }

    /// ⌘Y / ⌃Q — the preview the user *asked* for, which is a different question from the one that
    /// follows the cursor (below).
    @Test("switching a preview on over that row offers the chooser")
    func openingThePreviewOffersTheChooser() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let probe = try Probe(insideArchiveAt: fixture.path)
        probe.putCursor(on: try probe.unreadableRow())

        probe.pane.openArchivePreview {}

        #expect(try await Self.sheet(over: probe.window) == Sheet.chooser)
    }

    @Test("⏎ into a nested archive named in a code page offers the chooser")
    func enteringANestedArchiveOffersTheChooser() async throws {
        let fixture = try Fixture(nesting: true)
        defer { fixture.cleanup() }
        let probe = try Probe(insideArchiveAt: fixture.path)
        let row = try probe.unreadableRow()

        probe.pane.beginNestedArchiveEntry(for: row)

        #expect(try await Self.sheet(over: probe.window) == Sheet.chooser)
    }

    /// The hand-offs that stage a member first — Open With, Share, checksum, compare, ⌥F5 pack.
    /// They share one funnel, so one test covers all of them, and the funnel is the half that had
    /// to be taught which archive refused: with several archives in one gesture only its own loop
    /// knows which of them got that far.
    @Test("a hand-off that stages that row offers the chooser")
    func materializingAnUnnameableMemberOffersTheChooser() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let probe = try Probe(insideArchiveAt: fixture.path)
        let row = try probe.unreadableRow()

        probe.pane.materialize(
            [row], for: .handOff, failureMessage: { "unused" }, then: { _ in }
        )

        #expect(try await Self.sheet(over: probe.window) == Sheet.chooser)
    }

    /// F2 rewrites the container, so it meets the same refusal the other rewrites do — and it is
    /// the gesture a user reaches for *because* the name is unreadable, which makes reporting it as
    /// an ordinary failure the least helpful answer available.
    @Test("F2 on a row nobody can name offers the chooser")
    func renamingAnUnnameableMemberOffersTheChooser() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let probe = try Probe(insideArchiveAt: fixture.path)
        let row = try probe.unreadableRow()

        probe.pane.renameArchiveMember(
            row.path, to: "readable.txt", oldName: row.name, inArchiveAt: fixture.path
        )

        #expect(try await Self.sheet(over: probe.window) == Sheet.chooser)
    }

    /// The half the failure-path test cannot see, and the one the user reported: F2 asks **before**
    /// it opens the field, so nothing they typed can be discarded by the answer.
    ///
    /// `renamingEntryID` is the observable, because `beginRename` sets it the moment it commits to
    /// the edit and before every view call — so `nil` here means the field never opened. The view is
    /// loaded for the reason `RenameReachTests` records: an unloaded pane's table has no columns, so
    /// a flow that wrongly got this far would return at `nameColumnDisplayIndex` instead and leave
    /// the assertion green whatever the guard did.
    @Test("F2 asks for the code page before opening the field, not after")
    func renameAsksBeforeTakingATypedName() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let probe = try Probe(insideArchiveAt: fixture.path)
        probe.putCursor(on: try probe.unreadableRow())

        probe.pane.beginRename()

        #expect(try await Self.sheet(over: probe.window) == Sheet.chooser)
        #expect(probe.pane.renamingEntryID == nil, "the field opened on a name nobody can read")
    }

    /// Its narrowness control, and the one that stops "ask first" becoming "always ask": an archive
    /// whose names are perfectly readable is not asked about at all.
    ///
    /// It drives the **decision** rather than the key, and that is a measured constraint rather than
    /// a preference. Driving `beginRename` to *success* opens a real field editor in a real window,
    /// and this suite's windows are retained for the life of the process — measured 2026-09-10, that
    /// **crashes the test host**: the run restarts, the summary still says `passed`, and the tests
    /// after it silently never run (9 tests against 2, same tree, the only difference being this one
    /// driven to success). `RenameReachTests` records the same rule for the same reason and drives
    /// only refusals. What the pair still pins between them is both halves: the positive test above
    /// drives the real `beginRename` and gets the sheet, so the key does consult this; and this one
    /// says the answer is no where the names are readable.
    @Test("an ordinary archive is not asked about at all")
    func aReadableArchiveIsNotAsked() throws {
        let (root, path) = try Self.ordinaryArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = try Probe(insideArchiveAt: path)

        #expect(probe.pane.archiveNamesAreUnreadable(at: path) == false)
        #expect(probe.pane.offerNameEncodingBeforeTyping(forArchiveAt: path) == false)
        #expect(probe.window.attachedSheet == nil, "a readable archive raised the chooser")
    }

    /// Answering the chooser has to leave the cursor on the row the gesture was about — reported
    /// 2026-09-10, it landed on a different file.
    ///
    /// **The sibling is named `a.txt` on purpose, and the suite is inert without it.** Declaring a
    /// code page only strands the cursor when the re-decode *reorders* the rows, and measured
    /// against `localizedStandardCompare`, the chooser's default CP437 reading of this fixture
    /// (`Åá¡«…`) still sorts before `plain.txt` — which is exactly why a live run with CP437 looked
    /// perfect while the report, made with CP866 (`Панорама.txt`, Cyrillic after Latin), did not.
    /// Against `a.txt` the default pick reorders, so the bug is reachable without driving the popup.
    ///
    /// The contents differ in **length** for the same kind of reason: what survives a re-decode is
    /// everything but the name, so two members of equal size and timestamp are an ambiguous match
    /// that ``DirnexCore/ArchiveMemberAnchor`` deliberately refuses.
    ///
    /// Driven through the bare chooser rather than through F2, because the cursor half belongs to
    /// every gesture that raises it — and because F2's resume opens a real field editor, which in a
    /// suite whose windows outlive the tests takes the host down with it.
    @Test("answering the chooser leaves the cursor on the row the gesture was about")
    func theChooserKeepsItsRow() async throws {
        let fixture = try Fixture(siblingName: "a.txt", siblingContents: "short")
        defer { fixture.cleanup() }
        let probe = try Probe(insideArchiveAt: fixture.path)
        let row = try probe.unreadableRow()
        probe.putCursor(on: row)

        probe.pane.askForNameEncoding(forArchiveAt: fixture.path)
        try await settleUntil { probe.window.attachedSheet != nil }
        try Self.pressUse(on: probe.window)
        try await settleUntil {
            probe.pane.panel.displayedEntries.allSatisfy { !$0.name.contains("\u{FFFD}") }
        }

        let landed = try #require(probe.pane.panel.currentEntry)
        #expect(landed.byteSize == row.byteSize, "the cursor moved to a different file")
        #expect(!landed.name.contains("\u{FFFD}"), "the names did not re-decode")
    }

    /// The confirming button carries no `keyEquivalent` on macOS 26 — Return lives on the window's
    /// `defaultButtonCell` — so a scan for `"\r"` finds nothing and reads as a sheet with no default
    /// button (docs/NOTES.md ▸ Localization). Never a title match: this target inherits whatever
    /// `AppleLanguages` Dirnex is pinned to.
    private static func pressUse(on window: NSWindow) throws {
        let sheet = try #require(window.attachedSheet)
        let button = try #require(sheet.defaultButtonCell?.controlView as? NSButton)
        button.performClick(nil)
    }

    // MARK: - Narrowness

    /// Without this, "offer the chooser" passes implemented as "offer it whatever went wrong" —
    /// putting a code-page question over an archive whose names are perfectly fine and whose member
    /// is simply not there.
    @Test("a member missing from an ordinary archive still just reports the failure")
    func anOrdinaryFailureIsStillReported() async throws {
        let (root, path) = try Self.ordinaryArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = try Probe(insideArchiveAt: path)
        let real = try #require(probe.pane.panel.displayedEntries.first { $0.name == "one.txt" })
        // A row that names a member the archive does not hold: the same shape a stale listing hands
        // over, and the failure the chooser must not be offered for.
        let ghost = FileEntry(
            path: VFSPath(backend: real.path.backend, path: "/not-there.txt"),
            name: "not-there.txt",
            kind: .file,
            byteSize: 1,
            modificationDate: real.modificationDate,
            creationDate: real.creationDate,
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )

        probe.pane.beginArchiveMemberOpen(for: ghost)

        #expect(try await Self.sheet(over: probe.window) == Sheet.report)
    }

    /// The one deliberate silence, and the reason this is not "offer it everywhere": the preview
    /// that follows the **cursor** meets the identical refusal on every arrow key, and a sheet
    /// raised because the cursor came to rest somewhere is a question nobody asked.
    @Test("the preview following the cursor asks nothing at all")
    func thePassivePreviewStaysSilent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let probe = try Probe(insideArchiveAt: fixture.path)
        probe.putCursor(on: try probe.unreadableRow())

        probe.pane.prepareArchivePreview {}

        // Settled by work already in flight rather than by a constant: the gesture above raises its
        // sheet through the same extraction, on its own pane, and its task is created after this
        // one's — so a sheet this pane was going to raise would have arrived by the time that one
        // has (docs/NOTES.md ▸ Testing, `holdOutTheAutomaticFetchDelay`).
        let witness = try Probe(insideArchiveAt: fixture.path)
        witness.pane.beginArchiveMemberOpen(for: try witness.unreadableRow())
        try await settleUntil { witness.window.attachedSheet != nil }

        #expect(probe.window.attachedSheet == nil, "the cursor-following preview raised a sheet")
    }
}
