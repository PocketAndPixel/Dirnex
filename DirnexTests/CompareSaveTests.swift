import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// A compare window over two real files in a temporary folder, read through the opener, so each
/// side has the target a save writes (PLAN.md §M33 Slice 3).
@MainActor
struct CompareSaveRig {
    let directory: URL
    let controller: CompareWindowController
    /// What the window's saves filed with the browser window's journal.
    let journal: JournalBox

    final class JournalBox {
        var records: [UndoRecord] = []
    }

    init(_ left: Data, _ right: Data, store: ArchiveUndoStore? = nil, rightOrigin: VFSPath? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-compare-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let leftURL = directory.appendingPathComponent("left.txt")
        let rightURL = directory.appendingPathComponent("right.txt")
        try left.write(to: leftURL)
        try right.write(to: rightURL)
        let (leftSource, rightSource) = try CompareOpener.sources(
            CompareFile(path: .local(leftURL.path), origin: .local(leftURL.path)),
            detail: "",
            CompareFile(path: .local(rightURL.path), origin: rightOrigin ?? .local(rightURL.path)),
            detail: ""
        ).get()
        let journal = JournalBox()
        self.journal = journal
        controller = CompareWindowController(
            left: leftSource,
            right: rightSource,
            saving: CompareSaving(
                undo: { ArchiveUndoStorage.Request(store: store, live: []) },
                journal: { journal.records.append($0) }
            )
        )
        controller.show(CompareWindowController.prepare(
            left: leftSource,
            right: rightSource,
            options: LineDiffOptions(),
            coloringLimit: CompareTextStyle.syntaxColoringLimit
        ))
        Self.retained.append(controller)
    }

    init(_ left: String, _ right: String, store: ArchiveUndoStore? = nil) throws {
        try self.init(Data(left.utf8), Data(right.utf8), store: store)
    }

    /// Every window a rig built, kept for the life of the test host: tearing down a window whose
    /// sheet is still settling crashes a later test (docs/NOTES.md ▸ Testing).
    private static var retained: [CompareWindowController] = []

    var leftPath: String { directory.appendingPathComponent("left.txt").path }
    var rightPath: String { directory.appendingPathComponent("right.txt").path }

    func contents(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? "<none>"
    }

    /// Copy the current change to `side` and wait for the comparison of the result.
    func copy(to side: ComparisonPaneText.Side) async throws {
        controller.copyCurrentChange(to: side)
        try await settleUntil { controller.comparedRevision == controller.sidesRevision }
    }

    /// The sheet on the window once it is up.
    func sheet() async throws -> NSWindow {
        try await settleUntil { controller.window?.attachedSheet != nil }
        return try #require(controller.window?.attachedSheet)
    }

    func answer(_ response: NSApplication.ModalResponse) async throws {
        try controller.window?.endSheet(await sheet(), returnCode: response)
    }

    func cleanup() {
        if let window = controller.window, let sheet = window.attachedSheet {
            window.endSheet(sheet)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Every label's text under `view`, for what an alert says.
    static func texts(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { texts(in: $0) }
    }

    /// Every button under `view`, for an alert's keys.
    static func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        let own = (view as? NSButton).map { [$0] } ?? []
        return own + view.subviews.flatMap { buttons(in: $0) }
    }

    static let commandS = command("s", keyCode: 1)
    static let commandW = command("w", keyCode: 13)

    /// The key-down a real ⌘ and `character` would send.
    private static func command(_ character: String, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        ) ?? NSEvent()
    }
}

/// Saving in the compare window: ⌘S, the question when the file changed since it was read, and the
/// refusals. What the save does to the file is `DirnexCore`'s and tested there; these pin the
/// window's half.
@Suite("Compare window saves")
@MainActor
struct CompareSaveTests {
    @Test("⌘S writes the copied lines, clears the edited marks and journals an undoable save")
    func commandSSaves() async throws {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-compare-save-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: store) }
        let rig = try CompareSaveRig("a\nB\nc\n", "a\nb\nc\n", store: ArchiveUndoStore(root: store))
        defer { rig.cleanup() }
        try await rig.copy(to: .right)
        #expect(rig.controller.unsavedSides == [.right])

        #expect(rig.controller.handleKey(CompareSaveRig.commandS))
        try await settleUntil { rig.controller.window?.isDocumentEdited == false }

        #expect(rig.contents(rig.rightPath) == "a\nB\nc\n")
        #expect(rig.contents(rig.leftPath) == "a\nB\nc\n")
        #expect(rig.controller.unsavedSides.isEmpty)
        #expect(rig.controller.rightPane.nameLabel.stringValue == "right.txt")
        let record = try #require(rig.journal.records.first)
        #expect(rig.journal.records.count == 1)
        #expect(record.label == .saveFile)
        // What ⌘Z in a pane runs.
        #expect(UndoJournal.revert(record, using: LocalBackend()).succeeded)
        #expect(rig.contents(rig.rightPath) == "a\nb\nc\n")
    }

    @Test("an undo in the window after a save marks the side edited again, and a second ⌘S saves it")
    func undoPastASave() async throws {
        let rig = try CompareSaveRig("a\nB\nc\n", "a\nb\nc\n")
        defer { rig.cleanup() }
        try await rig.copy(to: .right)
        #expect(await rig.controller.saveEditedSides())

        rig.controller.edits.undo()
        try await settleUntil { rig.controller.comparedRevision == rig.controller.sidesRevision }
        #expect(rig.controller.unsavedSides == [.right])
        #expect(rig.controller.window?.isDocumentEdited == true)
        #expect(await rig.controller.saveEditedSides())
        #expect(rig.contents(rig.rightPath) == "a\nb\nc\n")
    }

    @Test("a file changed since it was read asks first, and Save Anyway writes over it")
    func changedFileAsks() async throws {
        let rig = try CompareSaveRig("a\nB\nc\n", "a\nb\nc\n")
        defer { rig.cleanup() }
        try await rig.copy(to: .right)
        try Data("somebody else's\n".utf8).write(to: URL(fileURLWithPath: rig.rightPath))

        let saving = Task { await rig.controller.saveEditedSides() }
        try await rig.answer(.alertFirstButtonReturn)
        #expect(await saving.value)
        #expect(rig.contents(rig.rightPath) == "a\nB\nc\n")
    }

    @Test("Cancel leaves the other app's change, and the side stays edited")
    func changedFileCancelled() async throws {
        let rig = try CompareSaveRig("a\nB\nc\n", "a\nb\nc\n")
        defer { rig.cleanup() }
        try await rig.copy(to: .right)
        try Data("somebody else's\n".utf8).write(to: URL(fileURLWithPath: rig.rightPath))

        let saving = Task { await rig.controller.saveEditedSides() }
        try await rig.answer(.alertSecondButtonReturn)
        #expect(await saving.value == false)
        #expect(rig.contents(rig.rightPath) == "somebody else's\n")
        #expect(rig.controller.unsavedSides == [.right])
    }

    @Test("a character the file's encoding cannot hold is reported, and nothing is written")
    func unencodableIsReported() async throws {
        let latin = try #require("a\ncafé\n".data(using: .isoLatin1))
        let rig = try CompareSaveRig(latin, Data("a\nfrom → to\n".utf8))
        defer { rig.cleanup() }
        try await rig.copy(to: .left)

        let saving = Task { await rig.controller.saveEditedSides() }
        let sheet = try await rig.sheet()
        #expect(
            CompareSaveRig.texts(in: sheet.contentView).contains { $0.contains("“→” on line 2") }
        )
        rig.controller.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        #expect(await saving.value == false)
        #expect(try Data(contentsOf: URL(fileURLWithPath: rig.leftPath)) == latin)
        #expect(rig.controller.unsavedSides == [.left])
    }

    @Test("the line named for an unencodable character counts from 1, as the panes do")
    func unencodableDetailCountsFromOne() {
        let detail = CompareWindowController.unencodableDetail("→", line: 41, in: .isoLatin1)
        #expect(detail.contains("“→” on line 42"))
        #expect(detail.contains(String.localizedName(of: .isoLatin1)))
    }

    @Test("Swap Sides takes each file's target with it, so ⌘S writes the file that was copied into")
    func swapKeepsTargets() async throws {
        let rig = try CompareSaveRig("a\nB\nc\n", "a\nb\nc\n")
        defer { rig.cleanup() }
        try await rig.copy(to: .right)
        rig.controller.swapSides()
        try await settleUntil { rig.controller.comparedRevision == rig.controller.sidesRevision }
        #expect(rig.controller.unsavedSides == [.left])

        #expect(await rig.controller.saveEditedSides())
        #expect(rig.contents(rig.rightPath) == "a\nB\nc\n")
    }

    @Test("a copy of a server file has no target, so ⌘S has nothing to save and beeps")
    func serverSideIsNotSaved() async throws {
        let server = VFSPath(backend: Handoff.remoteID, path: "/srv/right.txt")
        let rig = try CompareSaveRig(
            Data("a\nB\nc\n".utf8),
            Data("a\nb\nc\n".utf8),
            rightOrigin: server
        )
        defer { rig.cleanup() }
        #expect(rig.controller.right.target == nil)
        #expect(rig.controller.left.target == .reading(rig.leftPath))
        try await rig.copy(to: .right)

        #expect(rig.controller.unsavedSides.isEmpty)
        #expect(rig.controller.handleKey(CompareSaveRig.commandS))
        #expect(rig.controller.isSaving == false)
        #expect(rig.contents(rig.rightPath) == "a\nb\nc\n")
    }
}
