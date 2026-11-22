import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// ⌘Z and ⇧⌘Z on a change only an administrator can put back (PLAN.md §M40 Slice 5): the controller
/// asks before it takes the step, runs the root part, then the rest.
///
/// No test can type the password, so the seams are Slice 4's: an `actor` who owns none of the files,
/// so every change to them needs root, and the transport with its administrator flag off, which runs
/// the same script through the same `doShellScript`. The dialog is the `consent` closure.
@Suite("Undo ▸ as administrator")
@MainActor
struct AdministratorUndoTests {
    /// Someone who owns nothing in the scratch folder.
    private let stranger = UserContext(userID: getuid() + 1, groupIDs: [])

    private static let plainShell: UndoController.AdministratorTransport = {
        try await AdministratorShell.run($0, privileged: false)
    }

    /// What the dialog was asked, and what it answers.
    @MainActor
    private final class Dialog {
        var answer: Bool
        var asked: [(items: [VFSPath], direction: UndoDirection)] = []
        var whileUp: (() -> Void)?

        init(answer: Bool) { self.answer = answer }

        func consent(_ batch: EscalatedAttributeBatch, _ direction: UndoDirection) async -> Bool {
            asked.append((batch.items.map(\.path), direction))
            whileUp?()
            return answer
        }
    }

    /// A scratch folder holding files changed from 0644 to 0600, and a controller whose journal holds
    /// that change as one record.
    private struct Fixture {
        let controller: UndoController
        let urls: [URL]
        let folder: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func changed(
        _ names: [String],
        file: String = #fileID,
        function: String = #function
    ) throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdministratorUndo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        var entries: [UndoRecord.AttributeBatchEntry] = []
        var urls: [URL] = []
        for name in names {
            let url = folder.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            chmod(url.path, 0o644)
            let old = try FileAttributeIO.read(at: .local(url.path)).attributes
            chmod(url.path, 0o600)
            let new = try FileAttributeIO.read(at: .local(url.path)).attributes
            entries.append(.init(path: .local(url.path), actsOnLink: false, old: old, new: new))
            urls.append(url)
        }
        let controller = UndoController(
            backend: LocalBackend(),
            defaults: ScratchDefaults.fresh(file: file, function: function)
        )
        controller.record(try #require(UndoRecord.attributeBatchChange(entries)))
        return Fixture(controller: controller, urls: urls, folder: folder)
    }

    private func mode(_ url: URL) throws -> Int {
        try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        )
    }

    // MARK: - Asking

    @Test("Cancel in the dialog leaves the step where it was, and changes nothing")
    func cancelLeavesTheStep() async throws {
        let fixture = try changed(["a.txt", "b.txt"])
        defer { fixture.cleanup() }
        let (controller, urls) = (fixture.controller, fixture.urls)
        let dialog = Dialog(answer: false)

        let outcome = await controller.undo(
            actor: stranger, consent: dialog.consent, shell: Self.plainShell
        )

        #expect(outcome == nil)
        #expect(dialog.asked.count == 1)
        #expect(dialog.asked.first?.items == urls.map { .local($0.path) })
        #expect(dialog.asked.first?.direction == .undo)
        #expect(controller.nextLabel == .changeAttributes)
        #expect(controller.nextRedoLabel == nil)
        #expect(try urls.map(mode) == [0o600, 0o600])
    }

    @Test("Authenticate runs the root part and then the rest, and the step moves to redo")
    func authenticateUndoesTheStep() async throws {
        let fixture = try changed(["a.txt", "b.txt"])
        defer { fixture.cleanup() }
        let (controller, urls) = (fixture.controller, fixture.urls)

        let outcome = await controller.undo(
            actor: stranger, consent: Dialog(answer: true).consent, shell: Self.plainShell
        )

        guard case let .fileOperation(record, report, administrator) = outcome else {
            Issue.record("expected a file operation, got \(String(describing: outcome))")
            return
        }
        #expect(record.label == .changeAttributes)
        #expect(report.succeeded)
        #expect(administrator?.outcome.unchanged.isEmpty == true)
        #expect(administrator?.wasCancelled == false)
        #expect(try urls.map(mode) == [0o644, 0o644])
        #expect(controller.nextLabel == nil)
        #expect(controller.nextRedoLabel == .changeAttributes)
    }

    @Test("Cancel at the password, before anything ran, leaves the step where it was")
    func passwordCancelLeavesTheStep() async throws {
        let fixture = try changed(["a.txt"])
        defer { fixture.cleanup() }
        let (controller, urls) = (fixture.controller, fixture.urls)

        let outcome = await controller.undo(
            actor: stranger,
            consent: Dialog(answer: true).consent,
            shell: { _ in throw AdministratorShell.Failure.cancelled }
        )

        #expect(outcome == nil)
        #expect(controller.nextLabel == .changeAttributes)
        #expect(controller.nextRedoLabel == nil)
        #expect(try mode(urls[0]) == 0o600)
    }

    @Test("Redo of it asks too, and re-applies the change")
    func redoAsksToo() async throws {
        let fixture = try changed(["a.txt"])
        defer { fixture.cleanup() }
        let (controller, urls) = (fixture.controller, fixture.urls)
        let dialog = Dialog(answer: true)
        _ = await controller.undo(actor: stranger, consent: dialog.consent, shell: Self.plainShell)
        #expect(try mode(urls[0]) == 0o644)

        let outcome = await controller.redo(
            actor: stranger, consent: dialog.consent, shell: Self.plainShell
        )

        #expect(outcome != nil)
        #expect(dialog.asked.map(\.direction) == [.undo, .redo])
        #expect(try mode(urls[0]) == 0o600)
        #expect(controller.nextLabel == .changeAttributes)
        #expect(controller.nextRedoLabel == nil)
    }

    @Test("A change the user can put back alone never asks")
    func ownChangeNeverAsks() async throws {
        let fixture = try changed(["a.txt"])
        defer { fixture.cleanup() }
        let (controller, urls) = (fixture.controller, fixture.urls)
        let dialog = Dialog(answer: false)

        let outcome = await controller.undo(consent: dialog.consent, shell: Self.plainShell)

        guard case let .fileOperation(_, report, administrator) = outcome else {
            Issue.record("expected a file operation, got \(String(describing: outcome))")
            return
        }
        #expect(dialog.asked.isEmpty)
        #expect(report.succeeded)
        #expect(administrator == nil)
        #expect(try mode(urls[0]) == 0o644)
    }

    /// A queued job can finish while the dialog is up and record something newer. The undo the user
    /// asked for is the one the dialog named, and the newer action has to stay undoable on top.
    @Test(
        "A step recorded behind the dialog stays on top, and the one asked about goes from beneath it"
    )
    func newerStepStaysOnTop() async throws {
        let fixture = try changed(["a.txt"])
        defer { fixture.cleanup() }
        let (controller, urls) = (fixture.controller, fixture.urls)
        let dialog = Dialog(answer: true)
        let newer = UndoRecord(label: .newFolder, steps: [.removeCreatedFolder(.local("/nowhere"))])
        dialog.whileUp = { controller.record(newer) }

        _ = await controller.undo(actor: stranger, consent: dialog.consent, shell: Self.plainShell)

        #expect(try mode(urls[0]) == 0o644)
        #expect(controller.nextLabel == .newFolder)
        #expect(controller.nextRedoLabel == .changeAttributes)
    }

    // MARK: - One at a time

    @Test("⌘Z and ⇧⌘Z run one at a time, in the order they were pressed")
    func requestsRunOneAtATime() async throws {
        let controller = UndoController(backend: LocalBackend(), defaults: ScratchDefaults.fresh())
        let log = Log()

        controller.enqueue {
            log.events.append("first started")
            await withCheckedContinuation { log.release = $0 }
            log.events.append("first finished")
        }
        controller.enqueue { log.events.append("second") }

        try await settle { log.release != nil }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(log.events == ["first started"])
        log.release?.resume()
        try await settle { log.events.count == 3 }
        #expect(log.events == ["first started", "first finished", "second"])
    }

    @MainActor
    private final class Log {
        var events: [String] = []
        var release: CheckedContinuation<Void, Never>?
    }

    // MARK: - The dialog

    @Test("The dialog names an undo or a redo, and keeps the batch's body and command")
    func dialogTitles() throws {
        var diff = AttributeDiff()
        diff.permissions = POSIXPermissions(rawValue: 0o644)
        let batch = EscalatedAttributeBatch(items: [.init(
            path: .local("/a"),
            actsOnLink: false,
            current: FileAttributes(
                permissions: POSIXPermissions(rawValue: 0o600),
                flags: [],
                ownerID: 0,
                groupID: 0,
                accessDate: .distantPast,
                modificationDate: .distantPast,
                creationDate: .distantPast
            ),
            diff: diff
        )])
        let undo = AttributeBatchEscalation.alert(
            for: batch, title: AdministratorEscalationAlert.title(for: .undo)
        )
        let redo = AttributeBatchEscalation.alert(
            for: batch, title: AdministratorEscalationAlert.title(for: .redo)
        )
        let plain = AttributeBatchEscalation.alert(for: batch)

        #expect(undo.messageText == AdministratorEscalationAlert.title(for: .undo))
        #expect(redo.messageText == AdministratorEscalationAlert.title(for: .redo))
        #expect(undo.messageText != redo.messageText)
        #expect(undo.messageText != plain.messageText)
        #expect(undo.informativeText == plain.informativeText)
        #expect(undo.buttons.count == 2)
        let field = try #require(undo.accessoryView as? AdministratorCommandView).field
        #expect(field.stringValue == batch.terminalCommand())
    }

    /// Poll rather than spinning the run loop (docs/NOTES.md ▸ Testing).
    private func settle(within seconds: Double = 30, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(predicate())
    }
}
