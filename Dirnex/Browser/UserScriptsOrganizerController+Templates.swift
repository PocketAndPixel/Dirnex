import AppKit
import DirnexCore

// The **+** menu of the scripts organizer: a blank script, or one of `DirnexCore`'s ready-made
// templates. Split out of `UserScriptsOrganizerController.swift` so that file stays under
// SwiftLint's `file_length` ceiling (docs/NOTES.md file-splitting).
//
// The button opens a menu rather than adding on click because there is now more than one thing to
// add — the same reason Xcode's and System Settings' **+** buttons do. A template is a *seed*: it
// saves an ordinary, fully editable `UserScript` and is then forgotten, so nothing here has to
// answer for the script afterwards.

extension UserScriptsOrganizerController {
    /// Pop the add menu under the **+** button.
    ///
    /// Anchored at the button's bottom-left corner, so the menu drops away from the list rather than
    /// over the row the user is about to compare against.
    @objc func showAddMenu(_ sender: Any?) {
        let menu = NSMenu()
        let blank = NSMenuItem(
            title: String(
                localized: "Blank Script",
                comment: "Scripts organizer + menu: create an empty script rather than one from a template."
            ),
            action: #selector(addBlankScript(_:)),
            keyEquivalent: ""
        )
        blank.target = self
        menu.addItem(blank)
        menu.addItem(.separator())
        for template in UserScriptTemplate.all {
            let item = NSMenuItem(
                title: LocalizedCatalog.title(for: template),
                action: #selector(addTemplate(_:)),
                keyEquivalent: ""
            )
            item.target = self
            // The template rides on the item rather than an index: the menu is rebuilt on every
            // click, and an index would be one reorder of `UserScriptTemplate.all` away from
            // seeding the wrong script.
            item.representedObject = template
            menu.addItem(item)
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: addButton.bounds.maxY),
            in: addButton
        )
    }

    /// Seed the picked template: a real script, named and keyworded in the user's language, saved
    /// through the same path as a blank one (so a second copy lands as "Copy Paths 2" rather than
    /// silently replacing the first).
    @objc func addTemplate(_ sender: Any?) {
        guard let template = (sender as? NSMenuItem)?.representedObject as? UserScriptTemplate else {
            return
        }
        insert(LocalizedCatalog.script(for: template), renaming: false)
    }
}
