import AppKit
import DirnexCore

/// Case Sensitive and Whole Word: the two options Quick View's find and filter bar offers, and the
/// menu they live in (2026-09-18). Split out of `QuickViewTableFilterBar` in the pass that added them,
/// which took the class past SwiftLint's `type_body_length` — by concept rather than by shaving lines,
/// as every other split in this window has been.
///
/// What the options *mean* is `DirnexCore`'s (``DirnexCore/FilterQuery/Options``) and is the same for
/// all five surfaces, which is the whole point of them living on one type: the bar offers them and
/// decides nothing.
extension QuickViewTableFilterBar {
    /// The two toggles, in the search field's own magnifying-glass menu.
    ///
    /// The menu rather than a pair of buttons in the row, because this bar has no width to spare: it
    /// already carries a picker, the text, a count and a close button inside a pane that is 320 pt at
    /// the window's minimum, and every caption in it is one a translation can make half again as long
    /// (docs/NOTES.md ▸ Localization, four entries about exactly this bar's neighbours). The menu costs
    /// nothing at any width and is where macOS puts search options anyway.
    ///
    /// Rebuilt from `options` on every change rather than toggling the item that was clicked:
    /// `NSSearchField` **copies** its template to display it, so the item the action receives is not
    /// necessarily the one held here, and a state written onto the copy would be thrown away. Building
    /// from the stored value cannot drift whichever object the click arrived on.
    func buildOptionsMenu() {
        let menu = NSMenu()
        for (option, title) in Self.optionTitles {
            let item = NSMenuItem(
                title: title,
                action: #selector(optionToggled(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = option.rawValue
            item.state = options.contains(option) ? .on : .off
            menu.addItem(item)
        }
        field.searchMenuTemplate = menu
    }

    /// The titles, in the order the menu lists them. A `static let` so the two are named once and the
    /// loop above cannot fall out of step with the tags it reads back.
    static let optionTitles: [(FilterQuery.Options, String)] = [
        (.caseSensitive, String(
            localized: "Case Sensitive",
            comment: """
            Quick View find and filter: the option that stops “Beta” matching “beta”. A checkable item \
            in the search field's magnifying-glass menu.
            """
        )),
        (.wholeWord, String(
            localized: "Whole Word",
            comment: """
            Quick View find and filter: the option that finds “beta” only where it stands alone, not \
            inside “betaOnly”. A checkable item in the search field's magnifying-glass menu.
            """
        ))
    ]

    @objc fileprivate func optionToggled(_ sender: NSMenuItem) {
        applyOptions(options.symmetricDifference(FilterQuery.Options(rawValue: sender.tag)))
    }

    /// Put the options back to the default — for a bar being set up for a different kind of surface,
    /// where the previous one's choices are not this one's.
    func resetOptions() {
        applyOptions([])
    }
}
