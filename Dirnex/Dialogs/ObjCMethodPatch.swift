import AppKit
import ObjectiveC

/// Wrapping an AppKit method on a whole class, for behaviour that has to reach views Dirnex does not
/// construct — `NSAlert`'s buttons, SwiftUI's private controls, a tab view's own selector.
///
/// One variant per return type, because a `@convention(c)` function type cannot be generic. Each
/// hands `body` the view and the original implementation, and installs the replacement **on the
/// class itself when the method is only inherited**, so a superclass keeps its own; a class that
/// defines the method has it replaced in place.
enum ObjCMethodPatch {
    /// Wrap an argument-less `BOOL` method.
    static func wrapBool(
        _ selector: Selector,
        on viewClass: AnyClass,
        body: @escaping (NSView, () -> Bool) -> Bool
    ) {
        guard let method = class_getInstanceMethod(viewClass, selector) else { return }
        typealias Original = @convention(c) (NSView, Selector) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (NSView) -> Bool = { view in
            body(view) { original(view, selector) }
        }
        install(imp_implementationWithBlock(replacement), for: selector, on: viewClass, over: method)
    }

    /// Wrap an argument-less method returning an `NSRect`.
    static func wrapRect(
        _ selector: Selector,
        on viewClass: AnyClass,
        body: @escaping (NSView, () -> NSRect) -> NSRect
    ) {
        guard let method = class_getInstanceMethod(viewClass, selector) else { return }
        typealias Original = @convention(c) (NSView, Selector) -> NSRect
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (NSView) -> NSRect = { view in
            body(view) { original(view, selector) }
        }
        install(imp_implementationWithBlock(replacement), for: selector, on: viewClass, over: method)
    }

    /// Wrap an argument-less method returning nothing.
    static func wrapVoid(
        _ selector: Selector,
        on viewClass: AnyClass,
        body: @escaping (NSView, () -> Void) -> Void
    ) {
        guard let method = class_getInstanceMethod(viewClass, selector) else { return }
        typealias Original = @convention(c) (NSView, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (NSView) -> Void = { view in
            body(view) { original(view, selector) }
        }
        install(imp_implementationWithBlock(replacement), for: selector, on: viewClass, over: method)
    }

    /// Run `body` for `view` on the main actor; anywhere else, `fallback` — AppKit's own behaviour.
    static func onMainActor<Result: Sendable>(
        _ view: NSView,
        else fallback: Result,
        _ body: @MainActor (NSView) -> Result
    ) -> Result {
        guard Thread.isMainThread else { return fallback }
        return MainActor.assumeIsolated { body(view) }
    }

    private static func install(
        _ implementation: IMP,
        for selector: Selector,
        on viewClass: AnyClass,
        over method: Method
    ) {
        if !class_addMethod(viewClass, selector, implementation, method_getTypeEncoding(method)) {
            method_setImplementation(method, implementation)
        }
    }
}
