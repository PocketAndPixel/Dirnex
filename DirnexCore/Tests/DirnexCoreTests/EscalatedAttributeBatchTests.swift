import Foundation
import Testing

@testable import DirnexCore

/// The batch escalation's bodies (PLAN.md §M40 Slice 4): many items' root-only changes in as few
/// shell bodies as `execve` allows, each item running whatever the one before it did.
///
/// The commands are ordinary CLI, so the tests run the real bodies with `/bin/sh` on files the tester
/// owns and let the disk judge, as the single-item suite's harness did (docs/NOTES.md ▸ Attribute
/// escalation). Only the password is left out, and that is the one part a test cannot type. What the
/// read-back makes of a run is `EscalatedAttributeBatchOutcomeTests`.
@Suite("EscalatedAttributeBatch")
struct EscalatedAttributeBatchTests {
    private let epoch = EscalatedBatchSupport.epoch

    private func attributes(mode: UInt16 = 0o644, flags: BSDFileFlags = []) -> FileAttributes {
        EscalatedBatchSupport.attributes(mode: mode, flags: flags)
    }

    private func item(_ path: String, to new: UInt16) -> EscalatedAttributeBatch.Item {
        EscalatedBatchSupport.item(path, to: new)
    }

    private func runShell(_ body: String) throws -> (status: Int32, stderr: String) {
        try EscalatedBatchSupport.runShell(body)
    }

    private func diskItem(
        _ fixture: AttributeApplyFixture,
        _ relative: String,
        mode: UInt16
    ) throws -> EscalatedAttributeBatch.Item {
        try EscalatedBatchSupport.diskItem(fixture, relative, mode: mode)
    }

    // MARK: - The bodies

    @Test("Each item's command is the single-item translation, and a failure does not stop the next")
    func bodyShape() {
        let batch = EscalatedAttributeBatch(items: [item("/a", to: 0o600), item("/b c", to: 0o700)])
        #expect(batch.bodies() == [
            "s=0; /bin/chmod 600 '/a' || s=1; /bin/chmod 700 '/b c' || s=1; exit $s"
        ])
        #expect(
            batch.items.map(\.command.scriptBody) == ["/bin/chmod 600 '/a'", "/bin/chmod 700 '/b c'"]
        )
    }

    @Test("A hostile name stays one quoted word")
    func hostileName() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }
        let name = "x'; touch pwned; '$(touch pwned2)"
        try fixture.tree.writeFile(name, contents: "x")
        let batch = EscalatedAttributeBatch(items: [try diskItem(fixture, name, mode: 0o600)])

        let result = try runShell(try #require(batch.bodies().first))

        #expect(result.status == 0)
        #expect(try fixture.mode(name) == 0o600)
        #expect(!FileManager.default.fileExists(atPath: fixture.tree.path("pwned")))
        #expect(!FileManager.default.fileExists(atPath: "pwned"))
        #expect(!FileManager.default.fileExists(atPath: "pwned2"))
    }

    @Test("An item with only an omitted change runs nothing and is still stated")
    func onlyOmissions() {
        var diff = AttributeDiff()
        diff.creationDate = epoch.addingTimeInterval(60)
        let created = EscalatedAttributeBatch.Item(
            path: VFSPath.local("/c"), actsOnLink: false, current: attributes(), diff: diff
        )
        let onlyCreated = EscalatedAttributeBatch(items: [created])
        #expect(!onlyCreated.hasCommands)
        #expect(onlyCreated.bodies().isEmpty)
        #expect(onlyCreated.terminalCommand() == nil)
        #expect(onlyCreated.omissions == [.creationDate])

        let mixed = EscalatedAttributeBatch(items: [created, item("/a", to: 0o600)])
        #expect(mixed.hasCommands)
        #expect(mixed.bodies() == ["s=0; /bin/chmod 600 '/a' || s=1; exit $s"])
        #expect(mixed.omissions == [.creationDate])
    }

    @Test("Bodies split at the limit, in order, with every item exactly once")
    func chunking() {
        let items = (0..<40).map { item("/dir/file-\($0)", to: 0o600) }
        let batch = EscalatedAttributeBatch(items: items)
        let limit = 200
        let bodies = batch.bodies(limit: limit)

        #expect(bodies.count > 1)
        #expect(bodies.allSatisfy { $0.utf8.count <= limit })
        #expect(bodies.allSatisfy { $0.hasPrefix("s=0; ") && $0.hasSuffix("exit $s") })
        let commands = bodies.flatMap { body in
            body.dropFirst("s=0; ".count).dropLast("exit $s".count)
                .components(separatedBy: " || s=1; ").filter { !$0.isEmpty }
        }
        #expect(commands == items.map(\.command.scriptBody))
        #expect(batch.terminalCommand(limit: limit) == nil, "sudo could not pass more than one body")
    }

    @Test("An item longer than the limit by itself runs alone rather than being dropped")
    func oversizedItem() {
        let long = item("/" + String(repeating: "n", count: 300), to: 0o600)
        let batch = EscalatedAttributeBatch(
            items: [item("/a", to: 0o600), long, item("/b", to: 0o600)]
        )
        let bodies = batch.bodies(limit: 200)
        #expect(bodies.count == 3)
        #expect(bodies[1].contains(long.command.scriptBody))
    }

    @Test("The terminal line is the one body as a single argument to sudo's shell")
    func terminalCommand() throws {
        let batch = EscalatedAttributeBatch(items: [item("/a", to: 0o600), item("/b", to: 0o700)])
        let body = try #require(batch.bodies().first)
        #expect(
            batch.terminalCommand() == "sudo /bin/sh -c \(ShellQuoting.quoted(body, for: .other))"
        )
    }

    @Test("The real 512 KiB limit holds a few thousand items to a body")
    func defaultLimit() {
        let items = (0..<6000).map {
            item(
                "/Volumes/Archive/Projects/2019/client-name/assets/export/image-\($0).png",
                to: 0o644
            )
        }
        let bodies = EscalatedAttributeBatch(items: items).bodies()
        #expect(bodies.count == 2)
        #expect(bodies.allSatisfy { $0.utf8.count <= EscalatedAttributeBatch.bodyLimit })
    }

    // MARK: - Run, then read back

    @Test("A failed item leaves the others applied, and the read-back names it")
    func failureDoesNotStopTheRest() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }
        let batch = EscalatedAttributeBatch(items: [
            try diskItem(fixture, "a.txt", mode: 0o600),
            try diskItem(fixture, "sub/b.txt", mode: 0o600),
            try diskItem(fixture, "sub/deep/c.txt", mode: 0o600)
        ])
        try FileManager.default.removeItem(atPath: fixture.tree.path("sub/b.txt"))

        let result = try runShell(try #require(batch.bodies().first))
        let outcome = batch.outcomeOnDisk()

        #expect(
            result.status == 1,
            "the failure is the exit status, so the tool's stderr comes back"
        )
        #expect(result.stderr.contains("b.txt"))
        #expect(try fixture.mode("a.txt") == 0o600)
        #expect(try fixture.mode("sub/deep/c.txt") == 0o600, "the item after the failure still ran")
        #expect(
            outcome.changed.map(\.path) == [
                fixture.tree.vfsPath("a.txt"),
                fixture.tree.vfsPath("sub/deep/c.txt")
            ]
        )
        #expect(outcome.unchanged == [fixture.tree.vfsPath("sub/b.txt")])
        #expect(outcome.changedCount == 2)
        #expect(outcome.isUndoable)
    }

    @Test("A body that never ran journals nothing for its items")
    func laterBodyNeverRan() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }
        let batch = EscalatedAttributeBatch(items: [
            try diskItem(fixture, "a.txt", mode: 0o600),
            try diskItem(fixture, "sub/b.txt", mode: 0o600)
        ])
        let bodies = batch.bodies(limit: 60)
        #expect(bodies.count == 2)

        _ = try runShell(bodies[0]) // the password dialog cancelled before the second
        let outcome = batch.outcomeOnDisk()

        #expect(outcome.changed.map(\.path) == [fixture.tree.vfsPath("a.txt")])
        #expect(outcome.unchanged == [fixture.tree.vfsPath("sub/b.txt")])
    }

    @Test("A locked file's mode changes and it stays locked, judged by the disk")
    func lockedFile() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }
        #expect(chflags(fixture.tree.path("a.txt"), UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(fixture.tree.path("a.txt"), 0) }
        let batch = EscalatedAttributeBatch(items: [try diskItem(fixture, "a.txt", mode: 0o600)])

        _ = try runShell(try #require(batch.bodies().first))
        let outcome = batch.outcomeOnDisk()

        #expect(try fixture.mode("a.txt") == 0o600)
        #expect(try fixture.flags("a.txt").contains(.userImmutable))
        let entry = try #require(outcome.changed.first)
        #expect(entry.new.permissions.rawValue == 0o600)
        #expect(entry.new.flags == entry.old.flags, "the unlock and relock cancel out")
        #expect(outcome.unchanged.isEmpty)
    }
}
