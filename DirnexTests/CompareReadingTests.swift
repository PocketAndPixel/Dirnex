import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A window opened before its files are read, and the route that gets a pair there (PLAN.md §M37
/// Slice 3).
@Suite("Compare window — opening before the read")
@MainActor
struct CompareReadingTests: CompareComparingTesting {
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var outcome: Result<(CompareSource, CompareSource), CompareReadFailure>?

        var reads: Int {
            lock.withLock { count }
        }

        func finish(_ result: Result<(CompareSource, CompareSource), CompareReadFailure>) {
            lock.withLock { outcome = result }
        }

        func read(
            isCancelled: @Sendable () -> Bool
        ) -> Result<(CompareSource, CompareSource), CompareReadFailure> {
            lock.withLock { count += 1 }
            while true {
                if isCancelled() {
                    return .failure(CompareReadFailure(name: "left.txt", reason: .stopped))
                }
                if let result = lock.withLock({ outcome }) {
                    return result
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
    }

    private final class Failed {
        var failure: CompareReadFailure?
    }

    private func reading(
        _ reads: Reads,
        into failed: Failed
    ) -> CompareReading {
        CompareReading(
            read: { reads.read(isCancelled: $0) },
            failed: { failed.failure = $0 }
        )
    }

    @Test("a window opened before the read says Comparing at once, and names the files")
    func readingShowsAtOnce() throws {
        let held = HeldComparison()
        let window = try controller(
            held: held,
            reading: reading(Reads(), into: Failed()),
            left: standIn("a.log"),
            right: standIn("b.log")
        )
        window.startReading()
        defer { window.abandonComparing() }
        #expect(window.toolbar.comparingState == .comparing)
        #expect(window.leftPane.nameLabel.stringValue == "a.log")
        #expect(window.rightPane.nameLabel.stringValue == "b.log")
    }

    @Test("nothing offers to copy or edit a file that has not been read yet")
    func readingDisablesEdits() throws {
        let window = try controller(
            held: HeldComparison(),
            reading: reading(Reads(), into: Failed()),
            left: standIn("a.log"),
            right: standIn("b.log")
        )
        window.startReading()
        defer { window.abandonComparing() }
        #expect(!window.toolbar.copy.isEnabled(forSegment: 0))
        #expect(!window.toolbar.copy.isEnabled(forSegment: 1))
        #expect(!window.leftPane.editButton.isEnabled)
        #expect(!window.rightPane.editButton.isEnabled)
    }

    @Test("once the read lands, the files replace the stand-ins and are compared")
    func readingLands() async throws {
        let held = HeldComparison()
        held.release()
        let reads = Reads()
        let window = try controller(
            held: held,
            reading: reading(reads, into: Failed()),
            left: standIn("a.log"),
            right: standIn("b.log")
        )
        window.startReading()
        try reads.finish(.success((source("a.log", "one\n"), source("b.log", "two\n"))))
        #expect(await until { window.comparison != nil })
        #expect(window.reading == nil)
        #expect(window.left.document.lines.count == 1)
        #expect(window.right.document.lines.count == 1)
    }

    @Test("nothing compares the stand-ins while the read runs")
    func noComparingWhileReading() async throws {
        let held = HeldComparison()
        let window = try controller(
            held: held,
            reading: reading(Reads(), into: Failed()),
            left: standIn("a.log"),
            right: standIn("b.log")
        )
        window.startReading()
        defer { window.abandonComparing() }
        window.compute(options: LineDiffOptions(ignoresCase: true))
        window.swapSides()
        try await Task.sleep(for: .milliseconds(30))
        #expect(held.runs == 0)
        #expect(window.left.name == "a.log")
    }

    @Test("Stop during the read ends it, and Compare Again reads again")
    func stopDuringRead() async throws {
        let held = HeldComparison()
        held.release()
        let reads = Reads()
        let window = try controller(
            held: held,
            reading: reading(reads, into: Failed()),
            left: standIn("a.log"),
            right: standIn("b.log")
        )
        window.startReading()
        #expect(await until { reads.reads == 1 })
        window.stopComparing()
        #expect(window.toolbar.comparingState == .stopped)
        #expect(window.reading != nil)
        try reads.finish(.success((source("a.log", "one\n"), source("b.log", "two\n"))))
        window.compareAgain()
        #expect(await until { window.comparison != nil })
        #expect(reads.reads == 2)
    }

    @Test("a read that fails closes the window and hands on why")
    func readFails() async throws {
        let held = HeldComparison()
        let reads = Reads()
        let failed = Failed()
        let window = try controller(
            held: held,
            reading: reading(reads, into: failed),
            left: standIn("a.log"),
            right: standIn("b.log")
        )
        window.showWindow(nil)
        window.startReading()
        reads.finish(.failure(CompareReadFailure(name: "a.log", reason: .binary)))
        #expect(await until { failed.failure != nil })
        #expect(failed.failure == CompareReadFailure(name: "a.log", reason: .binary))
        #expect(window.window?.isVisible == false)
    }

    // MARK: - The route there

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("compare-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A file holding `head`, then zeros to `size` bytes without taking the space.
    private func file(in folder: URL, _ name: String, head: Data, size: Int64) throws -> CompareFile {
        let url = folder.appendingPathComponent(name)
        try head.write(to: url)
        #expect(truncate(url.path, size) == 0)
        return CompareFile(path: .local(url.path), origin: .local(url.path))
    }

    /// Longer than the first look at a file, so a NUL after it goes unseen until the whole read.
    private let text = Data(repeating: UInt8(ascii: "x"), count: TextPreview.sniffLength + 1)

    @Test("an ordinary pair is read first, as it always was")
    func routeOrdinary() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let left = try file(in: root, "a", head: text, size: Int64(text.count))
        let right = try file(in: root, "b", head: text, size: Int64(text.count))
        guard case .readFirst = CompareOpener.route(left, right, byteLimit: .max) else {
            Issue.record("expected the read to come first")
            return
        }
    }

    @Test("a side past 64 MiB opens the window first")
    func routeLarge() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let left = try file(in: root, "a", head: text, size: Int64(text.count))
        let right = try file(in: root, "b", head: text, size: ByteComparator.prescanByteLimit + 1)
        guard case .windowFirst = CompareOpener.route(left, right, byteLimit: .max) else {
            Issue.record("expected the window to come first")
            return
        }
    }

    @Test("exactly 64 MiB is still read first")
    func routeAtTheBoundary() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let left = try file(in: root, "a", head: text, size: ByteComparator.prescanByteLimit)
        guard case .readFirst = CompareOpener.route(left, left, byteLimit: .max) else {
            Issue.record("expected the read to come first")
            return
        }
    }

    @Test("a binary of any size is told apart without reading it")
    func routeBinary() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let left = try file(in: root, "a", head: text, size: Int64(text.count))
        let right = try file(in: root, "b", head: Data([0, 1]), size: 1 << 40)
        guard case let .refused(failure) = CompareOpener.route(left, right, byteLimit: .max) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(failure.reason == .binary)
        #expect(failure.name == "b")
    }

    @Test("a side past the limit is refused by size")
    func routeTooLarge() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let size = Int64(text.count) + 2000
        let left = try file(in: root, "a", head: text, size: size)
        guard case let .refused(failure) = CompareOpener.route(left, left, byteLimit: 1000) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(failure.reason == .tooLarge(byteSize: size, limit: 1000))
    }

    @Test("a large pair whose NUL is late still ends in the byte view")
    func lateNulGoesToBytes() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let size = ByteComparator.prescanByteLimit + 1
        let left = try file(in: root, "a", head: text, size: size)
        let right = try file(in: root, "b", head: text, size: size)
        let held = HeldComparison()
        var reason: BinaryCompareReason?
        var opened: CompareWindowController?
        CompareOpener.openWindow(
            left,
            detail: "left",
            right,
            detail: "right",
            byteLimit: .max,
            presentBytes: { _, _, _, shown in reason = shown },
            presentReading: { leftSide, rightSide, _, saving, reading in
                // Built here rather than through `present`, which would save a frame in the
                // user's defaults.
                let controller = CompareWindowController(
                    left: leftSide,
                    right: rightSide,
                    saving: saving,
                    reading: reading,
                    preparer: { left, right, options, limit, isCancelled throws(CancellationError) in
                        try held.prepare(left, right, options, limit, isCancelled: isCancelled)
                    }
                )
                opened = controller
                controller.startReading()
            },
            failed: { Issue.record("no alert was expected: \($0)") }
        )
        #expect(await until { reason != nil })
        #expect(reason == .notText(name: "a"))
        #expect(opened?.isComparing == false)
        #expect(held.runs == 0)
    }
}
