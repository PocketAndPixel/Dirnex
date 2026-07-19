import AppKit
import DirnexCore

/// The trailing titlebar Back/Forward controls, sitting beside the hidden-files toggle: the
/// ⌘[ / ⌘] history commands (View ▸ Go) as two borderless chevron buttons — bare glyphs with no
/// bezel behind them, matching the neighbouring eye toggle. The click routes through the
/// responder chain (like the Go menu items) so it steps *the focused* pane's per-tab trail; each
/// button's enabled state mirrors that pane's `canGoBack`/`canGoForward`, refreshed on every
/// navigation, tab switch, and focus change (`updateNavigationButtons`).
extension BrowserWindowController {
    /// The single `.trailing` accessory for the right-hand control cluster — hidden-files toggle,
    /// Back, Forward — evenly spaced in the otherwise empty transparent title bar. Assumes
    /// `installHiddenToggle` has already prepared the eye button (behaviour + size); this places it.
    func installNavigationButtons() {
        configureNavButton(
            backButton,
            symbol: "chevron.backward",
            label: "Back",
            action: #selector(navigateBackPressed(_:)),
            tooltip: navTooltip("Back", "go.back")
        )
        configureNavButton(
            forwardButton,
            symbol: "chevron.forward",
            label: "Forward",
            action: #selector(navigateForwardPressed(_:)),
            tooltip: navTooltip("Forward", "go.forward")
        )

        // One evenly-spaced cluster: the hidden-files eye toggle, then Back/Forward. The eye button
        // is behaviour-configured and tight-sized by `installHiddenToggle`; it just joins the row
        // here so the three glyphs read as a single control panel rather than separate accessories.
        let spacing: CGFloat = 12
        let stack = NSStackView(views: [hiddenToggleButton, backButton, forwardButton])
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 84, height: 28))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            // Pin the trailing edge only (both would stretch the row and distort the gaps), inset
            // from the container's right edge — which the titlebar parks at the window corner — by
            // the same `spacing` used between buttons, so the forward chevron keeps an even margin
            // from the corner instead of jamming into it.
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -spacing)
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .trailing
        window?.addTitlebarAccessoryViewController(accessory)

        updateNavigationButtons()
    }

    /// Enable each button only when the active pane's trail can move that way, so they grey out at
    /// its ends exactly as ⌘[ / ⌘] disable in the Go menu (`validateMenuItem`).
    func updateNavigationButtons() {
        backButton.isEnabled = focusedPanel.canGoBack
        forwardButton.isEnabled = focusedPanel.canGoForward
    }

    /// Dispatch through the responder chain to the focused pane — the same path the ⌘[ / ⌘] menu
    /// items take, so archive/results panes and history bounds behave identically.
    @objc private func navigateBackPressed(_ sender: NSButton) {
        NSApp.sendAction(#selector(PanelViewController.goBack(_:)), to: nil, from: sender)
    }

    @objc private func navigateForwardPressed(_ sender: NSButton) {
        NSApp.sendAction(#selector(PanelViewController.goForward(_:)), to: nil, from: sender)
    }

    private func configureNavButton(
        _ button: NSButton,
        symbol: String,
        label: String,
        action: Selector,
        tooltip: String
    ) {
        button.bezelStyle = .toolbar
        button.isBordered = false
        button.imagePosition = .imageOnly
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        image?.isTemplate = true
        button.image = image
        button.target = self
        button.action = action
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        // A `.toolbar` button is intrinsically far wider than its glyph, padding the chevron away
        // from the button edges; a tight width strips that so the pair reads as two bare glyphs
        // and the trailing one can sit in the window corner.
        button.widthAnchor.constraint(equalToConstant: 16).isActive = true
    }

    private func navTooltip(_ label: String, _ commandID: String) -> String {
        if let hint = KeyBindingStore.shared.shortcut(for: commandID)?.display {
            return "\(label) (\(hint))"
        }
        return label
    }
}
