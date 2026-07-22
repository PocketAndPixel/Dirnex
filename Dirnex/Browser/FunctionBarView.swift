import AppKit
import DirnexCore

/// One flush button in the function-key bar: the F-key token in a dimmer, monospaced weight beside
/// the operation caption ("F5 Copy"). Borderless and self-drawn so the row reads as a command bar
/// of edge-to-edge cells rather than macOS push buttons — transparent at rest, a label-tinted wash
/// on hover, a stronger wash while pressed, each cell stretched to the bar's full height. A hairline
/// `|` on the trailing edge separates it from the next cell.
final class FunctionBarButton: NSButton {
    /// The slot this button runs, carried so the bar can hand it to its `onRun` callback without a
    /// parallel index lookup.
    let slot: FunctionBarSlot

    /// Draw a `|` divider on the trailing edge — set on every cell except the last so the dividers
    /// sit *between* cells and never against the bar's edge.
    var showsTrailingSeparator = false

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
        // Transparent at rest so each cell reads flush over the panel-coloured bar; a label-tinted
        // wash appears on hover and deepens while pressed.
        let alpha: CGFloat = isHighlighted ? 0.20 : (isHovered ? 0.12 : 0)
        if alpha > 0 {
            NSColor.labelColor.withAlphaComponent(alpha).setFill()
            bounds.fill()
        }
        // A `|` between adjacent cells, inset only slightly from the top and bottom edges.
        if showsTrailingSeparator {
            NSColor.separatorColor.setFill()
            NSRect(x: bounds.maxX - 1, y: 5, width: 1, height: bounds.height - 12).fill()
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
            string: LocalizedCatalog.label(for: slot),
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

    /// "Copy to Other Panel (F5)" — the command's full menu title, which the cell itself is too
    /// narrow to print. A user script isn't in the catalog and its label already *is* its full
    /// name, so it falls back to that rather than going tooltip-less.
    private static func tooltip(for slot: FunctionBarSlot) -> String? {
        let title = LocalizedCatalog.command(for: slot.commandID)?.title
            ?? LocalizedCatalog.label(for: slot)
        return "\(title) (\(slot.keyName))"
    }
}

/// The Total-Commander-style function-key bar (PLAN.md §M6), a strip of labelled rounded buttons
/// along the bottom of the panes column: Copy/Move/NewFolder/Delete and friends on visible buttons
/// a new user can find without the manual. A click reports its slot to `onRun`; the window
/// controller focuses the active pane and dispatches the slot's command there (a nil-target
/// responder-chain dispatch misses, because clicking a bottom-bar button drops the pane's
/// first-responder status first). Its background is the same `.textBackgroundColor` as the file
/// panes, so the bar reads as a continuation of the panels rather than separate chrome. The window
/// controller owns the bar's height and collapses it when the feature is off.
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
        wantsLayer = true // the panel-coloured fill is painted in updateLayer, tracking appearance

        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 0 // cells sit flush; the `|` dividers they draw stand in for the gap
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // A hairline along the top divides the bar from the queue bar above it. Added last so it
        // paints over the flush cells rather than being covered by them.
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Flush to every edge: no padding around or between the cells.
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        setSlots(slots)
    }

    /// Replace the row of cells with `slots`. The bar is not a fixed layout: a user script can be
    /// bound to a function key (or unbound, or renamed) while windows are open, so the window
    /// controller re-derives the slots and calls this rather than rebuilding the whole window.
    func setSlots(_ slots: [FunctionBarSlot]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview() // removeArrangedSubview alone leaves it drawn as a subview
        }
        for (index, slot) in slots.enumerated() {
            let button = FunctionBarButton(slot: slot)
            button.showsTrailingSeparator = index < slots.count - 1
            button.target = self
            button.action = #selector(runSlot(_:))
            stack.addArrangedSubview(button)
            // Stretch each cell to the bar's full height — the stack centres arranged views at
            // their intrinsic height otherwise, leaving a gap above and below.
            button.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Match the file panes' `.textBackgroundColor`; resolved here so it tracks light/dark.
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true // re-resolve the CGColor for the new appearance
    }

    @objc private func runSlot(_ sender: FunctionBarButton) {
        onRun?(sender.slot)
    }
}
