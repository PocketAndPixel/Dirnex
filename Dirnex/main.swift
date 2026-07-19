import AppKit

// Programmatic entry point — no storyboard, no MainMenu.xib.
// Dirnex is keyboard-first and its UI is built in code (AppKit panels with
// SwiftUI chrome), so we own the app lifecycle explicitly from here.

// Opt this app out of macOS 26 (Tahoe)'s floating "Liquid Glass" sidebar, which renders
// the source list as an inset rounded card detached from the window edges. Dirnex wants
// the classic full-height sidebar flush to the window (traffic lights floating over it),
// so we disable the floating appearance. AppKit reads this appearance default through the
// standard preferences search list, so writing it into the app's own domain — before any
// window is built — scopes the opt-out to Dirnex without touching the global `-g` domain.
UserDefaults.standard.register(
    defaults: ["NSSplitViewItemSidebarDefaultsToFloatingAppearance": false]
)
UserDefaults.standard.set(false, forKey: "NSSplitViewItemSidebarDefaultsToFloatingAppearance")

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
