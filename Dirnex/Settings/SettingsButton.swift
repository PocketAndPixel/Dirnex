import AppKit
import SwiftUI

/// A push button for the Settings window that AppKit draws, so Tab reaches it whatever System
/// Settings ▸ Keyboard ▸ Keyboard navigation says.
///
/// **A SwiftUI `Button` in a `Form` has no `NSButton` behind it.** On macOS 26 SwiftUI draws it
/// itself (probed 2026-09-30: a grouped `Form` holding a field, a switch, a picker and two buttons
/// had an `NSTextField`, an `NSSwitch` and an `NSPopUpButton` in its view tree, and nothing for
/// either button). So `KeyboardReachableControls`' patch on `NSButton` never sees it, and SwiftUI
/// keeps it off the Tab loop while that switch is off, which is the macOS default. Settings' switches,
/// pickers, color wells and steppers are AppKit controls, which is why the rest of the window was
/// reachable and its buttons were not. Found by Oleg in the M29 Slice 6 beta: Tab never reached
/// **Buy a License…** in Settings ▸ License, nor **Activate** after pasting a key.
///
/// An `NSButton` inside the `Form` joins the loop through the same patch, with no new mechanism, and
/// Space presses it and VoiceOver reads it as AppKit's own. The title is a `LocalizedStringResource`,
/// so a literal is extracted into the string catalog under the same key a SwiftUI `Button` literal
/// used, and `.disabled(_:)` works as it does on a SwiftUI button.
struct SettingsButton: NSViewRepresentable {
    enum Role {
        case normal
        /// Marks the button for VoiceOver and AppKit as one that removes something.
        case destructive
    }

    let title: LocalizedStringResource
    var role: Role = .normal
    /// Filled with the accent color, like SwiftUI's `.borderedProminent`. It's never the default
    /// button, so Return never presses it.
    var isProminent = false
    let action: () -> Void

    init(
        _ title: LocalizedStringResource,
        role: Role = .normal,
        isProminent: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.role = role
        self.isProminent = isProminent
        self.action = action
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: String(localized: title),
            target: context.coordinator,
            action: #selector(Coordinator.press)
        )
        button.bezelStyle = .push
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = String(localized: title)
        button.isEnabled = context.environment.isEnabled
        button.hasDestructiveAction = role == .destructive
        button.bezelColor = isProminent ? .controlAccentColor : nil
    }

    func sizeThatFits(_: ProposedViewSize, nsView button: NSButton, context _: Context) -> CGSize? {
        button.intrinsicContentSize
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func press(_: NSButton) {
            action()
        }
    }
}

/// `SettingsButton` with a symbol for its label: an icon-only AppKit push button, so Tab reaches it
/// for the same reason. Its help text is the tooltip and what VoiceOver reads.
///
/// Made for the color rules' add, remove and move buttons, which were SwiftUI `Button`s and which Tab
/// passed (found with a real keyboard 2026-11-24). They share one width, as the SwiftUI ones shared
/// one frame: `plus` and the chevrons are drawn at different widths, and a row of buttons sized to
/// them would not line up.
struct SettingsIconButton: NSViewRepresentable {
    let symbol: String
    let help: String
    let action: () -> Void

    /// Every button's width, whatever its symbol. Its own natural width was 37.5 or 38.5 pt depending
    /// on the symbol (measured on macOS 27.2), wider than SwiftUI's bordered buttons it replaced and
    /// not equal, while a push button's bezel stretches to any width that holds its image.
    static let width: CGFloat = 32

    func makeCoordinator() -> SettingsButton.Coordinator {
        SettingsButton.Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage(),
            target: context.coordinator,
            action: #selector(SettingsButton.Coordinator.press)
        )
        // `NSButton(image:…)` leaves the placeholder title "Button" behind the image.
        button.title = ""
        button.bezelStyle = .push
        button.imagePosition = .imageOnly
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.toolTip = help
        button.image?.accessibilityDescription = help
        button.isEnabled = context.environment.isEnabled
    }

    func sizeThatFits(_: ProposedViewSize, nsView button: NSButton, context _: Context) -> CGSize? {
        CGSize(width: Self.width, height: button.intrinsicContentSize.height)
    }
}
