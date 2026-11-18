import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The app half of the batch escalation (PLAN.md §M40 Slice 4): the transport that feeds the core's
/// bodies to one `osascript` over stdin, the dialog, and the multi-selection Save that asks before it
/// writes. The password itself cannot be typed by a test, so the transport runs here with its
/// administrator flag off, which runs the same script through the same `doShellScript`.
@Suite("AttributeBatchEscalation")
@MainActor
struct AttributeBatchEscalationTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    /// A scratch folder holding `names`, each at mode 0644.
    private func scratch(_ names: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttributeBatchEscalation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        for name in names {
            let file = url.appendingPathComponent(name)
            try Data(name.utf8).write(to: file)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: file.path
            )
        }
        return url
    }

    private func mode(_ url: URL) throws -> Int {
        try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        )
    }

    /// A batch changing each file in `folder` named in `names` to `mode`, planned from disk.
    private func batch(_ folder: URL, _ names: [String], mode: UInt16) throws -> EscalatedAttributeBatch {
        var patch = AttributePatch()
        patch.permissionMask = POSIXPermissions(rawValue: 0o7777)
        patch.permissionValues = POSIXPermissions(rawValue: mode)
        let job = AttributeApplyJob(patch: patch)
        return EscalatedAttributeBatch(
            retrying: names.map {
                .init(path: .local(folder.appendingPathComponent($0).path), kind: .file)
            },
            of: job
        )
    }

    private static let plainShell: @Sendable ([String]) async throws -> Void = {
        try await AdministratorShell.run($0, privileged: false)
    }

    // MARK: - The transport

    @Test("Every body runs in one process, as data, past ARG_MAX, and a failure's stderr comes back")
    func transportRunsEveryBody() async throws {
        let folder = try scratch([])
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first").path
        let marker = folder.appendingPathComponent("it's \"quoted\" \\ $(here)").path
        let filler = String(repeating: "#", count: 600_000)

        await #expect(throws: AdministratorShell.Failure.failed(
            "ls: /nonexistent-dirnex: No such file or directory"
        )) {
            try await AdministratorShell.run(
                [
                    "/usr/bin/touch \(ShellQuoting.quoted(first, for: .other))",
                    "/bin/ls /nonexistent-dirnex",
                    "true \(filler)",
                    "true \(filler)",
                    "/usr/bin/touch \(ShellQuoting.quoted(marker, for: .other))"
                ],
                privileged: false
            )
        }
        #expect(FileManager.default.fileExists(atPath: first))
        #expect(
            FileManager.default.fileExists(atPath: marker),
            "the bodies after the failure ran, two together past ARG_MAX, and the name stayed whole"
        )
    }

    /// No test can press Cancel on the password dialog, so this pins the number the live run found:
    /// a real Cancel reached the script as -60006, and checking -128 alone read it as a failure.
    @Test("A cancel is recognised under both numbers macOS gives it")
    func transportKnowsBothCancelNumbers() {
        #expect(AdministratorShell.script.contains("const cancelled = [-128, -60006];"))
        #expect(
            AdministratorShell.script.contains(
                "if (cancelled.includes(error.errorNumber)) $.exit(2);"
            )
        )
    }

    @Test("No bodies is no process, and so no password dialog")
    func transportWithNothingToRun() async throws {
        try await AdministratorShell.run([], privileged: false)
        try await AdministratorShell.run([""], privileged: false)
    }

    // MARK: - Run, then read back

    @Test("A run reads every item back and journals what landed")
    func runJournalsWhatLanded() async throws {
        let folder = try scratch(["a.txt", "b.txt", "c.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let batch = try batch(folder, ["a.txt", "b.txt", "c.txt"], mode: 0o600)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("b.txt"))

        let result = await AttributeBatchEscalation.run(batch, shell: Self.plainShell)

        #expect(try mode(folder.appendingPathComponent("a.txt")) == 0o600)
        #expect(try mode(folder.appendingPathComponent("c.txt")) == 0o600)
        #expect(result.outcome.changedCount == 2)
        #expect(result.outcome.unchanged.map(\.lastComponent) == ["b.txt"])
        #expect(result.failure?.contains("b.txt") == true)
        #expect(result.reason == result.failure)
        #expect(!result.wasCancelled)
        let record = try #require(UndoRecord.attributeBatchChange(result.outcome.changed))
        #expect(record.steps.count == 2)
    }

    @Test("A cancelled dialog is a choice, and the items are still read back")
    func cancelledRunStillReadsBack() async throws {
        let folder = try scratch(["a.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let batch = try batch(folder, ["a.txt"], mode: 0o600)

        let result = await AttributeBatchEscalation.run(batch) { _ in
            throw AdministratorShell.Failure.cancelled
        }

        #expect(result.wasCancelled)
        #expect(result.failure == nil)
        #expect(result.outcome.changedCount == 0)
        #expect(result.outcome.unchanged.count == 1)
    }

    // MARK: - The dialog

    @Test(
        "A batch that fits one command line offers it to copy, and a longer one says it is too long"
    )
    func dialogOffersCommandOnlyWhenItFits() throws {
        let small = EscalatedAttributeBatch(items: [diffItem("/a"), diffItem("/b")])
        let smallAlert = AttributeBatchEscalation.alert(for: small)
        let field = try #require(smallAlert.accessoryView as? AdministratorCommandView).field
        #expect(field.stringValue == small.terminalCommand())
        #expect(smallAlert.informativeText == AdministratorEscalationAlert.batchBody(
            count: 2, offersCommand: true
        ))
        #expect(smallAlert.buttons.count == 2)

        let longName = "/" + String(repeating: "n", count: 1000)
        let large = EscalatedAttributeBatch(items: (0..<600).map { diffItem("\(longName)/\($0)") })
        #expect(large.bodies().count > 1)
        let largeAlert = AttributeBatchEscalation.alert(for: large)
        #expect(largeAlert.accessoryView == nil)
        #expect(largeAlert.informativeText == AdministratorEscalationAlert.batchBody(
            count: 600, offersCommand: false
        ))
    }

    @Test("A batch of only Created dates has nothing to authenticate, and says why")
    func dialogWithNothingToRun() {
        var diff = AttributeDiff()
        diff.creationDate = epoch.addingTimeInterval(60)
        let batch = EscalatedAttributeBatch(items: [.init(
            path: .local("/a"), actsOnLink: false, current: attributes(owner: 0), diff: diff
        )])
        let alert = AttributeBatchEscalation.alert(for: batch)
        #expect(alert.buttons.count == 1)
        #expect(alert.accessoryView == nil)
        #expect(alert.informativeText.hasPrefix(AdministratorEscalationAlert.nothingToRun))
        #expect(alert.informativeText.contains(
            AdministratorEscalationAlert.omissionSentences([.creationDate])[0]
        ))
    }

    @Test("Copy puts the command on the pasteboard whole")
    func copyButton() {
        let view = AdministratorCommandView(command: "sudo /bin/sh -c 'x'")
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        view.copyCommand(nil)
        #expect(pasteboard.string(forType: .string) == "sudo /bin/sh -c 'x'")
    }

    // MARK: - Fixtures

    private func attributes(owner: UInt32, flags: BSDFileFlags = []) -> FileAttributes {
        FileAttributes(
            permissions: POSIXPermissions(rawValue: 0o644),
            flags: flags,
            ownerID: owner,
            groupID: getgid(),
            accessDate: epoch,
            modificationDate: epoch,
            creationDate: epoch
        )
    }

    private func diffItem(_ path: String) -> EscalatedAttributeBatch.Item {
        var diff = AttributeDiff()
        diff.permissions = POSIXPermissions(rawValue: 0o600)
        return .init(
            path: .local(path),
            actsOnLink: false,
            current: attributes(owner: 0),
            diff: diff
        )
    }
}
