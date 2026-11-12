import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// A request from `git mergetool` through to the merge window and back (PLAN.md §M37 Slice 6), over
/// real files in a scratch folder. The window is the real one, built and never shown.
@Suite("git merge tool: the merge window")
@MainActor
struct GitMergeServiceTests {
    /// Choose yours for every conflict.
    private func resolve(_ controller: MergeWindowController) throws {
        for _ in try #require(controller.merge).choices {
            controller.take(.yours)
        }
        #expect(controller.merge?.isResolved == true)
    }

    @Test("a window closed without a save answers not saved, once")
    func closedUnsaved() async throws {
        let rig = try GitMergeRig()
        defer { rig.cleanup() }
        try rig.writeConflict()
        let controller = try await rig.open()
        #expect(rig.answers.isEmpty)
        #expect(rig.service.sessions.count == 1)
        controller.window?.close()
        #expect(rig.answers == [.notSaved])
        #expect(rig.service.sessions.isEmpty)
    }

    @Test("Save writes the working-tree file alone, and closing then answers saved")
    func savedThenClosed() async throws {
        let rig = try GitMergeRig()
        defer { rig.cleanup() }
        try rig.writeConflict()
        let before = rig.contentsOfFolder
        let locals = try ["a_LOCAL_1.txt", "a_BASE_1.txt", "a_REMOTE_1.txt"].map { try rig.read($0) }
        let controller = try await rig.open()
        try resolve(controller)
        #expect(await controller.saveResult())
        #expect(rig.answers.isEmpty)
        #expect(try rig.read("a.txt") == "1\nY\n3\n")
        #expect(rig.contentsOfFolder == before)
        #expect(
            try ["a_LOCAL_1.txt", "a_BASE_1.txt", "a_REMOTE_1.txt"].map { try rig.read($0) } == locals
        )
        controller.window?.close()
        #expect(rig.answers == [.saved])
    }

    @Test("a merge with no conflict left still has to be saved to count")
    func noConflict() async throws {
        let rig = try GitMergeRig()
        defer { rig.cleanup() }
        try rig.writeConflict()
        try rig.write("a_REMOTE_1.txt", "1\n2\n3\n")
        let controller = try await rig.open()
        #expect(controller.merge?.choices.isEmpty == true)
        #expect(controller.canSave)
        controller.window?.close()
        #expect(rig.answers == [.notSaved])
    }

    @Test("a choice changed after a save still answers saved, since the file holds a whole result")
    func changedAfterSave() async throws {
        let rig = try GitMergeRig()
        defer { rig.cleanup() }
        try rig.writeConflict()
        let controller = try await rig.open()
        try resolve(controller)
        #expect(await controller.saveResult())
        controller.goToConflict(0)
        controller.take(.theirs)
        #expect(controller.hasUnsavedChoices)
        controller.window?.close()
        #expect(rig.answers == [.saved])
        #expect(try rig.read("a.txt") == "1\nY\n3\n")
    }

    @Test("quitting answers each open merge as it stands")
    func stopping() async throws {
        let rig = try GitMergeRig()
        defer { rig.cleanup() }
        try rig.writeConflict()
        let saved = try await rig.open()
        try resolve(saved)
        #expect(await saved.saveResult())
        _ = try await rig.open()
        rig.service.stop()
        #expect(rig.answers == [.saved, .notSaved])
        #expect(rig.service.sessions.isEmpty)
    }

    @Test("a window closing after the quit's answer does not answer again")
    func answersOnce() async throws {
        let rig = try GitMergeRig()
        defer { rig.cleanup() }
        try rig.writeConflict()
        let controller = try await rig.open()
        rig.service.stop()
        controller.window?.close()
        #expect(rig.answers == [.notSaved])
    }

    @Test("a session answers once, however often it is finished")
    func finishesOnce() {
        var answers: [GitMergeAnswer] = []
        let session = GitMergeSession { answers.append($0) }
        session.finish()
        session.finish()
        #expect(answers == [.notSaved])
    }

    @Test("two merges at once answer separately")
    func twoMerges() async throws {
        let rig = try GitMergeRig()
        defer { rig.cleanup() }
        try rig.writeConflict()
        let first = try await rig.open()
        let second = try await rig.open()
        first.window?.close()
        #expect(rig.answers == [.notSaved])
        #expect(rig.service.sessions.count == 1)
        try resolve(second)
        #expect(await second.saveResult())
        second.window?.close()
        #expect(rig.answers == [.notSaved, .saved])
    }
}
