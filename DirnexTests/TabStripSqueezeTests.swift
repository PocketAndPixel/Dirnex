import AppKit
import Testing

@testable import Dirnex

/// A strip with more chips than fit shrinks them fairly: the widest come down to one shared width,
/// and a chip already narrower than that keeps its whole label.
///
/// Before the shared cap, every label resisted compression at the same priority and Auto Layout put
/// the whole shortfall wherever it liked. Nine chips in 600 pt came out as two whole labels and seven
/// collapsed to 4 pt, which is a label too narrow to draw even its ellipsis.
@MainActor
@Suite("An overfull tab strip shrinks its chips fairly", .serialized)
struct TabStripSqueezeTests {
    private static let titles = [
        "Downloads", "Documents", "Applications", "dirnex-tab-moves", "Library",
        "Desktop", "Pictures", "Movies", "Projects"
    ]
    /// Wider than any strip of these chips needs, so each chip is drawn at its own width.
    private static let roomy: CGFloat = 3000

    /// A strip of `items` laid out across a window `width` wide, the way a pane holds it.
    private func laidOut(_ items: [TabBarView.Item], width: CGFloat) -> TabBarView {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 40),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        RetainedWindows.all.append(window)
        let content = NSView()
        window.contentView = content
        let bar = TabBarView()
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: content.topAnchor)
        ])
        bar.setTabs(items, activeIndex: 0)
        window.layoutIfNeeded()
        return bar
    }

    private func folders(_ titles: [String]) -> [TabBarView.Item] {
        titles.map { TabBarView.Item(title: $0, symbolName: "folder") }
    }

    /// The rule: every chip is drawn at its own width or at one cap shared by all, whichever is less,
    /// and the cap is the widest chip drawn. The old squeeze broke it with chips below the cap that
    /// wanted more, while it also fitted the strip in.
    private func expectFairShare(_ items: [TabBarView.Item], width: CGFloat) {
        let natural = laidOut(items, width: Self.roomy).chips.map(\.frame.width)
        let bar = laidOut(items, width: width)
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

    @Test("nine chips in a strip too narrow for them all come down to one width")
    func evenSqueeze() {
        expectFairShare(folders(Self.titles), width: 600)
        // Every label keeps a share, where the old squeeze left seven of them at 4 pt.
        for chip in laidOut(folders(Self.titles), width: 600).chips {
            #expect(chip.labelFrame.width >= 12, "\(chip.title): \(chip.labelFrame.width)")
        }
    }

    @Test("a chip narrower than the shared width keeps its whole label")
    func shortTitleKeepsItsLabel() {
        let items = [
            TabBarView.Item(title: "x", symbolName: "externaldrive"),
            TabBarView.Item(title: "tmp", symbolName: "trash")
        ] + folders(Self.titles) + [TabBarView.Item(title: "invoice", symbolName: "magnifyingglass")]
        expectFairShare(items, width: 900)

        let natural = laidOut(items, width: Self.roomy).chips[0].frame.width
        let squeezed = laidOut(items, width: 900).chips
        #expect(abs(squeezed[0].frame.width - natural) <= 1)
        #expect(squeezed[0].frame.width < squeezed[3].frame.width - 5)
    }

    @Test("a strip with room draws every chip at its own width")
    func roomyStripIsUntouched() {
        expectFairShare(folders(Array(Self.titles.prefix(3))), width: 480)
        let chips = laidOut(folders(Array(Self.titles.prefix(3))), width: 480).chips
        let widths = Set(chips.map { Int($0.frame.width.rounded()) })
        #expect(widths.count == 3, "\(widths)")
    }

    @Test("a drop on a squeezed strip still lands in the gap beside the chip under the pointer")
    func dropSlotsFollowTheSqueeze() throws {
        let bar = laidOut(folders(Self.titles), width: 600)
        let board = NSPasteboard(name: NSPasteboard.Name("com.dirnex.tests.tab-squeeze-drag"))
        board.clearContents()
        board.setString("0", forType: TabBarView.tabDragType)
        for (index, chip) in bar.chips.enumerated() {
            let frame = chip.convert(chip.bounds, to: bar)
            for (x, slot) in [(frame.minX + 2, index), (frame.maxX - 2, index + 1)] {
                let location = bar.convert(NSPoint(x: x, y: bar.bounds.midY), to: nil)
                let info = TabDraggingInfo(board: board, source: bar, location: location)
                #expect(bar.dropSlot(for: info) == slot, "\(chip.title) at \(x)")
            }
        }
    }
}
