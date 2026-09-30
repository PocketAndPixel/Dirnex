import AppKit

extension NSTextField {
    /// Keep an entry field to a single, horizontally scrolling line.
    ///
    /// **Every bare AppKit initializer hands back a wrapping cell**, which is the wrong shape for
    /// anything a user types a name or a path into. Measured on macOS 26: `NSTextField()`,
    /// `NSTextField(frame:)` and both `NSSecureTextField` spellings all come back
    /// `wraps = true, isScrollable = false, lineBreakMode = .byWordWrapping`, while only
    /// `NSTextField(string:)` is single-line by construction. So a value longer than the field
    /// wraps onto a **second line the 24 pt field cannot show**: the visible line breaks at the
    /// last word boundary — for a file name, a `-` or a `.` — leaving a gap of empty field to its
    /// right, and the rest of the name is simply not on screen. Probed against the real ⇧F4 sheet
    /// with a 108-character name: field editor 48 pt tall inside a 20 pt clip.
    ///
    /// It fails in the quiet direction, which is why it survived so long in so many dialogs:
    /// nothing logs, every test stays green, the field really does hold the whole value, and any
    /// screenshot taken with a short name is perfect.
    ///
    /// **`cell.wraps` is the property that decides it, and `usesSingleLineMode` alone is not the
    /// fix** — which is the trap, because it is the one that reads like it. Measured with the caret
    /// sent to the end of the same long value: under `usesSingleLineMode` alone the editor stays
    /// 252 pt wide, is not horizontally resizable, and the clip view scrolls *vertically* to the
    /// hidden second line, so the tail stays unreachable; with `wraps = false` the editor is 621 pt
    /// wide and the clip scrolls horizontally to show it. `PathBarView`'s ⌘L field had exactly that
    /// half-fix. Single-line mode is kept anyway for what it *does* do — it keeps a pasted newline
    /// out of a field that stands for one name.
    ///
    /// **`isScrollable` is deliberately not set, because it and `lineBreakMode` clear each other**
    /// — probed: assigning the break mode drops `isScrollable` back to `false`, and assigning
    /// `isScrollable` resets the break mode to `.byClipping`, so whichever is written last wins.
    /// `ConnectServerForm` wrote both and has therefore been running with `isScrollable == false`
    /// since it shipped, which is the measurement that settles the choice: horizontal scrolling
    /// comes from `wraps` alone (editor 621 pt wide, clip scrolled to the tail, `isScrollable`
    /// false throughout), while the truncation is real work — `.byTruncatingHead` is what keeps the
    /// host and share of an unfocused address visible instead of its scheme.
    ///
    /// A cell built with `labelWithString:` already carries `wraps = false`, which is why the F2
    /// inline rename never had the bug (measured: identical scrolling with and without this call).
    func keepToOneLine(truncating: NSLineBreakMode = .byTruncatingTail) {
        usesSingleLineMode = true
        cell?.wraps = false
        cell?.lineBreakMode = truncating
    }

    /// The same thing at a declaration site — a stored property has no statement to call
    /// ``keepToOneLine(truncating:)`` from, and pushing its configuration into `init` puts the two
    /// halves a screen apart. Prefer this wherever the field is a `let` on the type.
    static func singleLine(truncating: NSLineBreakMode = .byTruncatingTail) -> NSTextField {
        let field = NSTextField()
        field.keepToOneLine(truncating: truncating)
        return field
    }
}
