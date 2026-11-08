import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Holds each comparison open until the test lets it go or the window asks it to stop.
final class HeldComparison: @unchecked Sendable {
    private let lock = NSLock()
    private var isReleased = false
    private var starts = 0
    private var stops = 0
    private var finishes = 0
    /// Whether it goes on regardless of a Stop, as a comparison on its last stretch does.
    private let ignoresStop: Bool

    init(ignoresStop: Bool = false) {
        self.ignoresStop = ignoresStop
    }

    var runs: Int {
        lock.withLock { starts }
    }

    var stopsSeen: Int {
        lock.withLock { stops }
    }

    var runsFinished: Int {
        lock.withLock { finishes }
    }

    func release() {
        lock.withLock { isReleased = true }
    }

    private var released: Bool {
        lock.withLock { isReleased }
    }

    func prepare(
        _ left: CompareSource,
        _ right: CompareSource,
        _ options: LineDiffOptions,
        _ limit: Int,
        isCancelled: @Sendable () -> Bool
    ) throws(CancellationError) -> CompareWindowController.Prepared {
        lock.withLock { starts += 1 }
        while !released {
            if isCancelled(), !ignoresStop {
                lock.withLock { stops += 1 }
                throw CancellationError()
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        defer { lock.withLock { finishes += 1 } }
        return try CompareWindowController.prepare(
            left: left,
            right: right,
            options: options,
            coloringLimit: limit
        )
    }
}

/// What the suites on a comparison that takes a while share. Windows are built directly rather than
/// through `present`, which would save a frame in the user's defaults.
@MainActor
protocol CompareComparingTesting: ByteWindowTesting {}

extension CompareComparingTesting {
    func source(_ name: String, _ text: String) throws -> CompareSource {
        try CompareSource(
            name: name,
            detail: "/\(name)",
            origin: .local("/\(name)"),
            document: ComparedDocument.decode(Data(text.utf8)),
            language: nil,
            target: nil,
            writeBack: nil
        )
    }

    func standIn(_ name: String) -> CompareSource {
        CompareSource(
            name: name,
            detail: "/\(name)",
            origin: .local("/\(name)"),
            document: .empty,
            language: nil,
            target: nil,
            writeBack: nil
        )
    }

    func controller(
        held: HeldComparison,
        reading: CompareReading? = nil,
        left: CompareSource? = nil,
        right: CompareSource? = nil
    ) throws -> CompareWindowController {
        try CompareWindowController(
            left: left ?? source("left.txt", "same\nleft\n"),
            right: right ?? source("right.txt", "same\nright\n"),
            saving: .none,
            reading: reading,
            preparer: { left, right, options, limit, isCancelled throws(CancellationError) in
                try held.prepare(left, right, options, limit, isCancelled: isCancelled)
            }
        )
    }

    func comparing(_ controller: CompareWindowController) async -> Bool {
        await until { controller.toolbar.comparingState == .comparing }
    }
}
