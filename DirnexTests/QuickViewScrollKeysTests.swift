import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// ⇧↑ / ⇧↓, ⇧Page Up / ⇧Page Down, ⇧← / ⇧→ and ⇧Home / ⇧End in the file list while a Quick View preview
/// is up (2026-10-18): which move each key asks for, that it never also moves the cursor, and that with
/// no preview up every key still does what it did before. What a move does to each backend is
/// `QuickViewScrollSurfaceTests`'.
@Suite("Quick View scroll keys")
@MainActor
struct QuickViewScrollKeysTests {
    private static let here = VFSPath.local("/tmp/dirnex-scroll-keys")

    private func makePane() async throws -> WindowedPane {
        let entries = ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"].map {
            Handoff.local("/tmp/dirnex-scroll-keys/\($0)")
        }
        let backend = Handoff.StubBackend(listings: [Self.here: entries])
        let source = windowedPane(showing: entries, at: Self.here, backend: backend)
        try await settleUntil { source.pane.tabs[0].hasLoaded }
        source.window.layoutIfNeeded()
        // On the second file, so a step either way has somewhere to go.
        let table = source.pane.tableView
        let second = source.pane.parentRowCount + 1
        table.selectRowIndexes(IndexSet(integer: second), byExtendingSelection: false)
        try #require(table.selectedRow == second)
        return source
    }

    /// A key as the keyboard sends it: the arrows carry the keypad and function flags, the rest of the
    /// navigation cluster the function flag alone.
    private func key(_ keyCode: UInt16, shift: Bool = true) throws -> NSEvent {
        let scalar = switch keyCode {
        case 123: NSLeftArrowFunctionKey
        case 124: NSRightArrowFunctionKey
        case 125: NSDownArrowFunctionKey
        case 126: NSUpArrowFunctionKey
        case 115: NSHomeFunctionKey
        case 119: NSEndFunctionKey
        case 116: NSPageUpFunctionKey
        default: NSPageDownFunctionKey
        }
        let characters = String(try #require(UnicodeScalar(UInt32(scalar))))
        var flags: NSEvent.ModifierFlags = (123...126).contains(keyCode)
            ? [.numericPad, .function]
            : .function
        if shift { flags.insert(.shift) }
        return try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    @Test("with a preview up, each ⇧ key asks for its move and the cursor stays on its file")
    func eachKeyAsksForItsMove() async throws {
        let source = try await makePane()
        source.host.quickViewMode = .pane
        let table = source.pane.tableView
        let row = table.selectedRow
        let keys: [(UInt16, QuickViewScroll)] = [
            (126, .lineUp), (125, .lineDown), (116, .pageUp), (121, .pageDown),
            (123, .top), (124, .end), (115, .top), (119, .end)
        ]
        for (keyCode, _) in keys {
            table.keyDown(with: try key(keyCode))
        }
        #expect(source.host.quickViewScrolls == keys.map(\.1))
        #expect(table.selectedRow == row)
    }

    /// The negative control for the routing: the same keys with no preview up must reach the table as
    /// before, which for ⇧↓ in this single-selection table is the plain cursor step.
    @Test("with no preview up, ⇧↓ moves the cursor as it always did and scrolls nothing")
    func noPreviewLeavesTheKeysAlone() async throws {
        let source = try await makePane()
        let table = source.pane.tableView
        let row = table.selectedRow
        table.keyDown(with: try key(125))
        #expect(table.selectedRow == row + 1)
        table.keyDown(with: try key(115)) // ⇧Home: the first row, as Home
        #expect(table.selectedRow == 0)
        #expect(source.host.quickViewScrolls.isEmpty)
    }

    @Test("without ⇧ the keys keep their meaning: Page Down moves the cursor, not the preview")
    func unshiftedKeysAreUnchanged() async throws {
        let source = try await makePane()
        source.host.quickViewMode = .pane
        let table = source.pane.tableView
        let row = table.selectedRow
        table.keyDown(with: try key(121, shift: false))
        #expect(table.selectedRow > row)
        table.keyDown(with: try key(126, shift: false))
        #expect(source.host.quickViewScrolls.isEmpty)
    }

    /// At full size a bare → flips to the next file and ⇧→ used to as well, since the flip was offered
    /// every arrow before ⇧ was looked at. Now ⇧ decides between the two.
    @Test("at full size → flips to the next file and ⇧→ scrolls to the end instead")
    func fullSizeSeparatesFlipFromScroll() async throws {
        let source = try await makePane()
        source.host.quickViewMode = .fullWindow
        let table = source.pane.tableView
        table.keyDown(with: try key(124, shift: false))
        #expect(source.host.quickViewFlips == [1])
        #expect(source.host.quickViewScrolls.isEmpty)

        table.keyDown(with: try key(124))
        table.keyDown(with: try key(125))
        #expect(source.host.quickViewFlips == [1])
        #expect(source.host.quickViewScrolls == [.end, .lineDown])
    }

    @Test("every key the table maps is a ⇧-key it hands over, and no other key is")
    func keyCodeMap() {
        #expect(QuickViewScroll(shiftedKeyCode: 126) == .lineUp)
        #expect(QuickViewScroll(shiftedKeyCode: 125) == .lineDown)
        #expect(QuickViewScroll(shiftedKeyCode: 116) == .pageUp)
        #expect(QuickViewScroll(shiftedKeyCode: 121) == .pageDown)
        #expect(QuickViewScroll(shiftedKeyCode: 123) == .top)
        #expect(QuickViewScroll(shiftedKeyCode: 115) == .top)
        #expect(QuickViewScroll(shiftedKeyCode: 124) == .end)
        #expect(QuickViewScroll(shiftedKeyCode: 119) == .end)
        // Return, Space, Tab, the letter a.
        for other: UInt16 in [36, 49, 48, 0] {
            #expect(QuickViewScroll(shiftedKeyCode: other) == nil)
        }
    }
}
