import AppKit

/// How hard each piece of the Quick View header holds its width, so that all of them give way
/// before the panes' divider moves (2026-11-20).
///
/// The split holds each pane's width at 250, and the layout engine never trades a little of a higher
/// priority for a lot of a lower one: a pane held by four constraints at 250 was still pushed out by
/// one at 470. So anything in a pane that wants room above 250 moves the divider. A surface stays in
/// its pane, hidden, after Quick View closes, so whatever it wanted it went on holding: a rendered
/// page's "1 Source · 2 Page (no JavaScript)" at 750 held a pane at 405 pt with the mode closed.
///
/// Every piece that can give way is below 250, and they give way in the order of their priorities,
/// the lowest wholly first. The readout of a playing movie and the position stay above, since a
/// clipped clock or count says nothing (PLAN.md §M42 ▸ Slice 2); both are short.
enum QuickViewHeaderPriority {
    /// A movie's facts go first: they stay whole in their tooltip.
    static let facts = NSLayoutConstraint.Priority(245)
    /// "(no JavaScript)" goes first beside a page: a note about it, and nothing a key selects.
    static let noJavaScriptMark = NSLayoutConstraint.Priority(245)
    /// Then a movie's sound (PLAN.md §M42 ▸ Sound tracks): its menu names it whole.
    static let sound = NSLayoutConstraint.Priority(245.5)
    /// Then the name.
    static let name = NSLayoutConstraint.Priority(246)
    /// The two styles last: the only place the `1` and `2` keys say what they do.
    static let styles = NSLayoutConstraint.Priority(247)
    /// The stack the styles sit in, just above them, so a style shortens before the stack clips it
    /// (docs/NOTES.md ▸ Views, layout and hit testing).
    static let strip = NSLayoutConstraint.Priority(248)
}
