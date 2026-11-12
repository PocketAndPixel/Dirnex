import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The route a pair takes to the byte view (PLAN.md §M37 Slice 2): what the text window cannot read
/// goes there, under the name the file lives by, and what cannot be opened at all is still an alert.
@Suite("Byte comparison window — the route there")
@MainActor
struct BinaryCompareRouteTests: ByteWindowTesting {
    @Test(
        "a file that cannot be read as text goes to the byte view, one that cannot be read at all does not"
    )
    func reasons() {
        func reason(_ failure: ComparedText.Failure) -> BinaryCompareReason? {
            BinaryCompareReason(CompareReadFailure(name: "x.bin", reason: failure))
        }
        #expect(reason(.binary) == .notText(name: "x.bin"))
        #expect(reason(.undecodable) == .undecodable(name: "x.bin"))
        #expect(reason(.tooLarge(byteSize: 2, limit: 1)) == .tooLarge)
        #expect(reason(.unreadable) == nil)
    }

    private final class Opened {
        var sides: (BinaryCompareSide, BinaryCompareSide)?
        var reason: BinaryCompareReason?
        var failure: String?
    }

    private func open(
        _ fixture: ByteWindowFixture,
        into opened: Opened,
        byteLimit: Int64 = ComparedText.windowByteLimit()
    ) {
        CompareOpener.openWindow(
            CompareFile(path: fixture.left, origin: .local("/somewhere/shown-left.bin")),
            detail: "shown left",
            CompareFile(path: fixture.right, origin: fixture.right),
            detail: "shown right",
            byteLimit: byteLimit,
            presentBytes: { left, right, _, reason in
                opened.sides = (left, right)
                opened.reason = reason
            },
            failed: { opened.failure = $0 }
        )
    }

    @Test("a binary pair opens the byte view under the name the file lives by, with no alert")
    func binaryRoute() async throws {
        let fixture = try fixture([0, 1, 2], [0, 1, 3])
        defer { fixture.cleanup() }
        let opened = Opened()
        open(fixture, into: opened)
        #expect(await until { opened.reason != nil })
        #expect(opened.reason == .notText(name: "shown-left.bin"))
        #expect(opened.sides?.0.name == "shown-left.bin")
        #expect(opened.sides?.0.detail == "shown left")
        #expect(opened.failure == nil)
    }

    @Test("a pair past the text limit opens the byte view, without reading the large file")
    func tooLargeRoute() async throws {
        let fixture = try fixture([], [])
        defer { fixture.cleanup() }
        #expect(truncate(fixture.left.path, ByteComparator.prescanByteLimit + 1) == 0)
        #expect(truncate(fixture.right.path, ByteComparator.prescanByteLimit + 1) == 0)
        let opened = Opened()
        open(fixture, into: opened, byteLimit: ByteComparator.prescanByteLimit)
        #expect(await until { opened.reason != nil })
        #expect(opened.reason == .tooLarge)
        #expect(opened.failure == nil)
    }

    @Test("a file that cannot be opened is still an alert")
    func missingFileRoute() async throws {
        let fixture = try fixture([1], [2])
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(atPath: fixture.right.path)
        let opened = Opened()
        open(fixture, into: opened)
        #expect(await until { opened.failure != nil })
        #expect(opened.reason == nil)
    }
}
