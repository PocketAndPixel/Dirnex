import AppKit

/// Lets Tab reach a dialog's popups, checkboxes, radio and push buttons, switches, segmented
/// controls, color wells, steppers and tab selectors, whatever System Settings ▸ Keyboard ▸
/// Keyboard navigation says.
///
/// A tab view joins as the system switch would have it: Tab goes from the control before it to the
/// selector and on into the selected tab's first control, the arrows move the highlight and Space
/// selects. Measured live in Get Info and in Settings, whose SwiftUI `TabView` is a real `NSTabView`.
///
/// With that switch off — the macOS default — AppKit keeps every one of those controls out of the
/// key view loop, so Tab walks a form's text fields and skips the Protocol popup between them. The
/// switch is one global preference that an app cannot flip for itself: probed 2026-09-13, setting
/// `AppleKeyboardUIMode = 2` in the app's own domain, the argument domain, a volatile domain and the
/// registration domain left `NSApp.isFullKeyboardAccessEnabled` reading `false` every time. So the
/// opt-in has to be made on the controls.
///
/// **The gate is `canBecomeKeyView`, not `acceptsFirstResponder`.** The same probe read
/// `acceptsFirstResponder == true` on all four control kinds with the switch off, and
/// `canBecomeKeyView == false` — so the controls could always *hold* focus and were only ever being
/// left out of the loop. Answering `canBecomeKeyView` the way the switch would is the whole change:
/// a plain window then tabbed field → checkbox → segmented control → field → button → popup, and an
/// `NSAlert` field → popup → Cancel → Pack.
///
/// **It is installed on the classes rather than on a subclass at each site**, because the controls
/// come from dozens of construction sites and from frameworks — `NSAlert`'s own buttons, and the
/// Settings window's SwiftUI controls, which are private subclasses nobody here constructs. Probed
/// 2026-09-13, none of those overrides `canBecomeKeyView`: a `Toggle` in a `Form` is an `NSSwitch`
/// subclass, a `Picker` an `NSPopUpButton` or `NSSegmentedControl` subclass, a `ColorPicker` an
/// `NSColorWell` subclass and a `Stepper` an `NSStepper` subclass, so patching the AppKit
/// class reaches them. The one exception is SwiftUI's *checkbox*-style `Toggle`, whose button answers
/// `acceptsFirstResponder == false` outright; Dirnex's Settings draws none. `NSPopUpButton` has no
/// override of its own either (adding one to it succeeds), so patching `NSButton` covers it —
/// `KeyboardReachableControlsTests` fails if a later macOS gives either of them one.
///
/// **The browser window is deliberately left out** — any window whose controller is a
/// ``PaneKeyWindowController``. Tab there is a pane key that only fires while a
/// pane holds focus (docs/NOTES.md), so a function-bar button, a path-bar crumb or a titlebar
/// accessory that could take focus would be a place to strand the keyboard with nothing to bring it
/// back. Everything else — sheets, alerts, the movable dialog windows, Settings — is a form, where
/// reaching every control is the point. A user who has turned the system switch on still gets it
/// everywhere, since the original answer is asked first.
enum KeyboardReachableControls {
    /// Install once, before any window is built. Safe to call again; later calls do nothing.
    static func install() {
        _ = installation
    }

    private static let installation: Void = {
        let controlClasses: [AnyClass] = [
            NSButton.self, NSSegmentedControl.self, NSSwitch.self, NSColorWell.self, NSStepper.self,
            NSTabView.self
        ]
        for controlClass in controlClasses {
            ObjCMethodPatch.wrapBool(#selector(getter: NSView.canBecomeKeyView), on: controlClass) { view, original in
                original() || ObjCMethodPatch.onMainActor(view, else: false) { joinsKeyViewLoop($0) }
            }
        }
        // A color well that took focus this way draws no ring, so it is handed one of ours.
        ObjCMethodPatch.wrapBool(#selector(NSResponder.becomeFirstResponder), on: NSColorWell.self) { view, original in
            let accepted = original()
            if accepted {
                ObjCMethodPatch.onMainActor(view, else: ()) { ColorWellFocusRing.attach(to: $0) }
            }
            return accepted
        }
        TabSelectorFocusRing.install()
    }()

    /// Whether `view` joins its window's Tab loop although the system switch is off: it can hold
    /// focus, it is visible and enabled, and its window's Tab is not a pane key.
    @MainActor
    static func joinsKeyViewLoop(_ view: NSView) -> Bool {
        guard let window = view.window,
              !(window.windowController is PaneKeyWindowController),
              view.acceptsFirstResponder,
              !view.isHiddenOrHasHiddenAncestor else { return false }
        return (view as? NSControl)?.isEnabled ?? true
    }
}

/// A window controller whose Tab belongs to its panes rather than to a key view loop, so its controls
/// stay out of that loop unless the system's Keyboard navigation switch puts them in.
@MainActor
protocol PaneKeyWindowController: NSWindowController {}
