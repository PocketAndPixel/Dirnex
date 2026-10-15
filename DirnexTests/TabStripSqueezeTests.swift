import AppKit
import Testing

@testable import Dirnex

/// A tab strip laid out across a window of its own, pinned edge to edge the way a pane holds it.
@MainActor
struct TabStripFixture {
    let bar: TabBarView
    let window: NSWindow

    static let titles = [
        "Downloads", "Documents", "Applications", "dirnex-tab-moves", "Library",
        "Desktop", "Pictures", "Movies", "Projects"
    ]

    static func folders(_ titles: [String]) -> [TabBarView.Item] {
        titles.map { TabBarView.Item(title: $0, symbolName: "folder") }
    }

    init(_ items: [TabBarView.Item], width: CGFloat, active: Int = 0) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 40),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        RetainedWindows.all.append(window)
        let content = NSView()
        window.contentView = content
        bar = TabBarView()
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: content.topAnchor)
        ])
        bar.setTabs(items, activeIndex: active)
        window.layoutIfNeeded()
    }

    /// Show `active` as a pane does after a switch: the whole strip rebuilt.
    func show(_ items: [TabBarView.Item], active: Int) {
        bar.setTabs(items, activeIndex: active)
        window.layoutIfNeeded()
    }

    /// Each chip's frame in the bar's coordinates.
    func frame(of chip: TabChipView) -> NSRect {
        chip.convert(chip.bounds, to: bar)
    }

    /// Every chip on the strip shows at least the readable floor of its label, or the whole label
    /// when that is shorter.
    func expectReadableLabels(sourceLocation: SourceLocation = #_sourceLocation) {
        let whole = Self(
            bar.chips.map { TabBarView.Item(title: $0.title, symbolName: $0.symbolName) },
            width: 3000
        )
        for chip in bar.chips[bar.visibleRange] {
            let floor = min(
                whole.bar.chips[chip.index].labelFrame.width,
                TabChipView.minimumLabelWidth
            )
            #expect(
                chip.labelFrame.width >= floor - 0.5,
                "\(chip.title): \(chip.labelFrame.width) under \(floor)",
                sourceLocation: sourceLocation
            )
        }
    }
}

/// A strip with more chips than fit at their own widths shrinks them fairly: the widest come down to
/// one shared width, and a chip already narrower than that keeps its whole label.
///
/// Before the shared cap, every label resisted compression at the same priority and Auto Layout put
/// the whole shortfall wherever it liked. Nine chips in 600 pt came out as two whole labels and seven
/// collapsed to 4 pt, which is a label too narrow to draw even its ellipsis. The widths here all fit
/// every chip at its narrowest; past that, tabs go to the overflow menu (`TabStripOverflowTests`).
@MainActor
@Suite("An overfull tab strip shrinks its chips fairly", .serialized)
struct TabStripSqueezeTests {
    /// Wider than any strip of these chips needs, so each chip is drawn at its own width.
    private static let roomy: CGFloat = 3000

    /// The rule: every chip is drawn at its own width or at one cap shared by all, whichever is less,
    /// and the cap is the widest chip drawn. The old squeeze broke it with chips below the cap that
    /// wanted more, while it also fitted the strip in.
    private func expectFairShare(_ items: [TabBarView.Item], width: CGFloat) {
        let natural = TabStripFixture(items, width: Self.roomy).bar.chips.map(\.frame.width)
        let bar = TabStripFixture(items, width: width).bar
        #expect(bar.visibleRange == bar.chips.indices, "a tab went to the overflow menu")
        let drawn = bar.chips.map(\.frame.width)
        #expect(abs(bar.frame.width - width) < 0.5, "the strip widened its window")
        let cap = drawn.max() ?? 0
        for (index, chip) in bar.chips.enumerated() {
            let fair = min(natural[index], cap)
            #expect(
                abs(drawn[index] - fair) <= 1,
                "\(chip.title): \(drawn[index]) where \(fair) is fair"
            )
        }
    }

    @Test("nine chips in a strip too narrow for their own widths come down to one width")
    func evenSqueeze() {
        let items = TabStripFixture.folders(TabStripFixture.titles)
        expectFairShare(items, width: 900)
        // Every label keeps the readable floor or its whole self, where the old squeeze left seven at 4 pt.
        TabStripFixture(items, width: 900).expectReadableLabels()
    }

    @Test("a chip narrower than the shared width keeps its whole label")
    func shortTitleKeepsItsLabel() {
        let items = [
            TabBarView.Item(title: "x", symbolName: "externaldrive"),
            TabBarView.Item(title: "tmp", symbolName: "trash")
        ] + TabStripFixture.folders(Array(TabStripFixture.titles.prefix(7)))
        expectFairShare(items, width: 900)

        let natural = TabStripFixture(items, width: Self.roomy).bar.chips[0].frame.width
        let squeezed = TabStripFixture(items, width: 900).bar.chips
        #expect(abs(squeezed[0].frame.width - natural) <= 1)
        #expect(squeezed[0].frame.width < squeezed[3].frame.width - 5)
    }

    @Test("a strip with room draws every chip at its own width")
    func roomyStripIsUntouched() {
        let items = TabStripFixture.folders(Array(TabStripFixture.titles.prefix(3)))
        expectFairShare(items, width: 480)
        let widths = Set(
            TabStripFixture(items, width: 480).bar.chips.map { Int($0.frame.width.rounded()) }
        )
        #expect(widths.count == 3, "\(widths)")
    }

    @Test("a drop on a squeezed strip still lands in the gap beside the chip under the pointer")
    func dropSlotsFollowTheSqueeze() {
        let strip = TabStripFixture(TabStripFixture.folders(TabStripFixture.titles), width: 900)
        for (index, chip) in strip.bar.chips.enumerated() {
            let frame = strip.frame(of: chip)
            #expect(strip.bar.dropSlot(atX: frame.minX + 2) == index, "\(chip.title)")
            #expect(strip.bar.dropSlot(atX: frame.maxX - 2) == index + 1, "\(chip.title)")
        }
    }
}

extension TabBarView {
    /// The slot a tab dragged from this strip and held over it at `x` would drop into.
    func dropSlot(atX x: CGFloat) -> Int {
        let board = NSPasteboard(name: NSPasteboard.Name("com.dirnex.tests.tab-strip-drag"))
        board.clearContents()
        board.setString("0", forType: Self.tabDragType)
        let location = convert(NSPoint(x: x, y: bounds.midY), to: nil)
        return dropSlot(for: TabDraggingInfo(board: board, source: self, location: location))
    }
}
