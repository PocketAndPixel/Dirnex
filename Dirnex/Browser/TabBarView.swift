import AppKit

/// Owner of a `TabBarView` — the file pane. The bar only reports intent; the pane
/// owns the tab list and every navigation decision (PLAN.md §2 "UI is a thin client").
@MainActor
protocol TabBarViewDelegate: AnyObject {
    func tabBar(_ bar: TabBarView, didSelectTabAt index: Int)
    func tabBar(_ bar: TabBarView, didCloseTabAt index: Int)
    /// One of this bar's chips was dropped into `slot`, a gap between its tabs (`TabSlot`).
    func tabBar(_ bar: TabBarView, didMoveTabFrom source: Int, toSlot slot: Int)
    /// The chip at `index` of `source` — the other pane's strip — was dropped into `slot` of this one.
    func tabBar(
        _ bar: TabBarView,
        didReceiveTabAt index: Int,
        from source: TabBarView,
        atSlot slot: Int
    )
    /// A chip's menu asked for its tab to move to the other pane.
    func tabBar(_ bar: TabBarView, didRequestOtherPanelForTabAt index: Int)
    /// A drag of one of this bar's chips started (`true`) or ended, however it ended.
    func tabBar(_ bar: TabBarView, tabDragIsInFlight inFlight: Bool)
    func tabBarDidRequestNewTab(_ bar: TabBarView)
}

/// A pane's tab strip: one chip per open directory plus a trailing `+`. The active
/// chip is filled (accent when the pane is active, muted otherwise); chips carry a
/// close button and a menu, and can be dragged along the strip or onto the other pane's
/// (`TabBarView+Drag`). Hidden when a pane has a single tab so the browser looks unchanged
/// until you actually open a second one.
@MainActor
final class TabBarView: NSView {
    weak var delegate: TabBarViewDelegate?

    /// Accent the active tab only in the focused pane, matching the path bar.
    var isActivePane = false {
        didSet {
            guard isActivePane != oldValue else { return }
            for chip in chips { chip.isPaneActive = isActivePane }
        }
    }

    /// Set by the pane while a chip from the *other* pane's strip is being dragged: the strip shows
    /// even at a single tab, because it is the drop target and a hidden view receives no drops.
    var isRevealedForDrag = false

    /// The pasteboard type of a chip being dragged, carrying its index. Private to the app and
    /// offered to nothing outside it, so a tab dropped anywhere else is never read as a folder.
    static let tabDragType = NSPasteboard.PasteboardType("com.dirnex.tab")

    /// Gap between chips; the insertion marker sits in the middle of it.
    static let chipSpacing: CGFloat = 3

    private let stack = NSStackView()
    private let newButton = NSButton()
    private(set) var chips: [TabChipView] = []
    private(set) var activeIndex = 0
    /// The chip of this bar being dragged right now, drawn faded until the drag ends.
    var draggedIndex: Int?
    /// The line drawn in the gap a dragged chip would drop into.
    let insertionMarker = NSView()

    /// Re-apply the user's accent to every chip after it changes (PLAN.md §M15 Slice 2). Unlike
    /// `isActivePane`, nothing about a chip's own state has moved — only the color it resolves —
    /// so this restyles them all rather than pushing a value down.
    func restyleForPalette() {
        for chip in chips { chip.restyleForPalette() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 24)
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Self.chipSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        newButton.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: String(
                localized: "New Tab",
                comment: "Accessibility label for the new-tab (+) button in a pane's tab strip."
            )
        )
        newButton.imageScaling = .scaleProportionallyDown
        newButton.isBordered = false
        newButton.bezelStyle = .inline
        newButton.setButtonType(.momentaryChange)
        newButton.controlSize = .small
        newButton.contentTintColor = .secondaryLabelColor
        newButton.target = self
        newButton.action = #selector(newTabClicked)
        newButton.toolTip = String(
            localized: "New Tab (⌘T)",
            comment: "Tooltip on the new-tab (+) button; ⌘T is the keyboard shortcut."
        )

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        // Laid out by hand, outside the stack, so showing it never shifts a chip.
        insertionMarker.wantsLayer = true
        insertionMarker.isHidden = true
        addSubview(insertionMarker)
        registerForDraggedTypes([Self.tabDragType])
    }

    /// What one chip shows: the tab's label, and the SF Symbol for where its listing comes from
    /// (`SidebarPlacePresentation.symbolName(for: LocationSource)`).
    struct Item: Equatable {
        let title: String
        let symbolName: String
    }

    /// Rebuild the chip row. Cheap enough to call on every tab-list change — a pane
    /// rarely has more than a handful of tabs.
    func setTabs(_ items: [Item], activeIndex: Int) {
        self.activeIndex = activeIndex
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        chips = items.enumerated().map { index, item in
            let chip = TabChipView(index: index, item: item, bar: self)
            chip.isActive = index == activeIndex
            chip.isPaneActive = isActivePane
            chip.alphaValue = index == draggedIndex ? TabChipView.draggedAlpha : 1
            return chip
        }
        for chip in chips {
            stack.addArrangedSubview(chip)
        }
        stack.addArrangedSubview(newButton)

        // A greedy trailing spacer keeps chips packed to the left.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
    }

    // MARK: - Chip callbacks

    func chipDidClick(_ chip: TabChipView) {
        delegate?.tabBar(self, didSelectTabAt: chip.index)
    }

    func chipDidClose(_ chip: TabChipView) {
        delegate?.tabBar(self, didCloseTabAt: chip.index)
    }

    @objc private func newTabClicked() {
        delegate?.tabBarDidRequestNewTab(self)
    }
}

/// One tab chip. Handles its own click (select), close button, menu and the start of a drag;
/// the bar routes those to the pane. `hitTest` funnels clicks anywhere on the chip
/// (including its label) to the chip itself, reserving only the close button.
@MainActor
final class TabChipView: NSView {
    /// How faded the chip being dragged is drawn, so the gap it left is legible.
    static let draggedAlpha: CGFloat = 0.35
    /// How far the pointer must travel before a press becomes a drag rather than a click.
    static let dragThreshold: CGFloat = 4

    let index: Int
    /// The SF Symbol drawn before the label, naming where the tab's listing comes from.
    let symbolName: String
    private weak var bar: TabBarView?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    var isActive = false { didSet { applyStyle() } }
    var isPaneActive = false { didSet { applyStyle() } }

    private var pressOrigin: NSPoint = .zero
    /// Set once this press has turned into a drag, which then owns the gesture: the session runs its
    /// own event loop and the chip sees no `mouseUp`, so a click must not fire either.
    private var didDrag = false

    var title: String {
        label.stringValue
    }

    /// The glyph's size: the label's own point size, as the path bar's leading glyph is drawn.
    static var symbolConfiguration: NSImage.SymbolConfiguration {
        NSImage.SymbolConfiguration(pointSize: NSFont.smallSystemFontSize, weight: .regular)
    }

    init(index: Int, item: TabBarView.Item, bar: TabBarView) {
        self.index = index
        symbolName = item.symbolName
        self.bar = bar
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5

        // No description: the label beside it names the tab, and the glyph is not a control.
        icon.image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(Self.symbolConfiguration)
        icon.image?.isTemplate = true
        icon.imageScaling = .scaleNone
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)
        // The glyph is what names the kind of source, so the label truncates first.
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        label.stringValue = item.title
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: String(
                localized: "Close Tab",
                comment: "Accessibility label for a tab chip's close (×) button."
            )
        )
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.setButtonType(.momentaryChange)
        closeButton.controlSize = .small
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.toolTip = String(
            localized: "Close Tab (⌘W)",
            comment: "Tooltip on a tab chip's close (×) button; ⌘W is the keyboard shortcut."
        )

        addSubview(icon)
        addSubview(label)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 5),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 12),
            closeButton.heightAnchor.constraint(equalToConstant: 12)
        ])
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Re-apply the accent after the user changes it (PLAN.md §M15 Slice 2). Internal so
    /// `TabBarView` can walk its chips from the pane's palette observer.
    func restyleForPalette() {
        applyStyle()
    }

    /// The fill and text color the chip is drawn in now; the drag image is drawn from the same pair.
    var colors: (background: NSColor, text: NSColor) {
        // Untouched, these are `.controlAccentColor` and `.alternateSelectedControlTextColor`
        // verbatim, so the shipped chip is unchanged (PLAN.md §M15 Slice 2).
        let palette = AppPreferences.shared.palette
        if isActive, isPaneActive {
            return (palette.resolvedAccent, palette.accentForeground)
        } else if isActive {
            return (.unemphasizedSelectedContentBackgroundColor, .labelColor)
        }
        return (.clear, .secondaryLabelColor)
    }

    private func applyStyle() {
        let (background, text) = colors
        layer?.backgroundColor = background.cgColor
        icon.contentTintColor = text
        label.textColor = text
        closeButton.contentTintColor = isActive && isPaneActive ? text : .secondaryLabelColor
    }

    /// Where the glyph and the label sit in the chip, for the drag image to draw them in place.
    var iconFrame: NSRect { icon.frame }
    var labelFrame: NSRect { label.frame }

    /// Route clicks anywhere on the chip to the chip; only the close button keeps its
    /// own hit area, so neither the label nor the glyph swallows a select click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === closeButton ? closeButton : self
    }

    override func mouseDown(with event: NSEvent) {
        pressOrigin = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag, let bar else { return }
        let location = event.locationInWindow
        guard hypot(location.x - pressOrigin.x, location.y - pressOrigin.y) > Self.dragThreshold else {
            return
        }
        didDrag = true
        bar.beginDrag(of: self, with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard !didDrag else { return }
        bar?.chipDidClick(self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        bar?.chipMenu(for: self)
    }

    @objc private func closeClicked() {
        bar?.chipDidClose(self)
    }
}
