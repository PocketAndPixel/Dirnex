import AppKit

/// The three colours a Dirnex user owns (PLAN.md §M15 Slice 2), resolved against the system's own
/// for whichever ones they have left alone.
///
/// Pure presentation, so it lives in the app rather than in `DirnexCore` — the core picks the state,
/// the app picks the pixels. `nil` means **Follow System** everywhere, and the resolved accessors
/// below are the one place that decides what "the system's own" is, so an untouched install draws
/// through the identical `NSColor`s it did before this type existed.
///
/// Deliberately three and no more. Finder tag dots have to match Finder's own colours, and the Git
/// status letters and sync badges are *information* rather than decoration — recolouring them would
/// be letting the user rename the alphabet.
struct PanelPalette: Equatable {
    /// Overrides `.controlAccentColor` at the path bar's current crumb, the active tab chip and the
    /// titlebar update indicator. Framed in Settings as an override rather than as a setting of its
    /// own, because macOS already ships this control (System Settings ▸ Appearance ▸ Accent) and
    /// `.controlAccentColor` already follows it.
    var accent: NSColor?

    /// The cursor row's background, or `nil` to leave the drawing to AppKit.
    ///
    /// `nil` is **not** the same as naming today's blue, which is why this stays optional rather
    /// than resolving like the other two: measured in both appearances, AppKit's emphasized
    /// selection is `.selectedContentBackgroundColor` — `#0064E1` in light, `#0059D1` in dark —
    /// against the accent's `#007AFF`. It is a *darker relative* of the accent, not the accent, and
    /// the relationship between them is not one to re-derive.
    var cursor: NSColor?

    /// The marked-row text colour — the hardcoded `.systemRed` in `FileCellView` before this
    /// existed. Unlike the selection blue this one was always Dirnex's decision rather than the
    /// system's, which is what makes it the most worthwhile of the three.
    var mark: NSColor?

    /// An untouched install: every colour the system's.
    static let followSystem = PanelPalette()

    /// Whether nothing has been overridden — the state in which every drawing site below hands back
    /// the exact `NSColor` the app used before this type existed.
    var isFollowingSystem: Bool { self == .followSystem }

    var resolvedAccent: NSColor { accent ?? .controlAccentColor }
    var resolvedMark: NSColor { mark ?? .systemRed }

    /// What text and glyphs draw in **on the cursor row**: white or black against a custom colour,
    /// and — untouched — the system's own `.alternateSelectedControlTextColor`, verbatim.
    ///
    /// Falling back to the system colour rather than deriving one for the default case is the whole
    /// reason "Follow System renders byte-identically" is a claim and not an aspiration. It is also
    /// necessary: see `foreground(on:)` for the measurement that shows a derivation would *not*
    /// reproduce what AppKit does on its own blue.
    var cursorForeground: NSColor {
        cursor.map(Self.foreground(on:)) ?? .alternateSelectedControlTextColor
    }

    /// The same, for whatever sits on the accent — the active tab chip's label and its close button.
    var accentForeground: NSColor {
        accent.map(Self.foreground(on:)) ?? .alternateSelectedControlTextColor
    }

    // MARK: - The derived foreground

    /// White or black on `background`, whichever the user can actually read.
    ///
    /// **The rule is "white unless it drops below 3:1", not "whichever contrasts more", and the
    /// difference is not academic.** Measured against the real system colours in both appearances:
    ///
    /// - AppKit's own emphasized selection `#0064E1` has a relative luminance of 0.1455, where white
    ///   scores 5.37:1 and black 3.91:1 — white, and both rules agree.
    /// - `.controlAccentColor` `#007AFF` is L=0.2114, where white scores **4.02:1** and black
    ///   **5.23:1**. Maximum contrast says *black*, while macOS — and Dirnex's own active tab chip,
    ///   which puts `.alternateSelectedControlTextColor` straight onto the accent — draws white. So
    ///   a max-contrast rule would flip the app's most familiar surface to black text the moment a
    ///   user picked a blue barely distinguishable from the one they already had.
    ///
    /// 3:1 is where the two concerns meet. It is the floor the system itself clears with room to
    /// spare, so the blues, reds and greens someone reaches for first keep white; and whenever it
    /// *is* black's turn the background is above L=0.3, where black scores at least 7:1 — so the
    /// rule never trades legibility for familiarity, it only breaks the tie in the band where both
    /// choices are legible.
    ///
    /// Literal white and black rather than a dynamic pair: the contrast was computed against one
    /// specific colour, and a foreground that flipped with the appearance would walk away from it.
    static func foreground(on background: NSColor) -> NSColor {
        contrastRatio(between: .white, and: background) >= 3 ? .white : .black
    }

    /// WCAG 2.1 relative luminance, over sRGB. `0` for a colour that cannot be converted (a pattern
    /// image colour), which is not a case the picker can produce.
    static func relativeLuminance(of color: NSColor) -> Double {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(srgb.redComponent)
            + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
    }

    /// WCAG 2.1 contrast ratio, 1…21. Symmetric, so the argument order carries no meaning.
    static func contrastRatio(between one: NSColor, and other: NSColor) -> Double {
        let first = relativeLuminance(of: one)
        let second = relativeLuminance(of: other)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    // MARK: - Persistence

    /// `#RRGGBB`, sRGB, or `nil` for a colour with no such representation. Hex rather than an
    /// archived `NSColor` because a preference someone may have to inspect or hand-edit should be
    /// readable (PLAN.md §2, "boring and debuggable") — and probed to be lossless: every system
    /// colour the app draws round-trips through eight bits a channel within 1/255.
    static func hex(from color: NSColor) -> String? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(
            format: "#%02X%02X%02X",
            channel(srgb.redComponent),
            channel(srgb.greenComponent),
            channel(srgb.blueComponent)
        )
    }

    /// The inverse, tolerant on the way in and strict about what it accepts: a leading `#` is
    /// optional, case is ignored, and **anything else is `nil`** — which the preference reads as
    /// Follow System. A hand-edited or newer-build value therefore degrades to the shipped default
    /// rather than to a colour nobody chose, the same way `AppPreferences` reads `rowDensity`.
    static func color(fromHex hex: String) -> NSColor? {
        var text = Substring(hex.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("#") { text = text.dropFirst() }
        // `UInt32(_:radix:)` accepts a leading `+`/`-`, so the digit check is not redundant with it.
        guard text.count == 6, text.allSatisfy(\.isHexDigit),
              let value = UInt32(text, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
