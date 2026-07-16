import AppKit
import DirnexCore

/// One flat button in the function-key bar: the F-key token in a dimmer, monospaced weight
/// beside the operation caption ("F5 Copy"), with its own hover and press feedback. Borderless
/// and self-drawn so a tight row of them reads as a Total Commander function bar rather than a
/// row of macOS push buttons, and so the whole strip stays 28 pt tall.
final class FunctionBarButton: NSButton {
    /// The slot this button runs, carried so the bar can hand it to its `onRun` callback without a
    /// parallel index lookup.
    let slot: FunctionBarSlot
    /// Draw a hairline on the leading edge to divide this button from its neighbour; the first
    /// button in the row leaves it off (its edge is the window edge).
    var showsLeadingSeparator = true

    private var hoverArea: NSTrackingArea?
    private var isHovered = false

    init(slot: FunctionBarSlot) {
        self.slot = slot
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        setButtonType(.momentaryPushIn)
        imagePosition = .noImage
        refusesFirstResponder = true // clicking must never steal focus from the active pane
        attributedTitle = Self.title(for: slot)
        toolTip = Self.tooltip(for: slot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // A pressed button reads darkest, a hovered one a touch lighter, idle is transparent so
        // the bar's own background shows through.
        if isHighlighted {
            NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
            bounds.fill()
        } else if isHovered {
            NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.5).setFill()
            bounds.fill()
        }
        if showsLeadingSeparator {
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: 4, width: 1, height: bounds.height - 8).fill()
        }
        super.draw(dirtyRect)
    }

    /// "F5" (secondary, monospaced) then the caption (primary), centred and truncating.
    private static func title(for slot: FunctionBarSlot) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: slot.keyName + " ",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        result.append(NSAttributedString(
            string: slot.label,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor
            ]
        ))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        result.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    private static func tooltip(for slot: FunctionBarSlot) -> String? {
        guard let command = CommandCatalog.command(for: slot.commandID) else { return nil }
        return "\(command.title) (\(slot.keyName))"
    }
}

/// The Total-Commander-style function-key bar (PLAN.md §M6), a strip of labelled buttons along
/// the window bottom: Copy/Move/NewFolder/Delete and friends on visible buttons a new user can
/// find without the manual. A click reports its slot to `onRun`; the window controller focuses the
/// active pane and dispatches the slot's command there — a nil-target responder-chain dispatch
/// (like the button doing it itself) misses, because clicking a bottom-bar button drops the pane's
/// first-responder status first. The window controller owns the bar's height and collapses it when
/// the feature is off (mirroring the queue bar).
final class FunctionBarView: NSView {
    /// The bar's fixed height, including the top hairline. The window controller uses this for
    /// the constraint it collapses to zero when the bar is hidden.
    static let preferredHeight: CGFloat = 28

    /// Fired when a button is clicked, carrying its slot. The window controller runs it against
    /// the active pane. The bar itself stays ignorant of panes and the command registry.
    var onRun: ((FunctionBarSlot) -> Void)?

    private let stack = NSStackView()

    init(slots: [FunctionBarSlot] = FunctionBar.defaultSlots) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            // 1 pt below the top so the bar's top hairline (drawn in `draw`) shows above the row.
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        for (index, slot) in slots.enumerated() {
            let button = FunctionBarButton(slot: slot)
            button.showsLeadingSeparator = index > 0
            button.target = self
            button.action = #selector(runSlot(_:))
            stack.addArrangedSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func runSlot(_ sender: FunctionBarButton) {
        onRun?(sender.slot)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        // Top hairline, matching the column-header and queue-bar borders.
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
