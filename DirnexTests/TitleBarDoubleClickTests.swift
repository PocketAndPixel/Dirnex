import AppKit
import Testing

@testable import Dirnex

/// What the system does on a double-click is its own setting, and these watch for the zoom.
private let systemZoomsOnDoubleClick =
    UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") == "Maximize"

/// A double-click on the free space in the title bar's row acts on the window, as it does in any title
/// bar. What decides that is AppKit's, in the window's frame view, and these drive the real responder
/// chain up to it and watch what it asks the window to do. A real double-click, which the window server
/// delivers, is for a person with a mouse.
@MainActor
@Suite("A double-click on the title bar's free space", .serialized)
struct TitleBarDoubleClickTests {
    /// Counts instead of zooming, which would animate and leave the window another size.
    private final class CountingWindow: NSWindow {
        var zooms = 0
        /// Reported rather than set: a window handed the real style out of the blue takes the app down.
        var inFullScreen = false

        override var styleMask: NSWindow.StyleMask {
            get { inFullScreen ? super.styleMask.union(.fullScreen) : super.styleMask }
            set { super.styleMask = newValue }
        }

        override func performZoom(_ sender: Any?) {
            zooms += 1
        }
    }

    /// A strip in a pane's container, under a transparent title bar, as the browser window holds one.
    @MainActor
    private struct Fixture {
        let window = CountingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let bar = TabBarView()

        init(content: NSView = BrowserContentView()) {
            window.isReleasedWhenClosed = false
            RetainedWindows.all.append(window)
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.contentView = content
            let pane = PanelContainerView()
            pane.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(pane)
            pane.addSubview(bar)
            NSLayoutConstraint.activate([
                pane.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                pane.topAnchor.constraint(equalTo: content.topAnchor),
                pane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                bar.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
                bar.topAnchor.constraint(equalTo: pane.topAnchor)
            ])
            bar.setTabs(TabStripFixture.folders(["Downloads", "Documents"]), activeIndex: 0)
            window.layoutIfNeeded()
        }

        /// A mouse-up on the title bar's row, or `below` it.
        func up(clicks: Int, below: Bool = false) -> NSEvent {
            let y = below ? 100 : window.frame.height - 14
            return NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: NSPoint(x: 600, y: y),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: clicks,
                pressure: 0
            ) ?? NSEvent()
        }
    }

    @Test("zooms the window from the strip's free space", .enabled(if: systemZoomsOnDoubleClick))
    func zooms() {
        let fixture = Fixture()
        fixture.bar.mouseUp(with: fixture.up(clicks: 2))
        #expect(fixture.window.zooms == 1)
    }

    /// The chain stops at the window with a plain content view, which is why the class exists, and this
    /// is what makes the zoom above a measurement of it.
    @Test("goes nowhere with a plain content view", .enabled(if: systemZoomsOnDoubleClick))
    func plainContentViewStopsIt() {
        let fixture = Fixture(content: NSView())
        fixture.bar.mouseUp(with: fixture.up(clicks: 2))
        #expect(fixture.window.zooms == 0)
    }

    @Test("needs exactly two clicks")
    func clickCounts() {
        let fixture = Fixture()
        fixture.bar.mouseUp(with: fixture.up(clicks: 1))
        fixture.bar.mouseUp(with: fixture.up(clicks: 3))
        #expect(fixture.window.zooms == 0)
    }

    @Test("does nothing below the title bar's row")
    func belowTheRow() {
        let fixture = Fixture()
        fixture.bar.mouseUp(with: fixture.up(clicks: 2, below: true))
        #expect(fixture.window.zooms == 0)
    }

    @Test("on a chip is the chip's", .enabled(if: systemZoomsOnDoubleClick))
    func aChipKeepsIt() throws {
        let fixture = Fixture()
        let chip = try #require(fixture.bar.chips.first)
        chip.mouseUp(with: fixture.up(clicks: 2))
        #expect(fixture.window.zooms == 0)
    }

    /// The × of the strip's last chip leaves free space under the pointer, and the next click is the
    /// second of a double-click as far as AppKit can tell.
    @Test(
        "right after a × leaves the window alone, once",
        .enabled(if: systemZoomsOnDoubleClick)
    )
    func aClosedChipIsNotTheFirstClick() throws {
        let fixture = Fixture()
        let chip = try #require(fixture.bar.chips.last)
        fixture.bar.chipDidClose(chip)
        fixture.bar.mouseUp(with: fixture.up(clicks: 2))
        #expect(fixture.window.zooms == 0)

        fixture.bar.mouseUp(with: fixture.up(clicks: 2))
        #expect(fixture.window.zooms == 1)
    }

    /// The first click of a real double-click is what clears the ×'s mark, long after the tab closed.
    @Test(
        "a later double-click zooms, its first click clearing the ×",
        .enabled(if: systemZoomsOnDoubleClick)
    )
    func aLaterDoubleClickZooms() throws {
        let fixture = Fixture()
        let chip = try #require(fixture.bar.chips.last)
        fixture.bar.chipDidClose(chip)
        fixture.bar.mouseUp(with: fixture.up(clicks: 1))
        fixture.bar.mouseUp(with: fixture.up(clicks: 2))
        #expect(fixture.window.zooms == 1)
    }

    /// At full-window size Quick View's surface holds the row, and it keeps every other click for itself.
    @Test("goes through Quick View's surface", .enabled(if: systemZoomsOnDoubleClick))
    func quickViewSurface() {
        let fixture = Fixture()
        let preview = QuickViewPreviewView(
            backingColor: .black,
            header: .none,
            findOptions: QuickViewFindOptionsStore.scratch()
        )
        fixture.window.contentView?.addSubview(preview)
        preview.mouseUp(with: fixture.up(clicks: 1))
        #expect(fixture.window.zooms == 0)
        preview.mouseUp(with: fixture.up(clicks: 2))
        #expect(fixture.window.zooms == 1)
    }

    @Test("does nothing in full screen", .enabled(if: systemZoomsOnDoubleClick))
    func fullScreen() {
        let fixture = Fixture()
        fixture.window.inFullScreen = true
        fixture.bar.mouseUp(with: fixture.up(clicks: 2))
        #expect(fixture.window.zooms == 0)
    }
}
