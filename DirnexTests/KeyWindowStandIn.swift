import AppKit
import ObjectiveC

/// Has `NSApp.keyWindow` answer a test's window while the test dispatches a key to it.
///
/// On macOS 27.2 a Tab that a control or a plain view hands up the responder chain, and a Space on a
/// focused button, reach `NSWindow.keyDown`, whose `_NSPostProcessKeyboardUIKey` sends the action
/// (`selectNextKeyView:` for Tab) with a nil target. A nil target resolves through `NSApp.keyWindow`.
/// Traced 2026-11-24 in a probe: with no key window `sendAction` answered `NO` and the focus stayed
/// put, and with `keyWindow` answering the probe's window the same Tab went round the loop. macOS
/// 26.6.2 (CI, 2026-11-22) moved the focus in a window that was not key.
///
/// The test host is never the active app here, so its windows are never key (docs/NOTES.md ▸ Testing),
/// and such a key goes nowhere. A real key only ever reaches the key window, so this is the state it
/// arrives in. Everything else stays AppKit's: the control's `keyDown`, the responder chain and the
/// action's dispatch. The window's own `isKeyWindow` still answers `false`.
@MainActor
enum KeyWindowStandIn {
    private static var window: NSWindow?

    /// Run `body` with `window` answering `NSApp.keyWindow`, then put the answer back.
    static func during<Result>(_ window: NSWindow, _ body: () throws -> Result) rethrows -> Result {
        _ = installation
        let previous = Self.window
        Self.window = window
        defer { Self.window = previous }
        return try body()
    }

    /// The real answer whenever no stand-in is set, and off the main thread.
    private static let installation: Void = {
        let selector = #selector(getter: NSApplication.keyWindow)
        guard let method = class_getInstanceMethod(NSApplication.self, selector) else { return }
        typealias Original = @convention(c) (NSApplication, Selector) -> NSWindow?
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (NSApplication) -> NSWindow? = { app in
            let standIn = Thread.isMainThread ? MainActor.assumeIsolated { KeyWindowStandIn.window } : nil
            return standIn ?? original(app, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }()
}
