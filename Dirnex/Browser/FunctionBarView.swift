import AppKit
import DirnexCore

/// One rounded button in the function-key bar: the F-key token in a dimmer, monospaced weight
/// beside the operation caption ("F5 Copy"). Borderless and self-drawn so the row reads as a
/// command bar of rounded chips rather than a row of macOS push buttons — a subtle rounded fill
/// by default, brighter on hover, brightest while pressed, each chip stretched to the bar's full
/// height.
final class FunctionBarButton: NSButton {
    /// The slot this button runs, carried so the bar can hand it to its `onRun` callback without a
    /// parallel index lookup.
    let slot: FunctionBarSlot

    private static let cornerRadius: CGFloat = 6

    private var hoverArea: NSTrackingArea?
    private var isHovered = false

    init(slot: FunctionBarSlot) {
        self.slot = slot
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
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
        // A neutral label-tinted fill so the chip reads the same over the bar's vibrant material in
        // either appearance: faint at rest, a touch brighter hovered, brightest while pressed.
        let alpha: CGFloat = isHighlighted ? 0.22 : (isHovered ? 0.14 : 0.07)
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Self.cornerRadius,
            yRadius: Self.cornerRadius
        ).fill()
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

/// The Total-Commander-style function-key bar (PLAN.md §M6), a strip of labelled rounded buttons
/// along the bottom of the panes column: Copy/Move/NewFolder/Delete and friends on visible buttons
/// a new user can find without the manual. A click reports its slot to `onRun`; the window
/// controller focuses the active pane and dispatches the slot's command there (a nil-target
/// responder-chain dispatch misses, because clicking a bottom-bar button drops the pane's
/// first-responder status first). Its background is the app's own window material, so it reads as
/// the same dark chrome as the sidebar rather than a flat black strip. The window controller owns
/// the bar's height and collapses it when the feature is off.
final class FunctionBarView: NSView {
    /// The bar's fixed height. The window controller uses this for the constraint it collapses to
    /// zero when the bar is hidden.
    static let preferredHeight: CGFloat = 32

    /// Fired when a button is clicked, carrying its slot. The window controller runs it against
    /// the active pane. The bar itself stays ignorant of panes and the command registry.
    var onRun: ((FunctionBarSlot) -> Void)?

    private let stack = NSStackView()

    init(slots: [FunctionBarSlot] = FunctionBar.defaultSlots) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // The bar's background is the *same* vibrant material as the sidebar, so it reads as the
        // app's own dark-blue chrome rather than an opaque near-black fill — `.windowBackground`
        // comes out a flat neutral grey here, where `.sidebar` carries the tint the user sees.
        let material = NSVisualEffectView()
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        material.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)

        // A hairline along the top divides the bar from the panes above it, like the queue bar's.
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: topAnchor),
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Inset the chips from the edges so their rounded corners and the gaps between them
            // read, while still stretching each to (almost) the bar's full height.
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        ])

        for slot in slots {
            let button = FunctionBarButton(slot: slot)
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
}
