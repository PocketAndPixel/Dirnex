import AppKit
import DirnexCore

/// The trailing titlebar Back/Forward controls: the ⌘[ / ⌘] history commands (View ▸ Go) as two
/// borderless chevron buttons — bare glyphs with no bezel behind them. The click routes through the
/// responder chain (like the Go menu items) so it steps *the focused* pane's per-tab trail; each
/// button's enabled state mirrors that pane's `canGoBack`/`canGoForward`, refreshed on every
/// navigation, tab switch, and focus change (`updateNavigationButtons`).
extension BrowserWindowController {
    /// Width of one chevron's cell, and — because the cells touch — the distance between the two
    /// glyph centres. This is the one dial for how far apart the chevrons *read*, and it is also
    /// the whole of each button's hit target, so the two pull against each other.
    ///
    /// The visible gap is neither of those numbers. Measured by rasterizing the symbols and
    /// scanning their alpha: the box is 10 × 14 but the ink is **7 × 12**, sitting 1pt from the
    /// box's inner edge and 2pt from its outer one — so the gap between the two inks is
    /// `cellWidth − 6`, i.e. 16pt here. Measure the ink, not the box.
    ///
    /// 22 keeps each target 6pt wider than the 16pt buttons this shipped with while closing the
    /// gap they had: those sat 12pt apart, which put their centres 28pt apart and their ink 22pt
    /// apart. Anything narrower trades hit target for tightness point for point.
    ///
    /// Verified live at this value by sweeping `hitTest` a point at a time: Forward owns 7…28pt in
    /// from the window's right edge and Back 29…50, both cells whole and touching.
    private static let cellWidth: CGFloat = 22

    /// Height of one cell. Not symmetrical with the width: nothing competes for vertical space, so
    /// this is simply as tall as the titlebar allows.
    private static let cellHeight: CGFloat = 24

    /// Distance from the forward cell's trailing edge to the window's right corner.
    ///
    /// 6 is the tightest value that costs nothing: `NSThemeFrame` claims the outer **7pt** of the
    /// window for its resize border and answers `hitTest` there itself, whatever is laid out
    /// underneath — measured by sweeping the cluster a point at a time. So a cell edge at 6 loses a
    /// single point to it and everything from 7 inward is live, while pulling the cluster further
    /// out would only push live width into a border that never delivers a click.
    private static let trailingInset: CGFloat = 6

    /// The single `.trailing` accessory for the right-hand control cluster — Back, Forward — in the
    /// otherwise empty transparent title bar.
    func installNavigationButtons() {
        let trailingInset = Self.trailingInset
        let back = String(
            localized: "Back",
            comment: "Accessibility label and tooltip for the titlebar Back button."
        )
        let forward = String(
            localized: "Forward",
            comment: "Accessibility label and tooltip for the titlebar Forward button."
        )
        configureNavButton(
            backButton,
            symbol: "chevron.backward",
            label: back,
            action: #selector(navigateBackPressed(_:)),
            tooltip: navTooltip(back, "go.back")
        )
        configureNavButton(
            forwardButton,
            symbol: "chevron.forward",
            label: forward,
            action: #selector(navigateForwardPressed(_:)),
            tooltip: navTooltip(forward, "go.forward")
        )

        // One *contiguous* cluster: adjacent cells with no gap, so every point between the two
        // glyphs belongs to the nearer chevron and there is no dead space to miss.
        let cellWidth = Self.cellWidth
        let buttons = [backButton, forwardButton]
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The accessory clips to its container's frame, so the container has to be wide enough for
        // every cell in the row plus the trailing inset below.
        let width = CGFloat(buttons.count) * cellWidth + trailingInset
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            // Pin the trailing edge only (both would stretch the row and distort the cells), inset
            // from the container's right edge — which the titlebar parks at the window corner. The
            // inset is what keeps the forward cell's own edge clear of the window's resize border:
            // a cell reaching within a few points of the corner would have an outer sliver that
            // starts a drag-resize instead of navigating.
            stack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -trailingInset
            )
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
        // A `.toolbar` button is intrinsically far wider than its glyph and its size is not pinned
        // to the glyph's, so both dimensions are stated: the glyph stays centred whatever the cell
        // is, and the cell is sized for the *pointer* rather than for the ink.
        //
        // These are the numbers a click actually sees, which is not obvious from the frames: the
        // button's *frame* comes out 5pt taller than the constraint, because a `.toolbar` button
        // carries ~2.5pt of alignment-rect inset above and below, and that overhang is then clipped
        // back off by the enclosing stack's own bounds (`NSView.hitTest` declines a point outside
        // its bounds before it ever descends). So the constraints below are the hit target, and the
        // overhang is neither reachable nor a hazard at the window's top resize border, which
        // `NSThemeFrame` keeps for itself just as it does the right one.
        button.widthAnchor.constraint(equalToConstant: Self.cellWidth).isActive = true
        button.heightAnchor.constraint(equalToConstant: Self.cellHeight).isActive = true
    }

    private func navTooltip(_ label: String, _ commandID: String) -> String {
        if let hint = KeyBindingStore.shared.shortcut(for: commandID)?.display {
            return "\(label) (\(hint))"
        }
        return label
    }
}
