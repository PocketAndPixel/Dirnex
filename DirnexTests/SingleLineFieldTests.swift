import AppKit
import Testing

@testable import Dirnex

/// `NSTextField.keepToOneLine(truncating:)` and the AppKit default it exists for.
///
/// A user reported the ⇧F4 Edit File sheet drawing a long name broken at a hyphen with a gap of
/// empty field beside it: AppKit's bare initializers hand back a **wrapping** cell, so the rest of
/// the name sits on a second line the 24 pt field cannot show. Eleven other dialogs had it at the
/// same time — nothing logs, both suites stay green, the field really does hold the whole value,
/// and every screenshot taken with a short name is perfect.
@Suite("Single-line entry fields")
@MainActor
struct SingleLineFieldTests {
    /// The negative control, and the reason the helper exists at all: a macOS that stopped
    /// defaulting to a wrapping cell would leave every `keepToOneLine()` call vestigial with all
    /// the assertions below still green. Measured on macOS 26.
    @Test("AppKit's bare initializers really do hand back a wrapping cell")
    func bareInitializersWrap() {
        for field in [
            NSTextField(),
            NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)),
            NSSecureTextField(),
            NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        ] {
            #expect(field.cell?.wraps == true)
            #expect(field.cell?.isScrollable == false)
        }
    }

    /// The two spellings that are already correct, so nothing has to call the helper on them —
    /// which is what lets the CI scan exempt them rather than demand a redundant call.
    @Test("the string and label initializers are single-line by construction")
    func stringAndLabelInitializersDoNotWrap() {
        #expect(NSTextField(string: "x").cell?.wraps == false)
        #expect(NSTextField(labelWithString: "x").cell?.wraps == false)
    }

    @Test("keepToOneLine stops the cell wrapping")
    func configuresTheCell() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.keepToOneLine()
        #expect(field.usesSingleLineMode)
        #expect(field.cell?.wraps == false)
        #expect(field.cell?.lineBreakMode == .byTruncatingTail)
    }

    @Test("a secure field takes it too")
    func configuresASecureCell() {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.keepToOneLine()
        #expect(field.cell?.wraps == false)
    }

    /// The break mode is what an *unfocused* field shows, and the path fields ask for
    /// `.byTruncatingHead` so the host and share stay visible rather than the scheme.
    @Test("a requested truncation survives")
    func truncationSurvives() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.keepToOneLine(truncating: .byTruncatingHead)
        #expect(field.cell?.lineBreakMode == .byTruncatingHead)
        #expect(field.cell?.wraps == false)
    }

    /// Why the helper does not set `isScrollable`, pinned so nobody adds it back: it and
    /// `lineBreakMode` clear each other, and the truncation is the half worth keeping — horizontal
    /// scrolling comes from `wraps = false` (measured on a live field editor: 621 pt of text
    /// scrolled to its tail inside a 252 pt clip with `isScrollable == false` throughout).
    @Test("isScrollable and lineBreakMode clear each other, so the break mode wins")
    func scrollableAndBreakModeAreExclusive() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.cell?.isScrollable = true
        field.cell?.lineBreakMode = .byTruncatingTail
        #expect(field.cell?.isScrollable == false)

        let other = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        other.cell?.lineBreakMode = .byTruncatingTail
        other.cell?.isScrollable = true
        #expect(other.cell?.lineBreakMode == .byClipping)

        // The helper's own result: the caller's truncation, not clipping.
        let field3 = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field3.keepToOneLine(truncating: .byTruncatingHead)
        #expect(field3.cell?.lineBreakMode == .byTruncatingHead)
    }

    /// `cell.wraps` is the property that decides whether the value can be reached, and
    /// `usesSingleLineMode` alone — the natural half-fix, and what `PathBarView` shipped — leaves
    /// it `true`. Measured on a live field editor: under that half-fix the editor stays 252 pt
    /// wide and the clip view scrolls *vertically* to the hidden line, so the tail of a long name
    /// is unreachable; with `wraps = false` the editor is 621 pt wide and scrolls horizontally.
    @Test("usesSingleLineMode alone leaves the cell wrapping")
    func singleLineModeAloneIsNotEnough() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.usesSingleLineMode = true
        #expect(field.cell?.wraps == true)
    }
}
