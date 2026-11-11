import Foundation
import Testing

@testable import DirnexCore

/// What changed since the sync that copied a file, on a pair with a server side: the local half by
/// bytes, the server half by its row's stamp (PLAN.md §M38 Slice 8).
@Suite("SyncRecord.change, with a server side")
struct SyncRecordServerChangeTests {
    private func synced(
        _ text: String = "kept\n",
        serverOnLeft: Bool = false,
        tags: Bool = false
    ) throws -> ServerSyncFixture {
        let fixture = try ServerSyncFixture(serverOnLeft: serverOnLeft, tags: tags)
        try fixture.writeLocal("a.txt", text)
        try fixture.sync()
        return fixture
    }

    @Test("nothing touched is unchanged, and nothing is downloaded to say so")
    func unchanged() throws {
        let fixture = try synced()
        defer { fixture.cleanup() }
        #expect(
            try fixture.record.changes(of: fixture.compare(includingIdentical: true))["a.txt"] == .unchanged
        )
        #expect(fixture.server.byteReads == 0)
    }

    @Test("a local edit is a change on the local side, whichever pane it is in")
    func localEdit() throws {
        let left = try synced()
        defer { left.cleanup() }
        try left.writeLocal("a.txt", "mine, longer\n")
        #expect(try left.change("a.txt") == .changedOnLeft)

        let right = try synced(serverOnLeft: true)
        defer { right.cleanup() }
        try right.writeLocal("a.txt", "mine, longer\n")
        #expect(try right.change("a.txt") == .changedOnRight)
    }

    @Test("a server write is a change on the server's side, read from its row alone")
    func serverEdit() throws {
        let fixture = try synced()
        defer { fixture.cleanup() }
        fixture.writeServer("a.txt", "theirs, longer\n")
        #expect(try fixture.change("a.txt") == .changedOnRight)
        #expect(fixture.server.byteReads == 0)
    }

    @Test("a server file whose date moved reads as changed, the safe direction")
    func touched() throws {
        let fixture = try synced()
        defer { fixture.cleanup() }
        let stamp = fixture.nextStamp()
        fixture.server.restamp(fixture.serverPath("a.txt"), modified: stamp.modified)
        #expect(
            try fixture.record.changes(of: fixture.compare(includingIdentical: true))["a.txt"] == .changedOnRight
        )
    }

    @Test("a same-size write inside the listing's minute is unseen without a tag, and seen with one")
    func sameMinute() throws {
        let untagged = try synced("aaaa\n")
        defer { untagged.cleanup() }
        let stamp = try #require(try untagged.record.versions["a.txt"]?.serverRevision)
        untagged.server.put(
            untagged.serverPath("a.txt"),
            "bbbb\n",
            modified: try #require(stamp.modified)
        )
        #expect(
            try untagged.record.changes(of: untagged.compare(includingIdentical: true))["a.txt"] == .unchanged
        )

        let tagged = try synced("aaaa\n", tags: true)
        defer { tagged.cleanup() }
        let taggedStamp = try #require(try tagged.record.versions["a.txt"]?.serverRevision)
        tagged.server.put(
            tagged.serverPath("a.txt"),
            "bbbb\n",
            modified: try #require(taggedStamp.modified),
            tag: "\"other\""
        )
        #expect(
            try tagged.record.changes(of: tagged.compare(includingIdentical: true))["a.txt"] == .changedOnRight
        )
    }

    @Test("a weak spelling of the same tag is no change")
    func weakTag() throws {
        let fixture = try synced(tags: true)
        defer { fixture.cleanup() }
        let stamp = try #require(try fixture.record.versions["a.txt"]?.serverRevision)
        fixture.server.restamp(
            fixture.serverPath("a.txt"),
            modified: try #require(stamp.modified),
            tag: "W/" + (stamp.entityTag ?? "")
        )
        #expect(
            try fixture.record.changes(of: fixture.compare(includingIdentical: true))["a.txt"] == .unchanged
        )
    }

    @Test("both sides moved on hands back the version the sync copied")
    func both() throws {
        let fixture = try synced()
        defer { fixture.cleanup() }
        try fixture.writeLocal("a.txt", "mine\n")
        fixture.writeServer("a.txt", "theirs!\n")
        let kept = try #require(try fixture.record.keptFile(for: "a.txt"))
        #expect(try fixture.change("a.txt") == .changedOnBoth(base: kept))
        let change = try fixture.change("a.txt")
        #expect(
            DirectorySync.defaultAction(for: .differ, direction: .bidirectional, change: change) == .conflict
        )
    }

    @Test(
        "a file changed on both sides merges over the version the sync copied, the server's file downloaded only then"
    )
    func theMilestonesSentence() throws {
        let fixture = try synced("one\ntwo\nthree\nfour\nfive\n")
        defer { fixture.cleanup() }
        try fixture.writeLocal("a.txt", "ONE\ntwo\nthree\nfour\nfive\n")
        fixture.writeServer("a.txt", "one\ntwo\nthree\nfour\nFIVE\n")
        guard case let .changedOnBoth(base) = try fixture.change("a.txt") else {
            Issue.record("expected a change on both sides")
            return
        }
        #expect(fixture.server.byteReads == 0)

        // What Merge… does when pressed: download the server's file, once.
        let theirs = fixture.tree.root.appendingPathComponent("theirs.txt")
        try fixture.server.copyFile(
            at: fixture.server.path(fixture.serverPath("a.txt")),
            to: .local(theirs.path),
            progress: { _ in },
            isCancelled: { false }
        )
        #expect(fixture.server.byteReads == 1)
        let merge = try TextMerge(
            base: ComparedDocument.read(contentsOf: base),
            yours: ComparedDocument.read(contentsOf: fixture.local("a.txt")),
            theirs: ComparedDocument.read(contentsOf: theirs)
        )
        #expect(merge.isResolved)
        #expect(TextMergeTests.text(merge.result.lines) == "ONE\ntwo\nthree\nfour\nFIVE\n")
    }

    @Test("a version with no stamp beside it, as an older build's rewrite leaves one, is no version")
    func noStamp() throws {
        let fixture = try synced()
        defer { fixture.cleanup() }
        let record = try fixture.record
        let version = try #require(record.versions["a.txt"])
        try fixture.store.write(
            SyncRecordStore.Manifest(
                pair: fixture.pair,
                versions: [
                    "a.txt": .init(
                        file: version.file,
                        byteSize: version.byteSize,
                        keptAt: version.keptAt
                    )
                ]
            ),
            to: record.directory
        )
        try fixture.writeLocal("a.txt", "mine, longer\n")
        #expect(try fixture.change("a.txt") == .noVersion)
    }

    @Test("a local side that cannot be read claims nothing")
    func unreadable() throws {
        let fixture = try synced()
        defer { fixture.cleanup() }
        let row = try #require(try fixture.compare(includingIdentical: true).first)
        try FileManager.default.removeItem(at: fixture.local("a.txt"))
        let local = try #require(row.left)
        let server = try #require(row.right)
        #expect(try fixture.record.change(of: "a.txt", left: local, right: server) == .unreadable)
    }

    @Test("a row without exactly one local side has no answer")
    func notOneLocal() throws {
        let fixture = try synced()
        defer { fixture.cleanup() }
        let server = try fixture.serverEntry("a.txt")
        #expect(try fixture.record.change(of: "a.txt", left: server, right: server) == .noVersion)
    }

    @Test("a stop is passed on rather than read as unreadable")
    func stop() throws {
        let fixture = try synced()
        defer { fixture.cleanup() }
        try fixture.writeLocal("a.txt", "mine\n")
        let rows = try fixture.compare(includingIdentical: true)
        #expect(throws: CancellationError.self) {
            try fixture.record.changes(of: rows, isCancelled: { true })
        }
    }
}

/// The record with a server side against a plain model of what each side has done since the sync
/// that last copied each file, over random histories.
@Suite("SyncRecord with a server side, histories")
struct SyncRecordServerHistoryTests {
    private static let names = ["a.txt", "b.txt", "d/c.txt"]
    // One length, so a size never gives an answer away.
    private static let bodies = ["aaaa\n", "bbbb\n", "cccc\n", "dddd\n"]

    /// For each file, the bytes the last copy left on both sides and the server stamp it left there,
    /// and what each side holds now.
    private struct Model {
        var local: [String: String] = [:]
        var server: [String: (text: String, stamp: Int)] = [:]
        var agreed: [String: (text: String, stamp: Int)] = [:]

        func expectedChange(_ name: String, base: URL?) -> SyncChange? {
            guard let local = local[name], let server = server[name] else { return nil }
            guard let agreed = agreed[name], let base else { return .noVersion }
            switch (local != agreed.text, server.stamp != agreed.stamp) {
            case (false, false): return .unchanged
            case (true, false): return .changedOnLeft
            case (false, true): return .changedOnRight
            case (true, true): return .changedOnBoth(base: base)
            }
        }
    }

    @Test(
        "every version is the last copy's bytes, and every answer the model's, over 30 random histories"
    )
    func histories() throws {
        var rng = SeededGenerator(seed: 0x0038_0801)
        for _ in 0..<30 {
            try runHistory(using: &rng)
        }
    }

    private func runHistory(using rng: inout SeededGenerator) throws {
        let fixture = try ServerSyncFixture()
        defer { fixture.cleanup() }
        var model = Model()
        var stamps = 0
        for _ in 0..<25 {
            let name = try #require(Self.names.randomElement(using: &rng))
            let body = try #require(Self.bodies.randomElement(using: &rng))
            switch Int.random(in: 0..<5, using: &rng) {
            case 0:
                try fixture.writeLocal(name, body)
                try fixture.tree.setModificationDate(
                    "L/\(name)",
                    to: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(stamps * 7 + 1))
                )
                model.local[name] = body
            case 1:
                fixture.writeServer(name, body)
                stamps += 1
                model.server[name] = (body, stamps)
            case 2, 3:
                try sync(
                    fixture,
                    &model,
                    &stamps,
                    direction: rng.next() % 2 == 0 ? .leftToRight : .rightToLeft
                )
            default:
                try check(fixture, model)
            }
        }
        try check(fixture, model)
    }

    /// A mirror whose every row is copied, picked by content rather than size, since a size never
    /// differs here: the rows that differ are the ones a content comparison would list.
    private func sync(
        _ fixture: ServerSyncFixture,
        _ model: inout Model,
        _ stamps: inout Int,
        direction: SyncDirection
    ) throws {
        let rows = try fixture.compare(includingIdentical: true).filter { row in
            guard let name = Self.names.first(where: { $0 == row.relativePath }) else {
                return row.left == nil || row.right == nil
            }
            return model.local[name] != model.server[name]?.text
        }
        let decisions = fixture.decisions(rows, direction: direction)
        func covered(by decision: SyncDecision) -> [String] {
            Self.names.filter {
                $0 == decision.entry.relativePath || $0.hasPrefix(decision.entry.relativePath + "/")
            }
        }
        // The deletes and the copies both finish before keeping, as the app waits for both.
        for decision in decisions {
            for name in covered(by: decision) {
                switch decision.action {
                case .deleteLeft:
                    model.local[name] = nil
                    try? FileManager.default.removeItem(at: fixture.local(name))
                case .deleteRight:
                    model.server[name] = nil
                    fixture.server.remove(fixture.serverPath(name))
                default:
                    break
                }
            }
        }
        try fixture.copy(decisions)
        try fixture.keep(after: decisions)
        var copied = false
        for decision in decisions {
            for name in covered(by: decision) {
                switch decision.action {
                case .copyToRight:
                    guard let text = model.local[name] else { continue }
                    copied = true
                    stamps += 1
                    model.server[name] = (text, stamps)
                    model.agreed[name] = (text, stamps)
                case .copyToLeft:
                    guard let server = model.server[name] else { continue }
                    copied = true
                    model.local[name] = server.text
                    model.agreed[name] = server
                default:
                    break
                }
            }
        }
        // A version outlives its file until a sync that copied something walks the pair and finds
        // the file gone from both sides.
        guard copied else { return }
        for name in Self.names where model.local[name] == nil && model.server[name] == nil {
            model.agreed[name] = nil
        }
    }

    private func check(_ fixture: ServerSyncFixture, _ model: Model) throws {
        try fixture.expectStoreMatchesRecord()
        let rows = try fixture.compare(includingIdentical: true)
        let answers = try fixture.record.changes(of: rows)
        for name in Self.names {
            if model.local[name] != nil, model.server[name] != nil {
                #expect(try fixture.kept(name) == model.agreed[name]?.text, "\(name)")
            }
            let base = try fixture.record.keptFile(for: name)
            // A row with no version gets no answer from `changes(of:)`, which the model calls none.
            if let expected = model.expectedChange(name, base: base) {
                #expect((answers[name] ?? .noVersion) == expected, "\(name)")
            }
        }
        #expect(fixture.server.byteReads == 0)
    }
}
