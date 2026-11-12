import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The byte view (PLAN.md §M37 Slice 2): both files' bytes in one table, the window up before the
/// scan ends, and what it says.
///
/// Assertions on sentences look for a file's name or a number rather than the words, because the
/// app test target inherits the developer's own `AppleLanguages` pin (docs/NOTES.md ▸ Localization).
@Suite("Byte comparison window")
@MainActor
struct BinaryCompareWindowTests: ByteWindowTesting {
    // MARK: - Rows

    @Test("the table has a row for every sixteen bytes of the longer file, and a column per side")
    func rowCounts() throws {
        let fixture = try fixture([UInt8](repeating: 1, count: 33), [UInt8](repeating: 1, count: 5))
        defer { fixture.cleanup() }
        let controller = try window(fixture)
        #expect(controller.numberOfRows(in: controller.table) == 3)
        #expect(controller.table.tableColumns.count == 3)
        #expect(controller.rightColumn.title == "/r/right.bin")
        #expect(controller.rightColumn.headerToolTip == "/r/right.bin")
    }

    @Test(
        "a row shows each file's own bytes once its page has been read, and the offset before that"
    )
    func rowContent() async throws {
        let fixture = try fixture([0x41, 0x42], [0x41, 0x43])
        defer { fixture.cleanup() }
        let controller = try window(fixture)
        #expect(controller.content(column: controller.offsetColumn, row: 0) == .offset("00000000"))
        _ = controller.rows.row(0)
        #expect(await until { controller.rows.row(0) != nil })
        let row = try #require(controller.rows.row(0))
        #expect(controller.content(column: controller.leftColumn, row: 0) == .side(row, .left))
        #expect(controller.content(column: controller.rightColumn, row: 0) == .side(row, .right))
        #expect(row.left == [0x41, 0x42])
        #expect(row.right == [0x41, 0x43])
    }

    @Test("a cell on screen is filled in when its page arrives")
    func cellFillsIn() async throws {
        let fixture = try fixture(Array(repeating: 7, count: 64), Array(repeating: 8, count: 64))
        defer { fixture.cleanup() }
        let controller = try window(fixture)
        let column = controller.table.column(withIdentifier: controller.leftColumn.identifier)
        let view = controller.table.view(atColumn: column, row: 0, makeIfNecessary: true)
        let cell = try #require(view as? BinaryHexCell)
        controller.table.layoutSubtreeIfNeeded()
        #expect(await until {
            if case let .side(row?, .left) = cell.content { return row.left.first == 7 }
            return false
        })
    }

    @Test("a row prepared before its page was read fills in when a scroll brings it on screen")
    func blankCellFillsOnScroll() async throws {
        let fixture = try fixture(Array(repeating: 7, count: 64), Array(repeating: 8, count: 64))
        defer { fixture.cleanup() }
        let controller = try window(fixture)
        let column = controller.table.column(withIdentifier: controller.leftColumn.identifier)
        let view = controller.table.view(atColumn: column, row: 0, makeIfNecessary: true)
        let cell = try #require(view as? BinaryHexCell)
        _ = controller.rows.row(0)
        #expect(await until { controller.rows.row(0) != nil })
        cell.content = .side(nil, .left)
        controller.tableDidScroll(Notification(name: NSView.boundsDidChangeNotification))
        if case let .side(row?, .left) = cell.content {
            #expect(row.left.first == 7)
        } else {
            Issue.record("the cell is still blank")
        }
    }

    @Test("a cell says what it shows to VoiceOver and the accessibility tree")
    func accessibility() {
        let cell = BinaryHexCell()
        let row = BinaryHexRow(offset: 0, left: [0x41], right: [])
        cell.content = .side(row, .left)
        #expect(cell.isAccessibilityElement())
        #expect(cell.accessibilityRole() == .staticText)
        #expect((cell.accessibilityValue() as? String)?.hasPrefix("41 ") == true)
        #expect(
            (cell.accessibilityValue() as? String)?.hasSuffix(
                "A" + String(repeating: " ", count: 15)
            ) == true
        )
    }

    @Test("a row the sides agree on has no fill, and the side with no byte has the gap's")
    func fills() {
        let same = BinaryHexRow(offset: 0, left: [1], right: [1])
        #expect(BinaryCompareStyle.fill(for: same, side: .left) == nil)
        let differs = BinaryHexRow(offset: 0, left: [1], right: [2])
        #expect(BinaryCompareStyle.fill(for: differs, side: .left) === CompareColors.removedRow)
        #expect(BinaryCompareStyle.fill(for: differs, side: .right) === CompareColors.insertedRow)
        let oneSided = BinaryHexRow(offset: 0, left: [1], right: [])
        #expect(BinaryCompareStyle.fill(for: oneSided, side: .right) === CompareColors.gapRow)
        #expect(BinaryCompareStyle.fill(for: oneSided, side: .left) === CompareColors.removedRow)
    }

    @Test("only the arrows and the counter show on the toolbar")
    func toolbar() throws {
        let fixture = try fixture([1], [2])
        defer { fixture.cleanup() }
        let toolbar = try window(fixture).toolbar
        for hidden in [
            toolbar.copy,
            toolbar.swap,
            toolbar.ignoresCase,
            toolbar.ignoresLineEndings,
            toolbar.whitespace
        ] {
            #expect(hidden.isHidden)
        }
        #expect(!toolbar.navigation.isHidden)
    }

    // MARK: - The scan

    @Test("the window has its rows and takes keys before the scan has answered")
    func windowBeforeTheScanEnds() async throws {
        let fixture = try fixture([1, 2, 3], [1, 9, 3])
        defer { fixture.cleanup() }
        let gate = CancellationFlag()
        let controller = try window(fixture) { pair, _, _ in
            while !gate.isCancelled {
                Thread.sleep(forTimeInterval: 0.005)
            }
            return try BinaryComparison.scan(pair)
        }
        controller.startScan()
        _ = controller.rows.row(0)
        #expect(await until { controller.rows.row(0) != nil })
        #expect(controller.comparison == nil)
        #expect(controller.toolbar.counter.stringValue.isEmpty)
        gate.isCancelled = true
        #expect(await until { controller.comparison?.isFinished == true })
    }

    @Test("a running scan's findings show as they come, and say nothing of bytes not yet compared")
    func partialFindings() async throws {
        let fixture = try fixture(Array(repeating: 0, count: 64), Array(repeating: 0, count: 64))
        defer { fixture.cleanup() }
        let gate = CancellationFlag()
        let found = BinaryComparison(
            leftByteSize: 1000,
            rightByteSize: 1000,
            differences: BinaryDifferenceList(),
            scannedByteCount: 450
        )
        let controller = try window(fixture) { pair, report, _ in
            report(found)
            while !gate.isCancelled {
                Thread.sleep(forTimeInterval: 0.005)
            }
            return try BinaryComparison.scan(pair)
        }
        controller.startScan()
        #expect(await until { controller.comparison != nil })
        #expect(controller.banner.stringValue.contains("45"))
        #expect(
            controller.toolbar.counter.stringValue.isEmpty,
            "\"no differences\" would be a claim"
        )
        gate.isCancelled = true
        #expect(await until { controller.comparison?.isFinished == true })
        #expect(!controller.toolbar.counter.stringValue.isEmpty)
    }

    @Test("closing the window stops the scan")
    func closeStopsTheScan() async throws {
        let fixture = try fixture([1], [2])
        defer { fixture.cleanup() }
        let ended = CancellationFlag()
        let controller = try window(fixture) { _, _, isCancelled in
            while !isCancelled() {
                Thread.sleep(forTimeInterval: 0.005)
            }
            ended.isCancelled = true
            throw CancellationError()
        }
        controller.startScan()
        controller.window?.close()
        #expect(await until { ended.isCancelled })
        #expect(controller.scanFailure == nil, "a Stop is not a failure")
    }

    @Test("a scan that fails says so, and why")
    func scanFailure() async throws {
        let fixture = try fixture([1], [2])
        defer { fixture.cleanup() }
        let controller = try window(fixture) { _, _, _ in
            throw VFSError.notFound(.local("/gone/away.bin"))
        }
        controller.startScan()
        #expect(await until { controller.scanFailure != nil })
        #expect(controller.bannerSentences().count == 2)
    }

    // MARK: - What it says

    @Test("the banner names the file that could not be read as text", arguments: [
        BinaryCompareReason.notText(name: "picture.raw"),
        BinaryCompareReason.undecodable(name: "picture.raw")
    ])
    func reasonNamesTheFile(reason: BinaryCompareReason) {
        #expect(BinaryCompareWindowController.reasonText(reason).contains("picture.raw"))
    }

    @Test("the banner counts the bytes that differ, in full")
    func bannerCounts() async throws {
        var right = [UInt8](repeating: 0, count: 2000)
        right[10] = 1
        right[1500] = 1
        let fixture = try fixture([UInt8](repeating: 0, count: 2000), right)
        defer { fixture.cleanup() }
        let controller = try window(fixture)
        #expect(await finished(controller))
        let formatted = Int64(2000).formatted(.number)
        #expect(controller.banner.stringValue.contains(formatted))
    }

    @Test("the banner names the longer file")
    func bannerNamesTheLongerFile() async throws {
        let fixture = try fixture([1, 2], [1, 2, 3, 4, 5])
        defer { fixture.cleanup() }
        let controller = try window(fixture)
        #expect(await finished(controller))
        #expect(controller.banner.stringValue.contains("right.bin"))
    }

    @Test("identical files say so, with no change to step to")
    func identicalFiles() async throws {
        let fixture = try fixture([1, 2], [1, 2])
        defer { fixture.cleanup() }
        let controller = try window(fixture)
        #expect(await finished(controller))
        #expect(controller.comparison?.isIdentical == true)
        #expect(controller.table.selectedRow == -1)
        #expect(!controller.toolbar.navigation.isEnabled(forSegment: 0))
    }

    @Test("an insertion's dense stretch is named by its offsets")
    func bannerNamesDenseStretch() async throws {
        // Bytes with no repeat short of 256 steps, where a shift by three leaves almost nothing equal.
        let left = (0..<(256 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 37 ^ $0 >> 8) }
        var right = left
        right.insert(contentsOf: [1, 2, 3], at: 0x1000)
        let fixture = try fixture(left, right)
        defer { fixture.cleanup() }
        let controller = try window(fixture)
        #expect(await finished(controller))
        #expect(controller.banner.stringValue.contains("00001"))
    }
}
