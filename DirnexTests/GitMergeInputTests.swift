import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// What a merge window for `git mergetool` is opened on, and what stops it opening (PLAN.md §M37
/// Slice 6).
@Suite("git merge tool: what the window opens on")
@MainActor
struct GitMergeInputTests {
    @Test("the window names the file and saves over the working-tree file")
    func input() async throws {
        let rig = try GitMergeRig()
        defer { rig.cleanup() }
        try rig.writeConflict()
        let controller = try await rig.open()
        #expect(controller.input.name == "a.txt")
        #expect(controller.input.target.path == rig.path("a.txt"))
        #expect(controller.input.resultDetail == GitMergeDocuments.resultDetail)
        #expect(controller.input.base.document.lines.map(\.content) == ["1", "2", "3"])
        #expect(controller.input.yours.document.lines.map(\.content) == ["1", "Y", "3"])
        #expect(controller.input.theirs.document.lines.map(\.content) == ["1", "T", "3"])
        #expect(controller.input.base.detail == PanelViewController.conflictBaseDetail)
    }

    @Test("an empty base is both sides adding the file, and the sides still merge")
    func emptyBase() async throws {
        let rig = try GitMergeRig()
        defer { rig.cleanup() }
        try rig.writeConflict(base: "")
        let controller = try await rig.open()
        #expect(controller.input.base.detail == PanelViewController.conflictNoBaseDetail)
        #expect(controller.merge?.choices.count == 1)
    }

    @Test("a base that isn't there is an empty one, not a refusal")
    func missingBase() async throws {
        let rig = try GitMergeRig()
        defer { rig.cleanup() }
        try rig.writeConflict()
        try FileManager.default.removeItem(atPath: rig.path("a_BASE_1.txt"))
        let controller = try await rig.open()
        #expect(rig.refusals.isEmpty)
        #expect(controller.input.base.detail == PanelViewController.conflictNoBaseDetail)
    }

    /// Answers `rev-parse --absolute-git-dir` with a folder of the test's own.
    private struct GitDirectory: GitTransport {
        let directory: String

        func run(_ arguments: [String]) throws(GitRunFailure) -> Data {
            Data((directory + "\n").utf8)
        }
    }

    @Test("each side is named for the operation in progress, as Resolve Conflict… names it")
    func rebaseWords() async throws {
        let rig = try GitMergeRig()
        defer { rig.cleanup() }
        try rig.writeConflict()
        try FileManager.default.createDirectory(
            atPath: rig.path("git/rebase-merge"),
            withIntermediateDirectories: true
        )
        let read = GitMergeDocuments.read(
            rig.request,
            transport: GitDirectory(directory: rig.path("git"))
        )
        let documents = try read.get()
        let input = GitMergeDocuments.mergeInput(for: rig.request, documents)
        #expect(documents.operation == .rebase)
        #expect(input.yours.detail == PanelViewController.conflictYoursDetail(.rebase))
        #expect(input.theirs.detail == PanelViewController.conflictTheirsDetail(.rebase))
    }

    /// git that fails every run, as on a Mac without it.
    private struct NoGit: GitTransport {
        func run(_ arguments: [String]) throws(GitRunFailure) -> Data {
            throw GitRunFailure(status: nil, message: "")
        }
    }

    @Test("without git the merge still opens, with the plain words")
    func noGit() throws {
        let rig = try GitMergeRig()
        defer { rig.cleanup() }
        try rig.writeConflict()
        #expect(
            try GitMergeDocuments.read(rig.request, transport: NoGit()).get().operation == .other
        )
    }

    @Test("the file's name picks the grammar")
    func language() throws {
        let rig = try GitMergeRig()
        defer { rig.cleanup() }
        try rig.writeConflict()
        let request = GitMergeRequest(
            local: rig.request.local,
            base: rig.request.base,
            remote: rig.request.remote,
            merged: rig.path("a.swift")
        )
        let documents = try GitMergeDocuments.read(request, transport: NoGit()).get()
        #expect(
            GitMergeDocuments.mergeInput(for: request, documents).language == SyntaxLanguage.forFile(
                named: "a.swift",
                text: ""
            )
        )
    }

    // MARK: - Refusals

    private func expectRefused(_ rig: GitMergeRig, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        await rig.service.open(rig.request) { [unowned rig] in rig.answers.append($0) }
        #expect(rig.windows.isEmpty, sourceLocation: sourceLocation)
        #expect(rig.service.sessions.isEmpty, sourceLocation: sourceLocation)
        let refusal = try #require(rig.refusals.first, sourceLocation: sourceLocation)
        #expect(
            refusal.title == PanelViewController.resolveFailureTitle("a.txt"),
            sourceLocation: sourceLocation
        )
        #expect(rig.answers == [.refused(refusal.detail)], sourceLocation: sourceLocation)
    }

    @Test("a binary side is refused by name, and the command told why")
    func binary() async throws {
        let rig = try GitMergeRig()
        defer { rig.cleanup() }
        try rig.writeConflict()
        try Data([0, 1, 2, 0, 3]).write(to: URL(fileURLWithPath: rig.path("a_LOCAL_1.txt")))
        try await expectRefused(rig)
        #expect(rig.refusals.first?.detail == CompareOpener.failureDetail(
            CompareReadFailure(name: "a.txt", reason: .binary)
        ))
    }

    @Test("a side over the merge window's limit is refused without being read")
    func tooLarge() async throws {
        let rig = try GitMergeRig()
        defer { rig.cleanup() }
        try rig.writeConflict()
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: rig.path("a_REMOTE_1.txt")))
        try handle.truncate(atOffset: UInt64(ByteComparator.prescanByteLimit) + 1)
        try handle.close()
        try await expectRefused(rig)
        #expect(
            rig.refusals.first?.detail == CompareOpener.limitDetail(ByteComparator.prescanByteLimit)
        )
    }

    @Test("a side that can't be read is refused")
    func unreadable() async throws {
        let rig = try GitMergeRig()
        defer { rig.cleanup() }
        try rig.writeConflict()
        try FileManager.default.removeItem(atPath: rig.path("a_LOCAL_1.txt"))
        try await expectRefused(rig)
    }

    @Test("the refusal waits for the alert before it answers the command")
    func refusalWaits() async throws {
        let rig = try GitMergeRig()
        defer { rig.cleanup() }
        try rig.writeConflict()
        try Data([0]).write(to: URL(fileURLWithPath: rig.path("a_LOCAL_1.txt")))
        var answersDuringAlert: [GitMergeAnswer]?
        let collected = AnswerBox()
        let service = GitMergeService(
            openWindow: { _, _ in fatalError("no window for a refusal") },
            refuse: { _, _ in answersDuringAlert = collected.answers }
        )
        await service.open(rig.request) { collected.answers.append($0) }
        #expect(answersDuringAlert == [])
        #expect(collected.answers.count == 1)
    }

    @MainActor
    private final class AnswerBox {
        var answers: [GitMergeAnswer] = []
    }
}
