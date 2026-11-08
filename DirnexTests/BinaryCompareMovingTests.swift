import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Getting around the byte view (PLAN.md §M37 Slice 2).
@Suite("Byte comparison window — moving")
@MainActor
struct BinaryCompareMovingTests: ByteWindowTesting {
    private func key(
        _ code: UInt16,
        _ special: NSEvent.SpecialKey?,
        _ modifiers: NSEvent.ModifierFlags
    ) -> NSEvent? {
        let text = special.map { String(Character(UnicodeScalar($0.rawValue) ?? " ")) } ?? ""
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: text,
            charactersIgnoringModifiers: text,
            isARepeat: false,
            keyCode: code
        )
    }

    private let next = (code: UInt16(125), special: NSEvent.SpecialKey.downArrow)
    private let previous = (code: UInt16(126), special: NSEvent.SpecialKey.upArrow)

    // MARK: - Moving

    /// Three differences, far enough apart to be three changes, and two bytes only the right has.
    private func threeChanges() throws -> (ByteWindowFixture, BinaryCompareWindowController) {
        let count = 100 * 16
        var right = [UInt8](repeating: 0, count: count)
        right[160] = 1
        right[800] = 1
        right[1300] = 1
        let fixture = try fixture([UInt8](repeating: 0, count: count), right + [1, 2])
        return try (fixture, window(fixture))
    }

    @Test("the window opens on the first difference")
    func opensOnFirstDifference() async throws {
        let (fixture, controller) = try threeChanges()
        defer { fixture.cleanup() }
        #expect(await finished(controller))
        #expect(controller.table.selectedRow == 10)
        #expect(controller.currentChangeOffset == 160)
    }

    @Test("it stays where the user went if that came before the first difference was found")
    func doesNotJumpAfterTheUserMoved() async throws {
        let (fixture, controller) = try threeChanges()
        defer { fixture.cleanup() }
        controller.table.selectRowIndexes([50], byExtendingSelection: false)
        #expect(await finished(controller))
        #expect(controller.table.selectedRow == 50)
        #expect(controller.currentChangeOffset == nil)
    }

    @Test("the keys step through every difference, the bytes only one side has last")
    func keysStep() async throws {
        let (fixture, controller) = try threeChanges()
        defer { fixture.cleanup() }
        #expect(await finished(controller))
        let down = try #require(key(next.code, next.special, [.option, .command]))
        let up = try #require(key(previous.code, previous.special, [.option, .command]))
        #expect(controller.handleKey(down))
        #expect(controller.table.selectedRow == 50)
        #expect(controller.handleKey(down))
        #expect(controller.table.selectedRow == 81)
        #expect(controller.handleKey(down))
        #expect(
            controller.table.selectedRow == 100,
            "the tail starts on the row past the shared bytes"
        )
        #expect(controller.handleKey(up))
        #expect(controller.table.selectedRow == 81)
    }

    @Test("next from a row the user moved to is the difference after it, or at it")
    func nextFromTheUsersRow() async throws {
        let (fixture, controller) = try threeChanges()
        defer { fixture.cleanup() }
        #expect(await finished(controller))
        controller.table.selectRowIndexes([20], byExtendingSelection: false)
        #expect(controller.currentChangeOffset == nil, "moving by hand leaves no change current")
        controller.goToNextChange()
        #expect(controller.table.selectedRow == 50)
        controller.table.selectRowIndexes([30], byExtendingSelection: false)
        controller.table.selectRowIndexes([50], byExtendingSelection: false)
        controller.goToNextChange()
        #expect(controller.table.selectedRow == 50, "a change that starts on the row counts")
    }

    @Test("the row of a change is on screen after going to it")
    func revealIsOnScreen() async throws {
        let (fixture, controller) = try threeChanges()
        defer { fixture.cleanup() }
        #expect(await finished(controller))
        for offset: Int64 in [160, 800, 1300, 1600] {
            controller.goToChange(at: offset)
            controller.table.layoutSubtreeIfNeeded()
            let visible = try #require(controller.visibleRows)
            #expect(visible.contains(Int(BinaryHexLayout.row(containing: offset))))
        }
    }

    @Test("a change arrives three rows below whatever covers the top of the table")
    func revealLeavesContextAbove() async throws {
        let (fixture, controller) = try threeChanges()
        defer { fixture.cleanup() }
        #expect(await finished(controller))
        controller.goToChange(at: 800)
        controller.table.layoutSubtreeIfNeeded()
        let clip = controller.scrollView.contentView
        let fromTop = controller.table.rect(ofRow: 50).minY - clip.bounds.minY + controller.restingTop
        #expect(fromTop == 3 * controller.table.rowHeight)
    }

    @Test("the accessibility tree offers the rows on screen, not one element for every row")
    func accessibilityStaysOnScreen() async throws {
        let fixture = try fixture([], [])
        defer { fixture.cleanup() }
        #expect(truncate(fixture.left.path, 20 << 30) == 0)
        #expect(truncate(fixture.right.path, 20 << 30) == 0)
        let answer = BinaryComparison(
            leftByteSize: 20 << 30,
            rightByteSize: 20 << 30,
            differences: BinaryDifferenceList(),
            scannedByteCount: 20 << 30
        )
        let controller = try window(fixture) { _, _, _ in answer }
        #expect(await finished(controller))
        controller.table.layoutSubtreeIfNeeded()
        let visible = try #require(controller.visibleRows)
        for row in visible {
            _ = controller.table.view(atColumn: 0, row: row, makeIfNecessary: true)
        }
        let rows = try #require(controller.table.accessibilityRows())
        #expect(rows.count == visible.count)
        let children = try #require(controller.table.accessibilityChildren())
        #expect(children.count == visible.count + 1, "the rows on screen and the header")
    }

    @Test("the overview strip holds every change, and the tail reads as what only one side has")
    func overview() async throws {
        let (fixture, controller) = try threeChanges()
        defer { fixture.cleanup() }
        #expect(await finished(controller))
        #expect(controller.overview.changeRows == [10..<11, 50..<51, 81..<82, 100..<101])
        #expect(controller.overview.kinds == [.change, .change, .change, .insertion])
        #expect(controller.overview.rowCount == 101)
    }

    @Test("a click in the strip goes there and leaves no change current")
    func overviewJump() async throws {
        let (fixture, controller) = try threeChanges()
        defer { fixture.cleanup() }
        #expect(await finished(controller))
        controller.overview.onJump?(90)
        controller.table.layoutSubtreeIfNeeded()
        #expect(controller.currentChangeOffset == nil)
        #expect(controller.visibleRows?.contains(90) == true)
    }

    @Test("⌘W and Escape close the window, and a plain arrow is left to the table")
    func closingKeys() throws {
        let fixture = try fixture([1], [2])
        defer { fixture.cleanup() }
        let controller = try window(fixture)
        let arrow = try #require(key(next.code, next.special, []))
        #expect(!controller.handleKey(arrow))
        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53
        ))
        #expect(controller.handleKey(escape))
    }

    // MARK: - Very large files

    @Test("a sparse 1 TiB pair has all its rows, and its last row is reachable and right")
    func oneTebibyte() async throws {
        let fixture = try fixture([], [])
        defer { fixture.cleanup() }
        let size: Int64 = 1 << 40
        #expect(truncate(fixture.left.path, size) == 0)
        #expect(truncate(fixture.right.path, size) == 0)
        var list = BinaryDifferenceList()
        let left: [UInt8] = [0]
        let right: [UInt8] = [1]
        left.withUnsafeBytes { leftBytes in
            right.withUnsafeBytes { rightBytes in
                list.consume(leftBytes, rightBytes, at: size - 1)
            }
        }
        let answer = BinaryComparison(
            leftByteSize: size,
            rightByteSize: size,
            differences: list,
            scannedByteCount: size
        )
        let controller = try window(fixture) { _, _, _ in answer }
        #expect(controller.rowCount == 1 << 36)
        #expect(controller.offsetDigits == 10)
        #expect(await finished(controller))
        controller.table.layoutSubtreeIfNeeded()
        let last = (1 << 36) - 1
        #expect(controller.table.selectedRow == last)
        #expect(controller.visibleRows?.contains(last) == true)
        // Auto Layout cuts a table at 10^10 points on the first pass after a size change.
        controller.window?.setContentSize(NSSize(width: 900, height: 500))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.table.layoutSubtreeIfNeeded()
        #expect(controller.table.frame.height == CGFloat(1 << 36) * BinaryCompareStyle.rowHeight)
        controller.reveal(row: last)
        controller.table.layoutSubtreeIfNeeded()
        #expect(controller.visibleRows?.contains(last) == true)
        #expect(
            controller.content(column: controller.offsetColumn, row: last) == .offset("FFFFFFFFF0")
        )
        _ = controller.rows.row(Int64(last))
        #expect(await until { controller.rows.row(Int64(last)) != nil })
        #expect(controller.rows.row(Int64(last))?.left.count == 16)
    }

    @Test("rows stop where the table can no longer reach them, and it is past any real file")
    func rowLimit() {
        let bytes = BinaryCompareStyle.maximumRows * BinaryHexLayout.bytesPerRow
        #expect(bytes >= 15 << 40)
        #expect(
            CGFloat(BinaryCompareStyle.maximumRows) * BinaryCompareStyle.rowHeight < 0x1000_0000_0000
        )
    }
}
