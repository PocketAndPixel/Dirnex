import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Two files on disk for a byte window to compare.
struct ByteWindowFixture {
    let directory: URL
    let left: VFSPath
    let right: VFSPath

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    func pair() throws -> BinaryFilePair {
        try BinaryFilePair(left: left, right: right)
    }
}

/// What the byte view's suites share. Every window here is built directly rather than through
/// `present`, which would save a frame in the user's defaults.
@MainActor
protocol ByteWindowTesting {}

extension ByteWindowTesting {
    func fixture(_ left: [UInt8], _ right: [UInt8]) throws -> ByteWindowFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-byte-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let leftURL = directory.appendingPathComponent("left.bin")
        let rightURL = directory.appendingPathComponent("right.bin")
        try Data(left).write(to: leftURL)
        try Data(right).write(to: rightURL)
        return ByteWindowFixture(
            directory: directory,
            left: .local(leftURL.path),
            right: .local(rightURL.path)
        )
    }

    func window(
        _ fixture: ByteWindowFixture,
        reason: BinaryCompareReason = .notText(name: "left.bin"),
        scanner: @escaping BinaryCompareWindowController.Scanner = BinaryCompareWindowController.liveScanner
    ) throws -> BinaryCompareWindowController {
        let controller = try BinaryCompareWindowController(
            left: BinaryCompareSide(name: "left.bin", detail: "/l/left.bin", path: fixture.left),
            right: BinaryCompareSide(name: "right.bin", detail: "/r/right.bin", path: fixture.right),
            pair: fixture.pair(),
            reason: reason,
            scanner: scanner
        )
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.table.layoutSubtreeIfNeeded()
        return controller
    }

    /// Wait for `condition`, by suspending, since an async read lands only when this actor does.
    /// A long bound, since in a full run another suite can hold the main actor for seconds, and the
    /// bound costs time only when something has really failed.
    func until(
        within seconds: Double = 60,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func finished(_ controller: BinaryCompareWindowController) async -> Bool {
        controller.startScan()
        return await until { controller.comparison?.isFinished == true }
    }
}
