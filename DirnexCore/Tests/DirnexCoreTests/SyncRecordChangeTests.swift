import Foundation
import Testing

@testable import DirnexCore

/// Which side changed since the last sync, and the merge that answer makes possible (PLAN.md §M37
/// Slice 7).
@Suite("SyncRecord.change")
struct SyncRecordChangeTests {
    private func synced(_ text: String = "kept\n") throws -> SyncRecordFixture {
        let fixture = try SyncRecordFixture()
        try fixture.writeBoth("a.txt", text)
        try fixture.keep()
        return fixture
    }

    @Test("nothing touched is unchanged")
    func unchanged() throws {
        let fixture = try synced()
        defer { fixture.cleanup() }
        #expect(try fixture.change("a.txt") == .unchanged)
    }

    @Test("a file with no version has nothing to say")
    func noVersion() throws {
        let fixture = try synced()
        defer { fixture.cleanup() }
        try fixture.writeBoth("new.txt", "fresh")
        #expect(try fixture.change("new.txt") == .noVersion)
    }

    @Test("one side changed, either way round")
    func oneSide() throws {
        let left = try synced()
        defer { left.cleanup() }
        try left.writeLeft("a.txt", "mine")
        #expect(try left.change("a.txt") == .changedOnLeft)

        let right = try synced()
        defer { right.cleanup() }
        try right.writeRight("a.txt", "theirs")
        #expect(try right.change("a.txt") == .changedOnRight)
    }

    @Test("both sides changed differently hands back the kept version")
    func both() throws {
        let fixture = try synced()
        defer { fixture.cleanup() }
        try fixture.writeLeft("a.txt", "mine")
        try fixture.writeRight("a.txt", "theirs")
        let kept = try #require(try fixture.record.keptFile(for: "a.txt"))
        #expect(try fixture.change("a.txt") == .changedOnBoth(base: kept))
    }

    @Test("an edit of one size is still a change, and the sides are told apart by bytes")
    func sameSizes() throws {
        let fixture = try synced("aaaa")
        defer { fixture.cleanup() }
        try fixture.writeLeft("a.txt", "bbbb")
        #expect(try fixture.change("a.txt") == .changedOnLeft)
        try fixture.writeRight("a.txt", "cccc")
        let kept = try #require(try fixture.record.keptFile(for: "a.txt"))
        #expect(try fixture.change("a.txt") == .changedOnBoth(base: kept))
    }

    @Test("both sides arriving at the same bytes is not a merge")
    func alike() throws {
        let fixture = try synced()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "same edit")
        #expect(try fixture.change("a.txt") == .changedAlike)
    }

    @Test("a new date with the same bytes is not a change")
    func touchIsNotAChange() throws {
        let fixture = try synced()
        defer { fixture.cleanup() }
        try fixture.tree.setModificationDate("L/a.txt", to: Date(timeIntervalSinceNow: 86400))
        #expect(try fixture.change("a.txt") == .unchanged)
    }

    @Test("an edit that kept the date and the size is still a change")
    func clockIsNotConsulted() throws {
        let fixture = try synced("aaaa")
        defer { fixture.cleanup() }
        let date = try #require(
            FileManager.default.attributesOfItem(atPath: fixture.left("a.txt").path)[
                .modificationDate
            ] as? Date
        )
        try fixture.writeLeft("a.txt", "bbbb")
        try fixture.tree.setModificationDate("L/a.txt", to: date)
        #expect(try fixture.change("a.txt") == .changedOnLeft)
    }

    @Test("a side that cannot be read claims nothing")
    func unreadable() throws {
        let fixture = try synced()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.right("a.txt"))
        #expect(try fixture.change("a.txt") == .unreadable)
    }

    @Test("a kept file that is gone or damaged is no version")
    func damagedBase() throws {
        let fixture = try synced()
        defer { fixture.cleanup() }
        let kept = try #require(try fixture.record.keptFile(for: "a.txt"))
        try Data("another length".utf8).write(to: kept)
        #expect(try fixture.record.keptFile(for: "a.txt") == nil)
        #expect(try fixture.change("a.txt") == .noVersion)

        try FileManager.default.removeItem(at: kept)
        #expect(try fixture.change("a.txt") == .noVersion)
    }

    @Test("a stop is passed on rather than read as unreadable")
    func stop() throws {
        let fixture = try synced()
        defer { fixture.cleanup() }
        let record = try fixture.record
        #expect(throws: CancellationError.self) {
            try record.change(
                of: "a.txt",
                left: fixture.left("a.txt"),
                right: fixture.right("a.txt"),
                isCancelled: { true }
            )
        }
    }

    @Test(
        "a file changed on both sides merges over the version the sync kept, with both edits in it"
    )
    func theMilestonesSentence() throws {
        let fixture = try synced("one\ntwo\nthree\nfour\nfive\n")
        defer { fixture.cleanup() }
        try fixture.writeLeft("a.txt", "ONE\ntwo\nthree\nfour\nfive\n")
        try fixture.writeRight("a.txt", "one\ntwo\nthree\nfour\nFIVE\n")

        guard case let .changedOnBoth(base) = try fixture.change("a.txt") else {
            Issue.record("expected a change on both sides")
            return
        }
        let merge = try TextMerge(
            base: ComparedDocument.read(contentsOf: base),
            yours: ComparedDocument.read(contentsOf: fixture.left("a.txt")),
            theirs: ComparedDocument.read(contentsOf: fixture.right("a.txt"))
        )
        #expect(merge.isResolved)
        #expect(TextMergeTests.text(merge.result.lines) == "ONE\ntwo\nthree\nfour\nFIVE\n")
    }
}

/// The record against a plain model of what the two sides have done, over random histories.
@Suite("SyncRecord, histories")
struct SyncRecordHistoryTests {
    private static let names = ["a.txt", "b.txt", "d/c.txt"]
    // One length, so a size never gives an answer away and every comparison has to read.
    private static let bodies = ["aaaa\n", "bbbb\n", "cccc\n", "dddd\n"]

    private struct Model {
        var left: [String: String] = [:]
        var right: [String: String] = [:]
        var agreed: [String: String] = [:]

        mutating func kept() {
            for name in Set(left.keys).union(right.keys).union(agreed.keys) {
                switch (left[name], right[name]) {
                case let (one?, other?) where one == other: agreed[name] = one
                case (nil, nil): agreed[name] = nil
                default: break
                }
            }
        }

        func expectedChange(_ name: String, base: URL?) -> SyncChange? {
            guard let left = left[name], let right = right[name] else { return nil }
            guard let agreed = agreed[name], let base else { return .noVersion }
            switch (left == agreed, right == agreed) {
            case (true, true): return .unchanged
            case (false, true): return .changedOnLeft
            case (true, false): return .changedOnRight
            case (false, false): return left == right ? .changedAlike : .changedOnBoth(base: base)
            }
        }
    }

    @Test("every kept version is the last thing both sides held, over 40 random histories")
    func histories() throws {
        var rng = SeededGenerator(seed: 0x0037_0702)
        for _ in 0..<40 {
            try runHistory(using: &rng)
        }
    }

    private func runHistory(using rng: inout SeededGenerator) throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.tree.makeDir("L/d")
        try fixture.tree.makeDir("R/d")
        var model = Model()
        for step in 0..<30 {
            try act(on: fixture, model: &model, using: &rng)
            try fixture.keep(date: Date(timeIntervalSince1970: TimeInterval(step)))
            model.kept()
            try check(fixture, model)
        }
    }

    private func act(
        on fixture: SyncRecordFixture,
        model: inout Model,
        using rng: inout SeededGenerator
    ) throws {
        let name = try #require(Self.names.randomElement(using: &rng))
        let body = try #require(Self.bodies.randomElement(using: &rng))
        switch Int.random(in: 0..<6, using: &rng) {
        case 0:
            try fixture.writeLeft(name, body)
            model.left[name] = body
        case 1:
            try fixture.writeRight(name, body)
            model.right[name] = body
        case 2:
            try fixture.writeBoth(name, body)
            model.left[name] = body
            model.right[name] = body
        case 3:
            try? FileManager.default.removeItem(at: fixture.left(name))
            model.left[name] = nil
        case 4:
            try? FileManager.default.removeItem(at: fixture.right(name))
            model.right[name] = nil
        default:
            try? FileManager.default.removeItem(at: fixture.left(name))
            try? FileManager.default.removeItem(at: fixture.right(name))
            model.left[name] = nil
            model.right[name] = nil
        }
    }

    private func check(_ fixture: SyncRecordFixture, _ model: Model) throws {
        try fixture.expectStoreMatchesRecord()
        #expect(try Set(fixture.record.versions.keys) == Set(model.agreed.keys))
        for name in Self.names {
            #expect(try fixture.kept(name) == model.agreed[name])
            let base = try fixture.record.keptFile(for: name)
            if let expected = model.expectedChange(name, base: base) {
                #expect(try fixture.change(name) == expected)
            }
        }
    }
}

/// What the Synchronize window asks of a record for its rows (PLAN.md §M37 Slice 8).
@Suite("SyncRecord, for a window's rows")
struct SyncRecordRowsTests {
    @Test("rows with a version are answered, and the rest are not")
    func changesOfRows() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("both.txt", "kept\n")
        try fixture.writeBoth("left.txt", "kept\n")
        try fixture.keep()
        try fixture.writeLeft("both.txt", "mine\n")
        try fixture.writeRight("both.txt", "theirs\n")
        try fixture.writeLeft("left.txt", "mine\n")
        try fixture.writeBoth("new.txt", "no version\n")
        try fixture.writeLeft("only.txt", "one side\n")

        let rows = try DirectorySync.survey(
            left: fixture.tree.vfsPath("L"),
            right: fixture.tree.vfsPath("R"),
            leftBackend: fixture.backend,
            rightBackend: fixture.backend
        )
        let record = try fixture.record
        let answers = try record.changes(of: rows)
        let base = try #require(record.keptFile(for: "both.txt"))
        #expect(answers == ["both.txt": .changedOnBoth(base: base), "left.txt": .changedOnLeft])
    }

    @Test("a file with a version that has since become a link has no answer")
    func becameALink() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "kept\n")
        try fixture.keep()
        try FileManager.default.removeItem(at: fixture.left("a.txt"))
        try fixture.tree.symlink("L/a.txt", to: "../R/a.txt")

        let rows = try DirectorySync.survey(
            left: fixture.tree.vfsPath("L"),
            right: fixture.tree.vfsPath("R"),
            leftBackend: fixture.backend,
            rightBackend: fixture.backend
        )
        #expect(try fixture.record.changes(of: rows).isEmpty)
    }

    @Test("a stop is passed on")
    func stopIsPassedOn() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "kept\n")
        try fixture.keep()
        let rows = try DirectorySync.survey(
            left: fixture.tree.vfsPath("L"),
            right: fixture.tree.vfsPath("R"),
            leftBackend: fixture.backend,
            rightBackend: fixture.backend
        )
        let record = try fixture.record
        #expect(throws: CancellationError.self) {
            try record.changes(of: rows, isCancelled: { true })
        }
    }

    @Test("only a file changed differently on both sides has a merge base")
    func mergeBase() {
        let base = URL(fileURLWithPath: "/base")
        #expect(SyncChange.changedOnBoth(base: base).mergeBase == base)
        for other: SyncChange in [
            .noVersion,
            .unchanged,
            .changedOnLeft,
            .changedOnRight,
            .changedAlike,
            .unreadable
        ] {
            #expect(other.mergeBase == nil)
        }
    }

    @Test(
        "Both Directions leaves a file changed on both sides for a merge, and a mirror still copies"
    )
    func defaultAction() {
        let both = SyncChange.changedOnBoth(base: URL(fileURLWithPath: "/base"))
        #expect(
            DirectorySync.defaultAction(for: .leftNewer, direction: .bidirectional, change: both) == .conflict
        )
        #expect(
            DirectorySync.defaultAction(for: .rightNewer, direction: .bidirectional, change: both) == .conflict
        )
        #expect(
            DirectorySync.defaultAction(for: .leftNewer, direction: .rightToLeft, change: both) == .copyToLeft
        )
        #expect(
            DirectorySync.defaultAction(for: .rightNewer, direction: .leftToRight, change: both) == .copyToRight
        )
    }

    @Test("what the record cannot say leaves the direction's default alone")
    func noClaimNoOverride() {
        for change: SyncChange? in [
            nil,
            .noVersion,
            .unchanged,
            .changedOnLeft,
            .changedAlike,
            .unreadable
        ] {
            for status: SyncStatus in [.leftNewer, .rightNewer, .differ, .leftOnly, .typeMismatch] {
                for direction: SyncDirection in [.leftToRight, .bidirectional, .rightToLeft] {
                    #expect(
                        DirectorySync.defaultAction(
                            for: status,
                            direction: direction,
                            change: change
                        )
                            == DirectorySync.defaultAction(for: status, direction: direction)
                    )
                }
            }
        }
    }
}
