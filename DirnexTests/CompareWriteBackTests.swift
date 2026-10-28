import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Saving a server file or an archive member from the compare window (PLAN.md §M33 Slice 4). The
/// window writes the copy it read and hands it to F4's write-back, and the side is saved once that
/// lands. The write-back's own check, question and upload are the browser window's and are tested
/// with it; these pin what the window hands over, when, and what it does with the answer.
@Suite("Compare window write-back")
@MainActor
struct CompareWriteBackTests {
    private static let server = VFSPath(backend: Handoff.remoteID, path: "/srv/right.txt")

    /// What the Synchronize window would hear.
    private final class Heard {
        var origins: [VFSPath] = []
        var observer: (any NSObjectProtocol)?
    }

    private func serverRig(_ origin: VFSPath = server) throws -> CompareSaveRig {
        try CompareSaveRig(
            Data("a\nB\nc\n".utf8),
            Data("a\nb\nc\n".utf8),
            rightOrigin: origin,
            rightWriteBack: .remoteFile(origin)
        )
    }

    private func listen() -> Heard {
        let heard = Heard()
        heard.observer = NotificationCenter.default.addObserver(
            forName: CompareWindowController.fileSaved,
            object: nil,
            queue: nil
        ) { [heard] notification in
            if let origin = CompareWindowController.savedOrigin(in: notification) {
                heard.origins.append(origin)
            }
        }
        return heard
    }

    private func stopListening(_ heard: Heard) {
        heard.observer.map(NotificationCenter.default.removeObserver)
    }

    @Test("⌘S writes a server file's copy, hands it over on this window, and saves once it lands")
    func serverSideIsCarriedBack() async throws {
        let rig = try serverRig()
        defer { rig.cleanup() }
        #expect(rig.controller.right.target == .reading(rig.rightPath))
        try await rig.copy(to: .right)
        #expect(rig.controller.unsavedSides == [.right])

        #expect(rig.controller.handleKey(CompareSaveRig.commandS))
        try await settleUntil { rig.controller.window?.isDocumentEdited == false }

        let call = try #require(rig.writeBacks.calls.first)
        #expect(rig.writeBacks.calls.count == 1)
        #expect(call.edit.destination == .remoteFile(Self.server))
        #expect(call.edit.temporaryURL.path == rig.rightPath)
        #expect(call.edit.name == "right.txt")
        #expect(
            String(bytes: call.bytes, encoding: .utf8) == "a\nB\nc\n",
            "the copy is written before it is handed over"
        )
        #expect(call.host === rig.controller.window, "the questions go on the compare window")
        #expect(rig.journal.records.isEmpty, "an upload keeps no undo")
        #expect(rig.controller.unsavedSides.isEmpty)
    }

    @Test("a write-back that does not land leaves the side edited, and ⌘S carries it again")
    func unlandedWriteBackStaysEdited() async throws {
        let rig = try serverRig()
        defer { rig.cleanup() }
        try await rig.copy(to: .right)
        rig.writeBacks.answer = false

        #expect(await rig.controller.saveEditedSides() == false)
        #expect(rig.contents(rig.rightPath) == "a\nB\nc\n")
        #expect(rig.controller.unsavedSides == [.right])
        #expect(rig.controller.window?.isDocumentEdited == true)

        // The window wrote the copy itself, so the next save does not ask whether it changed.
        rig.writeBacks.answer = true
        let saving = Task { await rig.controller.saveEditedSides() }
        try await settleUntil {
            rig.writeBacks.calls.count == 2 || rig.controller.window?.attachedSheet != nil
        }
        let asked = rig.controller.window?.attachedSheet != nil
        if asked { try await rig.answer(.alertSecondButtonReturn) }
        #expect(!asked, "the window's own write is not a change made behind its back")
        #expect(await saving.value)
        #expect(rig.controller.unsavedSides.isEmpty)
    }

    @Test("a copy changed since the window read it asks first, and Cancel hands nothing over")
    func changedCopyAsks() async throws {
        let rig = try serverRig()
        defer { rig.cleanup() }
        try await rig.copy(to: .right)
        try Data("the editor's save\n".utf8).write(to: URL(fileURLWithPath: rig.rightPath))

        let saving = Task { await rig.controller.saveEditedSides() }
        try await rig.answer(.alertSecondButtonReturn)
        #expect(await saving.value == false)
        #expect(rig.writeBacks.calls.isEmpty)
        #expect(rig.contents(rig.rightPath) == "the editor's save\n")
    }

    @Test("an archive member's copy goes back with its archive and the folder inside it")
    func archiveMemberIsCarriedBack() async throws {
        let archive = "/tmp/dirnex-compare-\(UUID().uuidString).zip"
        let member = VFSPath(backend: .archive(forArchiveAt: archive), path: "/docs/right.txt")
        let rig = try CompareSaveRig(
            Data("a\nB\nc\n".utf8),
            Data("a\nb\nc\n".utf8),
            rightOrigin: member,
            rightWriteBack: .archiveMember(archivePath: archive, innerDirectory: "/docs")
        )
        defer { rig.cleanup() }
        try await rig.copy(to: .right)

        #expect(await rig.controller.saveEditedSides())
        let call = try #require(rig.writeBacks.calls.first)
        #expect(
            call.edit.destination == .archiveMember(archivePath: archive, innerDirectory: "/docs")
        )
        #expect(String(bytes: call.bytes, encoding: .utf8) == "a\nB\nc\n")
        #expect(rig.journal.records.isEmpty, "the rewrite journals its own undo, not the window")
    }

    @Test("a file with nowhere to go back to takes no copy, and the banner says why")
    func nowhereToSaveIsReadOnly() async throws {
        let rig = try CompareSaveRig(
            Data("a\nB\nc\n".utf8),
            Data("a\nb\nc\n".utf8),
            rightOrigin: Self.server
        )
        defer { rig.cleanup() }
        #expect(rig.controller.right.target == nil)
        #expect(!rig.controller.canCopy(to: .right))
        #expect(rig.controller.canCopy(to: .left))
        #expect(!rig.controller.toolbar.copy.isEnabled(forSegment: 1))
        #expect(rig.controller.banner.stringValue.hasSuffix(
            "The right file is read-only here: Dirnex can’t save it back where it came from."
        ))
        rig.controller.copyCurrentChange(to: .right)
        #expect(rig.controller.edits.canUndo == false)
        #expect(rig.controller.unsavedSides.isEmpty)
        #expect(rig.controller.handleKey(CompareSaveRig.commandS))
        #expect(rig.writeBacks.calls.isEmpty)

        // The control: the same copy with somewhere to go back to takes copies.
        let carried = try serverRig()
        defer { carried.cleanup() }
        #expect(carried.controller.canCopy(to: .right))
        #expect(!carried.controller.banner.stringValue.contains("read-only"))
    }

    /// Each file is named by a path of its own, since other suites' windows save meanwhile.
    @Test(
        "a save that lands names its file to the Synchronize window, and one that does not, nothing"
    )
    func saveIsAnnounced() async throws {
        let origin = VFSPath(backend: Handoff.remoteID, path: "/srv/\(UUID().uuidString)/right.txt")
        let heard = listen()
        defer { stopListening(heard) }
        // Two windows rather than two saves in one, so a save that went wrong fails here rather
        // than waiting on a question nobody answers.
        let unlanded = try serverRig(origin)
        defer { unlanded.cleanup() }
        try await unlanded.copy(to: .right)
        unlanded.writeBacks.answer = false
        #expect(await unlanded.controller.saveEditedSides() == false)
        #expect(!heard.origins.contains(origin))

        let landed = try serverRig(origin)
        defer { landed.cleanup() }
        try await landed.copy(to: .right)
        #expect(await landed.controller.saveEditedSides())
        #expect(heard.origins.filter { $0 == origin }.count == 1, "named where it lives")
        #expect(!heard.origins.contains(.local(landed.rightPath)), "not by the copy")
    }

    @Test("a local save is announced too, by its own path")
    func localSaveIsAnnounced() async throws {
        let rig = try CompareSaveRig("a\nB\nc\n", "a\nb\nc\n")
        defer { rig.cleanup() }
        let heard = listen()
        defer { stopListening(heard) }
        try await rig.copy(to: .right)

        #expect(await rig.controller.saveEditedSides())
        #expect(heard.origins.filter { $0 == .local(rig.rightPath) }.count == 1)
        #expect(rig.writeBacks.calls.isEmpty, "a local file is written in place")
    }
}
