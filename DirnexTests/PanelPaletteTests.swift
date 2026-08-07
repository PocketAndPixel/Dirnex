import AppKit
import Foundation
import Testing

@testable import Dirnex

/// The palette the user owns (PLAN.md §M15 Slice 2). Presentation, so it is tested here rather than
/// in `DirnexCore`, the way `SyncBadgeTests` and `RowDensityTests` already are.
///
/// The claims worth pinning are the two the feature can fail *quietly* at: that leaving the
/// preference alone reproduces the shipped `NSColor`s exactly, and that no colour the picker can
/// produce yields an unreadable cursor row.
@Suite("Panel palette")
@MainActor
struct PanelPaletteTests {
    // MARK: - Follow System

    /// The whole bargain of the slice: an untouched install must resolve to the very colours the
    /// app named before `PanelPalette` existed — not to a copy of them, and not to a derivation.
    @Test("following the system hands back the system's own colours, identically")
    func followSystemIsTheShippedRendering() {
        let palette = PanelPalette.followSystem
        #expect(palette.isFollowingSystem)
        #expect(palette.resolvedAccent == .controlAccentColor)
        #expect(palette.resolvedMark == .systemRed)
        // `nil`, not "today's blue": `PanelRowView` reads this as "let AppKit draw its own".
        #expect(palette.cursor == nil)
        #expect(palette.cursorForeground == .alternateSelectedControlTextColor)
        #expect(palette.accentForeground == .alternateSelectedControlTextColor)
    }

    /// A palette with one colour set must leave the other two alone — the shape a per-role
    /// copy-paste in the settings rows would break.
    @Test("each colour is independent of the other two")
    func rolesDoNotBleed() {
        let marked = PanelPalette(mark: .systemGreen)
        #expect(marked.resolvedMark == .systemGreen)
        #expect(marked.resolvedAccent == .controlAccentColor)
        #expect(marked.cursor == nil)
        #expect(!marked.isFollowingSystem)

        let accented = PanelPalette(accent: .systemPurple)
        #expect(accented.resolvedAccent == .systemPurple)
        #expect(accented.resolvedMark == .systemRed)
    }

    // MARK: - The derived foreground

    /// The failure this exists to prevent: a pale cursor colour with white text on it. Whatever the
    /// user picks, the derived foreground must clear 3:1 — the floor macOS's own white-on-accent
    /// (4.02:1) sits above.
    @Test("no colour yields an unreadable cursor row")
    func derivedForegroundAlwaysClearsTheFloor() {
        // A sweep of the whole RGB cube at a coarse step, plus the system colours a user is most
        // likely to reach for from the picker's own swatches.
        var backgrounds: [NSColor] = []
        for red in stride(from: 0.0, through: 1.0, by: 0.1) {
            for green in stride(from: 0.0, through: 1.0, by: 0.1) {
                for blue in stride(from: 0.0, through: 1.0, by: 0.1) {
                    backgrounds.append(NSColor(srgbRed: red, green: green, blue: blue, alpha: 1))
                }
            }
        }
        backgrounds += [
            .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemMint, .systemTeal,
            .systemCyan, .systemBlue, .systemIndigo, .systemPurple, .systemPink, .systemBrown,
            .systemGray, .black, .white
        ]

        for background in backgrounds {
            let palette = PanelPalette(cursor: background)
            let ratio = PanelPalette.contrastRatio(
                between: palette.cursorForeground, and: background
            )
            #expect(
                ratio >= 3,
                "\(PanelPalette.hex(from: background) ?? "?") scores only \(ratio)"
            )
        }
    }

    /// The measurement that set the rule, pinned so a later "just use maximum contrast" tidy-up
    /// fails loudly instead of flipping the app's most familiar surface to black text.
    ///
    /// `.controlAccentColor` is the case where the two rules disagree: white scores 4.02 and black
    /// 5.23, so maximum contrast picks black — while macOS, and Dirnex's own active tab chip, draw
    /// white. The 3:1 rule keeps white here and still hands back black on a yellow.
    @Test("white wins on the system blue, where maximum contrast would have picked black")
    func theRuleMatchesTheSystemWhereItMatters() {
        let systemBlue = NSColor(srgbRed: 0, green: 0.4784, blue: 1, alpha: 1)
        let onWhite = PanelPalette.contrastRatio(between: .white, and: systemBlue)
        let onBlack = PanelPalette.contrastRatio(between: .black, and: systemBlue)
        // The disagreement itself — if this stops holding, the rationale below has changed too.
        #expect(onBlack > onWhite)
        #expect(onWhite >= 3)
        #expect(PanelPalette.foreground(on: systemBlue) == .white)

        // …and it still yields black where white would genuinely be unreadable.
        #expect(PanelPalette.foreground(on: .systemYellow) == .black)
        #expect(PanelPalette.foreground(on: .white) == .black)
        #expect(PanelPalette.foreground(on: .black) == .white)
    }

    /// Whenever black is chosen the background is light enough that black wins comfortably, so the
    /// rule never trades legibility for familiarity — it only breaks the tie where both are legible.
    @Test("choosing black is never a close call")
    func blackIsOnlyChosenWithRoomToSpare() {
        for value in stride(from: 0.0, through: 1.0, by: 0.02) {
            let grey = NSColor(srgbRed: value, green: value, blue: value, alpha: 1)
            guard PanelPalette.foreground(on: grey) == .black else { continue }
            #expect(PanelPalette.contrastRatio(between: .black, and: grey) >= 7)
        }
    }

    /// "Legible in both appearances" is a claim the derivation has to make *by construction*, since
    /// only one appearance can be on screen at a time: the cursor colour is the user's own and the
    /// rule is a luminance test over its sRGB components, so neither half can vary with the
    /// appearance. Pinned rather than argued — a foreground that drifted would be readable in the
    /// mode it was checked in and unreadable in the other, which no single screenshot can catch.
    @Test("the derived foreground is the same in light and dark")
    func derivationIsAppearanceIndependent() {
        let cursors = [
            NSColor(srgbRed: 1, green: 0.839, blue: 0.039, alpha: 1),
            NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1),
            NSColor(srgbRed: 0.039, green: 0.518, blue: 1, alpha: 1),
            NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        ]
        for cursor in cursors {
            var resolved: [NSColor] = []
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                    resolved.append(PanelPalette(cursor: cursor).cursorForeground)
                }
            }
            #expect(resolved.count == 2)
            #expect(resolved.first == resolved.last)
        }
    }

    @Test("relative luminance matches the WCAG anchors")
    func luminanceAnchors() {
        #expect(abs(PanelPalette.relativeLuminance(of: .white) - 1) < 0.0001)
        #expect(abs(PanelPalette.relativeLuminance(of: .black)) < 0.0001)
        // Contrast is symmetric and spans the full 1…21.
        let extremes = PanelPalette.contrastRatio(between: .white, and: .black)
        #expect(abs(extremes - 21) < 0.0001)
        #expect(PanelPalette.contrastRatio(between: .black, and: .white) == extremes)
        #expect(PanelPalette.contrastRatio(between: .systemRed, and: .systemRed) == 1)
    }

    // MARK: - Persistence

    @Test("a colour round-trips through its hex form")
    func hexRoundTrips() throws {
        for hex in ["#000000", "#FFFFFF", "#007AFF", "#1A2B3C", "#FF383C"] {
            let color = try #require(PanelPalette.color(fromHex: hex))
            #expect(PanelPalette.hex(from: color) == hex)
        }
        // Tolerant on the way in: no `#`, lower case.
        #expect(PanelPalette.color(fromHex: "007aff") == PanelPalette.color(fromHex: "#007AFF"))
        #expect(PanelPalette.color(fromHex: " #007AFF ") == PanelPalette.color(fromHex: "#007AFF"))
    }

    /// Anything unparseable must read as Follow System rather than as a colour nobody chose — the
    /// same tolerance `AppPreferences` gives `rowDensity`. The `+`/`-` cases are the ones a plain
    /// `UInt32(_:radix:)` accepts, which is why the digit check is not redundant.
    @Test("a value this build can't parse falls back to Follow System")
    func unparseableFallsBack() {
        let junkValues = [
            "", "  ", "#", "fff", "#GGGGGG", "#12345", "#1234567",
            "+FF000", "-FF000", "rgb(1,2,3)", "#00 7AFF"
        ]
        for junk in junkValues {
            #expect(PanelPalette.color(fromHex: junk) == nil, "\(junk) parsed as a colour")
        }
    }

    @Test("the preferences default to Follow System and round-trip through UserDefaults")
    func preferenceRoundTrips() throws {
        let suiteName = "PanelPaletteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AppPreferences(defaults: defaults).palette.isFollowingSystem)

        let preferences = AppPreferences(defaults: defaults)
        preferences.cursorColorHex = "#1A2B3C"
        preferences.markColorHex = "#00FF00"

        let reloaded = AppPreferences(defaults: defaults)
        #expect(reloaded.palette.cursor == PanelPalette.color(fromHex: "#1A2B3C"))
        #expect(reloaded.palette.resolvedMark == PanelPalette.color(fromHex: "#00FF00"))
        // Untouched, the third one is still the system's.
        #expect(reloaded.palette.accent == nil)

        // A hand-edited or newer-build value degrades rather than trapping.
        defaults.set("chartreuse", forKey: "Dirnex.pref.accentColorHex")
        #expect(AppPreferences(defaults: defaults).palette.accent == nil)
    }

    @Test("changing a colour posts the notification open panes restyle on")
    func changePostsNotification() throws {
        let suiteName = "PanelPaletteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: AppPreferences.paletteDidChange,
            object: preferences,
            queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        preferences.accentColorHex = "#FF0000"
        #expect(posts == 1)
        // Re-assigning the same value must not churn every open pane.
        preferences.accentColorHex = "#FF0000"
        #expect(posts == 1)
        preferences.markColorHex = "#00FF00"
        #expect(posts == 2)
    }

    /// The reset is one gesture, so it must be one repaint however many colours it clears — three
    /// notifications would drive three full re-renders of every open pane.
    @Test("resetting all three posts exactly once, and is inert when nothing is custom")
    func resetPostsOnce() throws {
        let suiteName = "PanelPaletteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        preferences.accentColorHex = "#FF0000"
        preferences.cursorColorHex = "#00FF00"
        preferences.markColorHex = "#0000FF"

        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: AppPreferences.paletteDidChange,
            object: preferences,
            queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        preferences.resetPalette()
        #expect(posts == 1)
        #expect(preferences.palette.isFollowingSystem)
        // And it reaches the store, not just the published properties.
        #expect(AppPreferences(defaults: defaults).palette.isFollowingSystem)

        preferences.resetPalette()
        #expect(posts == 1)
    }

    // MARK: - The drawing sites

    /// A cell built before the user picked anything must still draw the shipped colours — the
    /// recycled-cell case, the same one `RowDensityTests` pins for the icon box.
    @Test("a cell carries the palette it was last rendered with, not the one it was built at")
    func cellFollowsThePalette() throws {
        let cell = FileCellView(showsImage: true, identifier: NSUserInterfaceItemIdentifier("name"))
        cell.marked = true
        cell.applyStyle()
        #expect(cell.textField?.textColor == .systemRed)

        cell.palette = PanelPalette(mark: .systemGreen)
        cell.applyStyle()
        #expect(cell.textField?.textColor == .systemGreen)

        // A Git status leaves the mark's colour alone — the letter is a badge of its own now
        // (`GitBadgeView`), where it used to be a cell whose colour outranked everything.
        cell.gitStatus = .modified
        cell.applyStyle()
        #expect(cell.textField?.textColor == .systemGreen)
    }

    /// The one badge with a legibility stake in the cursor's colour: the dots and the cloud are
    /// shapes read by colour, while a small orange character on a colour the user picked can simply
    /// disappear. So the letter takes the same derived foreground the name does — which is what the
    /// status *gutter* did too, being an ordinary cell whose emphasized branch outranked its colour.
    @Test("the Git letter takes the cursor row's derived foreground")
    func gitBadgeFollowsTheCursorColour() throws {
        let cell = FileCellView(showsImage: true, identifier: NSUserInterfaceItemIdentifier("name"))
        cell.gitStatus = .modified
        let badge = try #require(cell.gitBadge)
        #expect(!badge.isEmphasized)

        cell.palette = PanelPalette(cursor: .systemYellow)
        cell.backgroundStyle = .emphasized
        #expect(badge.isEmphasized)
        #expect(badge.emphasizedInk == cell.palette.cursorForeground)
        // A pale cursor derives black, which is the case the derivation exists for — an orange `M`
        // on yellow is the version that reads as a bug.
        #expect(badge.emphasizedInk == .black)
    }

    /// The cursor row's own text: derived when custom, the system's colour when not — and the
    /// derivation has to happen for a *pale* cursor or the name goes white-on-white.
    @Test("the cursor row's text is derived from the cursor colour")
    func cursorRowTextFollowsTheCursorColour() {
        let cell = FileCellView(showsImage: true, identifier: NSUserInterfaceItemIdentifier("name"))
        cell.backgroundStyle = .emphasized
        #expect(cell.textField?.textColor == .alternateSelectedControlTextColor)

        cell.palette = PanelPalette(cursor: .systemYellow)
        cell.applyStyle()
        #expect(cell.textField?.textColor == .black)

        cell.palette = PanelPalette(cursor: NSColor(srgbRed: 0.1, green: 0, blue: 0.4, alpha: 1))
        cell.applyStyle()
        #expect(cell.textField?.textColor == .white)
    }

    /// The row view is installed for every row, so the untouched path has to be `super`'s drawing —
    /// which it is exactly when there is no colour to draw instead.
    @Test("a row view with no cursor colour has nothing of its own to draw")
    func rowViewDefersWhenFollowingSystem() {
        let row = PanelRowView()
        #expect(row.cursorColor == nil)

        row.cursorColor = .systemTeal
        #expect(row.cursorColor == .systemTeal)
    }

    /// The size bar is the other fill that has to survive the cursor's background, and it defaults
    /// to the same system colour the text does.
    @Test("the size bar's emphasized ink defaults to the system's and takes a derived colour")
    func sizeBarInkFollowsTheCursorColour() {
        let bar = SizeBarView()
        #expect(bar.emphasizedInk == .alternateSelectedControlTextColor)

        bar.emphasizedInk = PanelPalette(cursor: .systemYellow).cursorForeground
        #expect(bar.emphasizedInk == .black)
    }
}
