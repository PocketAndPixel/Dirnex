import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Which pages get read, and when (PLAN.md §M37 Slice 2), driven with a fake read that answers only
/// when told to.
@Suite("Byte view page reads")
@MainActor
struct BinaryRowSourceTests {
    private final class FakeRead: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [Int64] = []
        private var released: Set<Int64> = []
        private var failing: Set<Int64> = []

        var readPages: [Int64] {
            lock.withLock { calls }
        }

        func release(_ index: Int64) {
            lock.withLock { _ = released.insert(index) }
        }

        func fail(_ index: Int64) {
            lock.withLock { _ = failing.insert(index) }
        }

        func read(_ index: Int64) throws -> BinaryPage {
            lock.withLock { calls.append(index) }
            while !lock.withLock({ released.contains(index) }) {
                Thread.sleep(forTimeInterval: 0.002)
            }
            if lock.withLock({ failing.contains(index) }) {
                throw VFSError.io(path: .local("/x"), code: EIO)
            }
            return BinaryPage(index: index, left: [UInt8(index & 0xFF)], right: [])
        }
    }

    private let rowsPerPage = Int64(BinaryPage.byteCount / BinaryHexLayout.bytesPerRow)

    private func until(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(60)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test("a row not held is nil, and held once its page has arrived")
    func loads() async {
        let fake = FakeRead()
        let source = BinaryRowSource { try fake.read($0) }
        source.pagesOnScreen = { [0] }
        var loaded: [Int64] = []
        source.onLoad = { loaded.append($0) }
        #expect(source.row(0) == nil)
        fake.release(0)
        #expect(await until { loaded == [0] })
        #expect(source.row(0)?.left == [0])
    }

    @Test("asking again while a page is on its way reads it once")
    func readsOnce() async {
        let fake = FakeRead()
        let source = BinaryRowSource { try fake.read($0) }
        source.pagesOnScreen = { [0] }
        var loaded = 0
        source.onLoad = { _ in loaded += 1 }
        _ = source.row(0)
        #expect(await until { fake.readPages == [0] })
        // The read is under way now: a redraw asks for the same page, from the same or another row.
        _ = source.row(0)
        _ = source.row(1)
        fake.release(0)
        #expect(await until { loaded == 1 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(fake.readPages == [0])
        #expect(loaded == 1)
    }

    @Test("one read at a time, and a page that has left the screen is not read")
    func oneAtATimeAndOnlyOnScreen() async {
        let fake = FakeRead()
        let source = BinaryRowSource { try fake.read($0) }
        var onScreen: Set<Int64> = [0]
        source.pagesOnScreen = { onScreen }
        _ = source.row(0)
        #expect(await until { fake.readPages == [0] })
        onScreen = [0, 1, 2]
        _ = source.row(rowsPerPage)
        _ = source.row(rowsPerPage * 2)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(fake.readPages == [0], "the second read waits for the first")
        onScreen = [2]
        fake.release(0)
        fake.release(2)
        #expect(await until { fake.readPages == [0, 2] })
        fake.release(1)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(fake.readPages == [0, 2], "page 1 scrolled away before its turn")
    }

    @Test("a page that fails is reported once and not asked for again")
    func failureOnce() async {
        let fake = FakeRead()
        let source = BinaryRowSource { try fake.read($0) }
        source.pagesOnScreen = { [0] }
        var failures = 0
        source.onFailure = { _ in failures += 1 }
        fake.fail(0)
        fake.release(0)
        _ = source.row(0)
        #expect(await until { failures == 1 })
        _ = source.row(0)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(failures == 1)
        #expect(fake.readPages == [0])
    }
}
