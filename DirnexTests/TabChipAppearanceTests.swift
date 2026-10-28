import AppKit
import Testing

@testable import Dirnex

/// A tab chip's fill and outline are layer properties, so each is a `CGColor` resolved under one
/// appearance. Seen live in light mode: the inactive pane's tab was filled `#464646`, the dark-mode
/// gray, beside a cursor row drawn in the light one (`#DCDCDC`), with black text on it.
@MainActor
@Suite("A tab chip's fill and outline follow the window's appearance", .serialized)
struct TabChipAppearanceTests {
    /// `color` as `appearance` draws it, in sRGBA bytes.
    private static func bytes(of color: NSColor, in appearance: NSAppearance) -> [Int] {
        var resolved: [Int] = []
        appearance.performAsCurrentDrawingAppearance {
            resolved = bytes(of: color.cgColor)
        }
        return resolved
    }

    private static func bytes(of color: CGColor?) -> [Int] {
        guard let color, let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return [] }
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
            .map { Int(($0 * 255).rounded()) }
    }

    /// Draw the strip in `appearance`. Each chip's own `displayIfNeeded`, because in a window that is
    /// never ordered in, `display()` on the window or on any ancestor clears a chip's `needsDisplay`
    /// without updating its layer (probed): the app's update comes from the run loop's display pass.
    private static func draw(_ strip: TabStripFixture, in appearance: NSAppearance) {
        strip.window.appearance = appearance
        for chip in strip.bar.chips {
            chip.displayIfNeeded()
        }
    }

    /// The showing tab's fill after the strip has drawn in `appearance`.
    private static func fill(_ strip: TabStripFixture, in appearance: NSAppearance) -> [Int] {
        draw(strip, in: appearance)
        return bytes(of: strip.bar.chips[0].layer?.backgroundColor)
    }

    @Test("the inactive pane's tab takes the unemphasized gray of each appearance, both ways")
    func inactivePaneTabFollowsAppearance() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        let gray = NSColor.unemphasizedSelectedContentBackgroundColor
        let lightGray = Self.bytes(of: gray, in: light)
        let darkGray = Self.bytes(of: gray, in: dark)
        #expect(lightGray != darkGray, "the two appearances must draw this gray apart to tell")

        let strip = TabStripFixture(TabStripFixture.folders(["one", "two"]), width: 600)
        #expect(!strip.bar.isActivePane)
        #expect(Self.fill(strip, in: dark) == darkGray)
        #expect(Self.fill(strip, in: light) == lightGray)
        #expect(Self.fill(strip, in: dark) == darkGray)
    }

    @Test("a tab that isn't showing stays unfilled in either appearance")
    func otherTabsStayClear() throws {
        let strip = TabStripFixture(TabStripFixture.folders(["one", "two"]), width: 600)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            Self.draw(strip, in: try #require(NSAppearance(named: name)))
            #expect(strip.bar.chips[1].layer?.backgroundColor?.alpha == 0, "\(name)")
        }
    }

    @Test("a tab that isn't showing is outlined in each appearance's separator color, both ways")
    func otherTabsAreOutlined() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        let lightLine = Self.bytes(of: .separatorColor, in: light)
        let darkLine = Self.bytes(of: .separatorColor, in: dark)
        #expect(lightLine != darkLine, "the two appearances must draw the separator apart to tell")

        let strip = TabStripFixture(TabStripFixture.folders(["one", "two"]), width: 600)
        for (appearance, line) in [(dark, darkLine), (light, lightLine), (dark, darkLine)] {
            Self.draw(strip, in: appearance)
            let chip = strip.bar.chips[1]
            #expect(Self.bytes(of: chip.layer?.borderColor) == line, "\(appearance.name)")
            #expect(chip.layer?.borderWidth == 1)
        }
    }

    @Test("the showing tab has no outline, whichever pane is active")
    func showingTabIsNotOutlined() throws {
        let strip = TabStripFixture(TabStripFixture.folders(["one", "two"]), width: 600)
        for isActivePane in [false, true] {
            strip.bar.isActivePane = isActivePane
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                Self.draw(strip, in: try #require(NSAppearance(named: name)))
                let line = strip.bar.chips[0].layer?.borderColor
                #expect(line?.alpha == 0, "\(name), active pane: \(isActivePane)")
            }
        }
    }
}
