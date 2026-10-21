import AppKit

// Programmatic entry point — no storyboard, no MainMenu.xib.
// Dirnex is keyboard-first and its UI is built in code (AppKit panels with
// SwiftUI chrome), so we own the app lifecycle explicitly from here.

// Opt this app out of macOS 26 (Tahoe)'s floating "Liquid Glass" sidebar, which renders
// the source list as an inset rounded card detached from the window edges. Dirnex wants
// the classic full-height sidebar flush to the window (traffic lights floating over it),
// so we disable the floating appearance. AppKit reads this appearance default through the
// standard preferences search list. It is registered here, before any window is built, and
// written into the app's own domain below on a real launch; both scope the opt-out to Dirnex
// without touching the global `-g` domain.
UserDefaults.standard.register(
    defaults: ["NSSplitViewItemSidebarDefaultsToFloatingAppearance": false]
)

// Let Tab reach a dialog's popups, checkboxes and buttons even with the system's Keyboard
// navigation switch off — before any window is built, so the first dialog's key view loop has them.
KeyboardReachableControls.install()
// A clearer edge on every bezeled text field, the system's own faint border drawn again stronger.
FieldBorder.install()

let application = NSApplication.shared
// ⌘1–⌘9 pick a dialog's tabs, and holding ⌘ shows the numbers.
TabShortcuts.install()
// A value its column cuts short floats whole: on hover, and for the cursor row while ⌘ is held.
HoverExpansion.install()
CursorNamePeek.install()
// XCTest uses this app as its host, with the user's real defaults domain. Keep the AppKit
// setup above, but do not start the normal lifecycle: it restores tabs, records visits and
// saves window geometry before a test even runs. Tests build the controllers they need.
let delegate = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    ? AppDelegate() : nil

if let delegate {
    // The sidebar opt-out's write (top of the file). Not under XCTest, where it would add a key
    // to a domain the run must leave unchanged.
    UserDefaults.standard.set(false, forKey: "NSSplitViewItemSidebarDefaultsToFloatingAppearance")
    application.delegate = delegate
}

application.run()
