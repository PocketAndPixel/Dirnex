import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Finding text in Quick View's text preview (2026-09-17). Which text matches is `DirnexCore`'s and
/// tested there (`TextFindMatchesTests`); what is left is what the bar does to the text on screen —
/// which match is current and where stepping takes it, what is highlighted and in which color, that
/// a far match is brought into view, and that a new file forgets it all. The keys the bar shares with
/// the table (Esc, Return, Tab) are `QuickViewTableFilterKeysTests`'; the arrows, which step matches
/// here rather than rows, are tested again below.
///
/// Typing is driven through the window's real field editor, as the table's filter tests drive it.
@Suite("Quick View text find")
@MainActor
struct QuickViewTextFindTests {
    private typealias Fixtures = QuickViewTextFindFixtures
    private typealias Typing = QuickViewTableFilterFixtures

    private static let sample = "alpha Beta\nbeta gamma\nBETA delta\n"

    @Test("typing finds every occurrence, ignoring case, the first one current")
    func findsEveryOccurrence() async throws {
        let fixture = try await Fixtures.text(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        let text = Self.sample as NSString
        let expected = [
            text.range(of: "Beta"), text.range(of: "beta"), text.range(of: "BETA")
        ].map { $0.location..<NSMaxRange($0) }
        #expect(surface.find.matches?.ranges == expected)
        #expect(surface.find.current == 0)
        #expect(surface.filterBar.countLabel.stringValue.contains("1"))
        #expect(surface.filterBar.countLabel.stringValue.contains("3"))
        #expect(surface.filterBar.columnPicker.isHidden)
    }

    @Test("↑ and ↓ in the text step through the matches, wrapping past either end, keyboard kept")
    func arrowsStepThroughMatches() async throws {
        let fixture = try await Fixtures.text(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        let down = #selector(NSResponder.moveDown(_:))
        let up = #selector(NSResponder.moveUp(_:))
        try Typing.editor(of: surface).doCommand(by: down)
        #expect(surface.find.current == 1)
        try Typing.editor(of: surface).doCommand(by: down)
        try Typing.editor(of: surface).doCommand(by: down)
        #expect(surface.find.current == 0)
        try Typing.editor(of: surface).doCommand(by: up)
        #expect(surface.find.current == 2)
        #expect(surface.filterBar.countLabel.stringValue.contains("3"))
        #expect(surface.filterHasKeyboard)
    }

    @Test(
        "the matches are highlighted, the current one in its own color, and clearing takes them away"
    )
    func highlights() async throws {
        let fixture = try await Fixtures.text(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        let starts = try #require(surface.find.matches).ranges.map(\.lowerBound)
        var marks = Fixtures.highlights(surface)
        #expect(Set(marks.keys) == Set(starts))
        #expect(marks[starts[0]] == .systemOrange)
        #expect(marks[starts[1]] == .findHighlightColor)

        try Typing.editor(of: surface).doCommand(by: #selector(NSResponder.moveDown(_:)))
        marks = Fixtures.highlights(surface)
        #expect(marks[starts[0]] == .findHighlightColor)
        #expect(marks[starts[1]] == .systemOrange)

        // The view is still on TextKit 2, whose lazy layout a large file depends on.
        #expect(surface.textView.textLayoutManager != nil)

        try await Typing.type("", into: surface)
        #expect(Fixtures.highlights(surface).isEmpty)
        let storage = try #require(surface.textView.textStorage)
        #expect(storage.attribute(.backgroundColor, at: starts[1], effectiveRange: nil) == nil)
        #expect(surface.find.matches == nil)
        #expect(surface.filterBar.countLabel.stringValue.isEmpty)
    }

    /// A one-letter query over a 4 MB file has 100 000 matches, so only those near the screen carry a
    /// highlight; a match far down gains one when it is brought into view, and the first loses its.
    ///
    /// Three megabytes of lines of uneven length, so wrapping makes the heights uneven: under TextKit 2 a
    /// far match's position is then an estimate the first scroll lands short of, and only the later
    /// corrections bring it on screen (`revealCurrentMatch`, docs/NOTES.md ▸ AppKit).
    @Test("a far match is brought into view and highlighted there, and only the matches near it are")
    func farMatch() async throws {
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 20)
        let lines = (0..<14000).map { index -> String in
            let body = String(filler.prefix(10 + (index * 37) % 400))
            return index == 2 || index == 13990 ? "needle \(index) \(body)" : "line \(index) \(body)"
        }
        let fixture = try await Fixtures.text(lines.joined(separator: "\n"))
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("needle", into: surface)
        let ranges = try #require(surface.find.matches).ranges
        // Past `TextPreview.byteLimit` the far needle would not be read at all.
        #expect(fixture.surface.searchableText.utf8.count < TextPreview.byteLimit)
        try #require(ranges.count == 2)
        #expect(surface.find.current == 0)
        #expect(Set(Fixtures.highlights(surface).keys) == [ranges[0].lowerBound])

        try Typing.editor(of: surface).doCommand(by: #selector(NSResponder.moveDown(_:)))
        #expect(surface.find.current == 1)
        // Where a far match lies settles over a few turns.
        let settled = await Fixtures.settle {
            let onScreen = Fixtures.frame(of: ranges[1], in: surface)
                .map(surface.scrollView.documentVisibleRect.contains) ?? false
            return onScreen && Set(Fixtures.highlights(surface).keys) == [ranges[1].lowerBound]
        }
        #expect(settled)
        #expect(Set(Fixtures.highlights(surface).keys) == [ranges[1].lowerBound])
    }

    /// The fixture is where the two rules part: "ab1" stops matching once "ab2" is typed, so carrying
    /// on from it reaches the "ab2" after it, and starting over from the top would reach the one
    /// before it.
    @Test("typing more carries on from the current match rather than going back to the first")
    func refiningKeepsThePlace() async throws {
        let fixture = try await Fixtures.text("ab2 ab1 ab2x\n")
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("ab", into: surface)
        try Typing.editor(of: surface).doCommand(by: #selector(NSResponder.moveDown(_:)))
        #expect(surface.find.matches?.ranges[surface.find.current ?? -1] == 4..<6)

        try await Typing.type("ab2", into: surface)
        #expect(surface.find.matches?.ranges == [0..<3, 8..<11])
        #expect(surface.find.current == 1)
    }

    @Test("text found nowhere highlights nothing and says so")
    func noMatch() async throws {
        let fixture = try await Fixtures.text(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("zzz", into: surface)
        #expect(surface.find.matches?.isEmpty == true)
        #expect(surface.find.current == nil)
        #expect(Fixtures.highlights(surface).isEmpty)
        let label = surface.filterBar.countLabel.stringValue
        #expect(!label.isEmpty)
        #expect(!label.contains("0"))
    }

    @Test("an empty file has nothing to find in, and the command stays off")
    func emptyFile() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await QuickViewTableFixtures.loaded(
            try tree.write("empty.txt", contents: "")
        )
        #expect(preview.textSurface?.isHidden == false)
        #expect(preview.filterableSurface == nil)
    }

    @Test("a second Esc puts the bar away with its highlights and hands the keyboard back")
    func escapeTakesTheHighlightsAway() async throws {
        let fixture = try await Fixtures.text(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        var returned = 0
        surface.returnKeyboard = { returned += 1 }
        try await Typing.type("beta", into: surface)
        let cancel = #selector(NSResponder.cancelOperation(_:))
        try Typing.editor(of: surface).doCommand(by: cancel)
        #expect(Fixtures.highlights(surface).isEmpty)
        #expect(!surface.filterBar.isHidden)
        try Typing.editor(of: surface).doCommand(by: cancel)
        #expect(surface.filterBar.isHidden)
        #expect(returned == 1)
    }

    @Test("a new file opens with the bar away, nothing found, and a search still running dropped")
    func newFileForgetsTheSearch() async throws {
        let fixture = try await Fixtures.text(Self.sample)
        defer { fixture.cleanup() }
        let (preview, surface) = (fixture.preview, fixture.surface)
        try await Typing.type("beta", into: surface)

        let editor = try Typing.editor(of: surface)
        editor.insertText("x", replacementRange: NSRange(location: 4, length: 0))
        let stale = try #require(surface.filterTask)
        preview.show(try fixture.tree.write("other.txt", contents: "beta again\n"), style: .rendered)
        for _ in 0..<400 where surface.textView.string != "beta again\n" {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(surface.filterBar.isHidden)
        #expect(surface.filterBar.query.isEmpty)
        await stale.value
        #expect(surface.find.matches == nil)
        #expect(Fixtures.highlights(surface).isEmpty)
        #expect(surface.searchableText == "beta again\n")
    }

    @Test(
        "the bar keeps the mouse while it is up, and gives the spot back to the text once it is away"
    )
    func barKeepsTheMouse() async throws {
        let fixture = try await Fixtures.text(Self.sample)
        defer { fixture.cleanup() }
        let (preview, surface) = (fixture.preview, fixture.surface)
        surface.beginFiltering()
        surface.superview?.layoutSubtreeIfNeeded()
        let bar = surface.filterBar
        let point = bar.convert(
            NSPoint(x: bar.bounds.midX, y: bar.bounds.midY),
            to: preview.superview
        )
        let hit = try #require(preview.hitTest(point))
        #expect(hit.isDescendant(of: bar))

        surface.endFiltering()
        surface.superview?.layoutSubtreeIfNeeded()
        let afterwards = try #require(preview.hitTest(point))
        #expect(!afterwards.isDescendant(of: bar))
        #expect(afterwards.isDescendant(of: surface.scrollView))
    }

    @Test("a formatted document is found in too, by its text")
    func richText() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let document = NSAttributedString(
            string: "Quarterly Report\nThe report is due.\n",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 18)]
        )
        let data = try document.data(
            from: NSRange(location: 0, length: document.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let url = tree.root.appendingPathComponent("report.rtf")
        try data.write(to: url)
        let preview = try await QuickViewTableFixtures.loaded(url)
        let surface = try #require(preview.textSurface)
        #expect(preview.filterableSurface === surface)
        try await Typing.type("report", into: surface)
        #expect(surface.find.matches?.count == 2)
        #expect(Fixtures.highlights(surface).count == 2)
        // A document is drawn with adaptive color mapping in Dark Mode, which turned a plain black match
        // text white on the yellow (found live). A named color is left alone.
        let start = try #require(surface.find.matches?.ranges.first?.lowerBound)
        let text = surface.textView.textStorage?.attribute(
            .foregroundColor,
            at: start,
            effectiveRange: nil
        )
        #expect((text as? NSColor)?.type == .catalog)
    }

    /// Found live: the first version highlighted with TextKit 2 rendering attributes, which
    /// `NSTextView` stores and never draws, so every assertion reading them back passed over a preview
    /// with no highlight on it. The colors now go into the storage, and what has to hold is that they
    /// come off again exactly — a syntax color, a match across two of them, and a document's own
    /// background included.
    @Test("clearing puts back the colors each match had, across syntax colors and a background")
    func restoresOriginalColors() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let source = "let alpha = \"let\"\n"
        let preview = try await QuickViewTableFixtures.loaded(
            try tree.write("sample.swift", contents: source)
        )
        let surface = try #require(preview.textSurface)
        let storage = try #require(surface.textView.textStorage)
        storage.addAttribute(
            .backgroundColor,
            value: NSColor.systemTeal,
            range: NSRange(location: 4, length: 5)
        )
        let before = NSAttributedString(attributedString: storage)

        try await Typing.type("let", into: surface)
        #expect(surface.find.matches?.count == 2)
        try await Typing.type("a = \"l", into: surface)
        #expect(surface.find.matches?.count == 1)
        #expect(!Fixtures.highlights(surface).isEmpty)
        try await Typing.type("", into: surface)
        #expect(storage.isEqual(to: before))
    }

    /// A document TextKit 2 cannot lay out falls back to TextKit 1 by itself — an RTF with a table
    /// does. Reading `layoutManager` is the same fallback on demand.
    @Test("under TextKit 1 the matches are found and highlighted the same way")
    func textKitOneFallback() async throws {
        let fixture = try await Fixtures.text(Self.sample)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        _ = try #require(surface.textView.layoutManager)
        #expect(surface.textView.textLayoutManager == nil)
        try await Typing.type("beta", into: surface)
        let starts = try #require(surface.find.matches).ranges.map(\.lowerBound)
        let marks = Fixtures.highlights(surface)
        #expect(marks[starts[0]] == .systemOrange)
        #expect(marks[starts[2]] == .findHighlightColor)
        try await Typing.type("", into: surface)
        #expect(Fixtures.highlights(surface).isEmpty)
    }
}

/// A text preview in a window, and what the find suite reads off it.
@MainActor
enum QuickViewTextFindFixtures {
    struct Fixture {
        let preview: QuickViewPreviewView
        let surface: QuickViewTextView
        let tree: TempDirectory

        func cleanup() {
            tree.cleanup()
        }
    }

    static func text(_ contents: String, function: String = #function) async throws -> Fixture {
        let tree = try TempDirectory()
        let preview = try await QuickViewTableFixtures.loaded(
            try tree.write("notes.txt", contents: contents),
            function: function
        )
        return Fixture(preview: preview, surface: try #require(preview.textSurface), tree: tree)
    }

    /// Each highlighted run's start and background color, read back from the text storage: the find
    /// yellow or the current match's orange, and nothing else a file carries.
    static func highlights(_ surface: QuickViewTextView) -> [Int: NSColor] {
        guard let storage = surface.textView.textStorage else { return [:] }
        var found: [Int: NSColor] = [:]
        let whole = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.backgroundColor, in: whole) { value, range, _ in
            guard let color = value as? NSColor,
                  color == .findHighlightColor || color == .systemOrange
            else { return }
            found[range.location] = color
        }
        return found
    }

    /// Wait until `condition` holds, polling with `Task.sleep` (docs/NOTES.md ▸ Testing); `false` if it
    /// has not within the budget.
    static func settle(within seconds: Double = 10, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Where a range is drawn, in the text view's coordinates.
    static func frame(of range: Range<Int>, in surface: QuickViewTextView) -> CGRect? {
        guard let layoutManager = surface.textView.textLayoutManager,
              let storage = surface.textView.textContentStorage,
              let lower = storage.location(
                  storage.documentRange.location,
                  offsetBy: range.lowerBound
              ),
              let upper = storage.location(lower, offsetBy: range.count),
              let textRange = NSTextRange(location: lower, end: upper)
        else { return nil }
        var frame: CGRect?
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segment, _, _ in
            frame = frame.map { $0.union(segment) } ?? segment
            return true
        }
        let origin = surface.textView.textContainerOrigin
        return frame?.offsetBy(dx: origin.x, dy: origin.y)
    }
}
