import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Dirnex's own compare window, on the app side (PLAN.md §M31 Slice 3). What a comparison *is* is
/// `DirnexCore`'s and tested there; these pin what the window does with it: that TextKit 2 stays on,
/// that rows are colored by the fragment the delegate hands out, that the panes stay level by row
/// far into a large file, and the keys.
///
/// Whether the colors *draw* is not something a test here can see: a `cacheDisplay` captures nothing
/// of a TextKit 2 text view (docs/NOTES.md ▸ Text fields and text views). That half is a live check.
@Suite("Compare window")
@MainActor
struct CompareWindowTests {
    private func source(
        _ name: String,
        _ text: String,
        language: SyntaxLanguage? = nil
    ) throws -> CompareSource {
        try CompareSource(
            name: name,
            detail: "/tmp/\(name)",
            document: ComparedDocument.decode(Data(text.utf8)),
            language: language
        )
    }

    /// A window showing `left` against `right`, computed on the spot rather than through `present`,
    /// so nothing is added to the app's list of open windows.
    private func window(
        _ left: String,
        _ right: String,
        options: LineDiffOptions = LineDiffOptions()
    ) async throws -> CompareWindowController {
        let leftSource = try source("left.swift", left, language: .swift)
        let rightSource = try source("right.swift", right, language: .swift)
        let controller = CompareWindowController(left: leftSource, right: rightSource, saving: .none)
        let prepared = CompareWindowController.prepare(
            left: leftSource,
            right: rightSource,
            options: options,
            coloringLimit: CompareTextStyle.syntaxColoringLimit
        )
        controller.show(prepared)
        try await settle(controller)
        return controller
    }

    private func settle(_ controller: CompareWindowController) async throws {
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        for pane in [controller.leftPane, controller.rightPane] {
            pane.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
        try await Task.sleep(for: .milliseconds(30))
    }

    @Test("the row coloring answers TextKit's fragment selector, so TextKit really calls it")
    func delegateIsEmitted() {
        let selector = NSSelectorFromString(
            "textLayoutManager:textLayoutFragmentForLocation:inTextElement:"
        )
        #expect(CompareRowColoring().responds(to: selector))
    }

    @Test("each pane stays on TextKit 2, shows its rows, and is laid out by the row coloring")
    func panesShowTheirRows() async throws {
        let controller = try await window(
            "let a = 1\nlet b = 2\n",
            "let a = 1\nlet b = 3\nlet c = 4\n"
        )
        let left = controller.leftPane.textView
        let right = controller.rightPane.textView
        #expect(left.textLayoutManager != nil)
        #expect(right.textLayoutManager != nil)
        #expect(left.string == "let a = 1\nlet b = 2\n\n")
        #expect(right.string == "let a = 1\nlet b = 3\nlet c = 4\n")
        #expect(left.textLayoutManager?.delegate is CompareRowColoring)
    }

    @Test("rows are drawn by row fragments carrying their row's fill, and a same row carries none")
    func fragmentsCarryFills() async throws {
        let controller = try await window("same\nold\n", "same\nnew\nadded\n")
        var fills: [Bool] = []
        controller.leftPane.textView.textLayoutManager?.enumerateTextLayoutFragments(
            from: nil,
            options: [.ensuresLayout]
        ) { fragment in
            fills.append((fragment as? CompareRowFragment)?.fill != nil)
            return true
        }
        // Left rows: "same", "old" against "new", and a gap against "added".
        #expect(fills == [false, true, true])
    }

    @Test("the pane is as wide as its widest row, so no row wraps and every row is one line tall")
    func rowsDoNotWrap() async throws {
        let long = String(repeating: "x", count: 600)
        let controller = try await window("short\n\(long)\nend\n", "short\n\(long)y\nend\n")
        let textView = controller.rightPane.textView
        #expect(textView.frame.width >= CGFloat(601) * CompareTextStyle.columnWidth)
        var tops: [CGFloat] = []
        textView.forEachVisibleRow { _, top in tops.append(top) }
        #expect(tops.count == 3)
        let steps = zip(tops.dropFirst(), tops).map { $0 - $1 }
        #expect(steps.allSatisfy { abs($0 - CompareTextStyle.lineHeight) < 0.01 })
    }

    @Test("copying gives the file's own text, without the gaps")
    func copyGivesTheFile() async throws {
        let controller = try await window("one\r\ntwo\n", "one\r\nnew\ntwo\n")
        let textView = controller.leftPane.textView
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("Dirnex.CompareWindowTests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        textView.pasteboard = pasteboard
        textView.selectAll(nil)
        textView.copy(nil)
        #expect(pasteboard.string(forType: .string) == "one\r\ntwo\n")
    }

    @Test("far into a large file, the two panes show the same row at the top")
    func panesStayLevel() async throws {
        // Lines of different lengths on each side, so TextKit's estimates of where a far row is
        // disagree between the two documents, which is the case keeping level by offset gets wrong.
        let left = (0..<20000).map { "\($0)" + String(repeating: "a", count: $0 % 90) }.joined(
            separator: "\n"
        )
        let right = (0..<20000).map { "\($0)" + String(repeating: "b", count: ($0 * 7) % 150) }
            .joined(separator: "\n")
        let controller = try await window(left, right)
        for target in [3000, 12000, 19000, 500] {
            controller.leftPane.textView.scroll(toRow: target, offset: 0, x: 0)
            try await settle(controller)
            let leftTop = controller.leftPane.textView.rowAtTop()
            let rightTop = controller.rightPane.textView.rowAtTop()
            #expect(leftTop?.row == target)
            #expect(rightTop?.row == leftTop?.row)
            #expect(abs((rightTop?.offset ?? 99) - (leftTop?.offset ?? 0)) < 1)
        }
    }

    @Test("⌥⌘↓ and ⌥⌘↑ go from change to change, and other keys pass through")
    func navigationKeys() async throws {
        let controller = try await window("a\nb\nc\nd\ne\n", "a\nB\nc\nD\ne\n")
        // A window opens on its first change.
        #expect(controller.currentChange == 0)
        #expect(controller.handleKey(key(.downArrow, keyCode: 125, modifiers: [.option, .command])))
        #expect(controller.currentChange == 1)
        #expect(controller.handleKey(key(.upArrow, keyCode: 126, modifiers: [.option, .command])))
        #expect(controller.currentChange == 0)
        #expect(!controller.handleKey(key(.downArrow, keyCode: 125, modifiers: [])))
        #expect(!controller.handleKey(key(.downArrow, keyCode: 125, modifiers: [.command])))
    }

    /// A line only the right file has is an insertion, drawn green. Swapped, the same line is only
    /// the left file's, a removal drawn red, which is the point of swapping.
    @Test("⌘U swaps the files, their names and the direction of each change, and swaps them back")
    func swapSides() async throws {
        let controller = try await window("a\nc\n", "a\nb\nc\n")
        #expect(controller.changeKinds == [.insertion])
        #expect(!controller.handleKey(letter("u", modifiers: [])))
        #expect(!controller.handleKey(letter("u", modifiers: [.command, .shift])))

        #expect(controller.handleKey(letter("u", modifiers: [.command])))
        // The title is set when the new comparison is shown, so this waits on the swap's result
        // rather than on the sources it exchanged first.
        try await settleUntil { controller.window?.title == "right.swift ↔ left.swift" }
        #expect(controller.leftPane.textView.string == "a\nb\nc\n")
        #expect(controller.rightPane.textView.string == "a\n\nc\n")
        #expect(controller.leftPane.textView.accessibilityLabel() == "right.swift")
        #expect(controller.rightPane.textView.accessibilityLabel() == "left.swift")
        #expect(controller.changeKinds == [.removal])

        controller.toolbar.swap.performClick(nil)
        try await settleUntil { controller.window?.title == "left.swift ↔ right.swift" }
        #expect(controller.leftPane.textView.string == "a\n\nc\n")
        #expect(controller.changeKinds == [.insertion])
    }

    @Test("the counter and the banner say what the rows cannot")
    func counterAndBanner() async throws {
        #expect(CompareToolbar.counterText(current: nil, count: 0) == "No differences")
        #expect(CompareToolbar.counterText(current: 2, count: 12) == "Change 3 of 12")
        let identical = TextComparison(
            ComparedText(text: "a\n", encoding: .utf8),
            ComparedText(text: "a\n", encoding: .utf16LittleEndian, hasByteOrderMark: true)
        )
        let banner = try #require(CompareWindowController.bannerText(for: identical))
        #expect(banner.hasPrefix("No line differs."))
        #expect(banner.contains("byte-order mark"))
        let endings = TextComparison(ComparedText(text: "a\r\nb\n"), ComparedText(text: "a\nb\n"))
        #expect(
            CompareWindowController.bannerText(for: endings) == "Lines marked ↵ end differently."
        )
        let plain = TextComparison(ComparedText(text: "a\n"), ComparedText(text: "b\n"))
        #expect(CompareWindowController.bannerText(for: plain) == nil)
    }

    /// Seen live in German in Slice 5: at the window's minimum width the counter gave way to the
    /// option controls and vanished, and in English it truncated.
    @Test("at the window's narrowest the counter still shows its longest text in full")
    func counterKeepsItsRoom() async throws {
        let left = (0..<40).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let right = (0..<40).map { $0 % 2 == 0 ? "line \($0)" : "edited \($0)" }
            .joined(separator: "\n") + "\n"
        let controller = try await window(left, right)
        let window = try #require(controller.window)
        let count = try #require(controller.comparison?.changeRows.count)
        #expect(count >= 10, "a two-digit count, so the last change is the widest text")
        controller.goToChange(count - 1)
        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: false)
        window.contentView?.layoutSubtreeIfNeeded()
        let counter = controller.toolbar.counter
        #expect(counter.frame.width > 0)
        #expect(counter.frame.width >= counter.intrinsicContentSize.width)
    }

    @Test(
        "the overview folds changes into one color per point, a removal beside an insertion a change"
    )
    func overviewBuckets() {
        let buckets = CompareOverviewView.buckets(
            height: 10,
            rowCount: 100,
            changes: [0..<5, 5..<10, 90..<91],
            kinds: [.removal, .insertion, .insertion]
        )
        #expect(buckets[0] == .change)
        #expect(buckets[9] == .insertion)
        #expect(buckets[5] == nil)
    }

    private func letter(_ character: String, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 0
        ) ?? NSEvent()
    }

    private func key(
        _ special: NSEvent.SpecialKey,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent {
        let characters = String(Character(UnicodeScalar(UInt16(special.rawValue)) ?? " "))
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) ?? NSEvent()
    }
}
