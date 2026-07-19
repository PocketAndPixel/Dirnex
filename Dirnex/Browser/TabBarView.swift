import AppKit

/// Owner of a `TabBarView` — the file pane. The bar only reports intent; the pane
/// owns the tab list and every navigation decision (PLAN.md §2 "UI is a thin client").
@MainActor
protocol TabBarViewDelegate: AnyObject {
    func tabBar(_ bar: TabBarView, didSelectTabAt index: Int)
    func tabBar(_ bar: TabBarView, didCloseTabAt index: Int)
    func tabBar(_ bar: TabBarView, didMoveTabFrom source: Int, to destination: Int)
    func tabBarDidRequestNewTab(_ bar: TabBarView)
}

/// A pane's tab strip: one chip per open directory plus a trailing `+`. The active
/// chip is filled (accent when the pane is active, muted otherwise); chips carry a
/// close button and can be dragged to reorder. Hidden when a pane has a single tab so
/// the browser looks unchanged until you actually open a second one.
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

    private let stack = NSStackView()
    private let newButton = NSButton()
    private var chips: [TabChipView] = []
    private(set) var activeIndex = 0

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
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false

        newButton.image = NSImage(
            systemSymbolName: "plus", accessibilityDescription: "New Tab"
        )
        newButton.imageScaling = .scaleProportionallyDown
        newButton.isBordered = false
        newButton.bezelStyle = .inline
        newButton.setButtonType(.momentaryChange)
        newButton.controlSize = .small
        newButton.contentTintColor = .secondaryLabelColor
        newButton.target = self
        newButton.action = #selector(newTabClicked)
        newButton.toolTip = "New Tab (⌘T)"

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    /// Rebuild the chip row. Cheap enough to call on every tab-list change — a pane
    /// rarely has more than a handful of tabs.
    func setTabs(_ titles: [String], activeIndex: Int) {
        self.activeIndex = activeIndex
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        chips = titles.enumerated().map { index, title in
            let chip = TabChipView(index: index, title: title, bar: self)
            chip.isActive = index == activeIndex
            chip.isPaneActive = isActivePane
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

    /// A chip was dragged and released at `locationX` (this view's coordinates); move
    /// it to whichever slot that x falls into.
    func chipDidDrag(_ chip: TabChipView, toLocationX locationX: CGFloat) {
        let destination = destinationIndex(forX: locationX)
        guard destination != chip.index else { return }
        delegate?.tabBar(self, didMoveTabFrom: chip.index, to: destination)
    }

    private func destinationIndex(forX x: CGFloat) -> Int {
        for chip in chips where x < chip.frame.midX {
            return chip.index
        }
        return max(chips.count - 1, 0)
    }

    @objc private func newTabClicked() {
        delegate?.tabBarDidRequestNewTab(self)
    }
}

/// One tab chip. Handles its own click (select), close-button, and drag-to-reorder;
/// the bar routes those to the pane. `hitTest` funnels clicks anywhere on the chip
/// (including its label) to the chip itself, reserving only the close button.
@MainActor
final class TabChipView: NSView {
    let index: Int
    private weak var bar: TabBarView?
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    var isActive = false { didSet { applyStyle() } }
    var isPaneActive = false { didSet { applyStyle() } }

    private var pressOriginX: CGFloat = 0
    private var didDrag = false

    init(index: Int, title: String, bar: TabBarView) {
        self.index = index
        self.bar = bar
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5

        label.stringValue = title
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.setButtonType(.momentaryChange)
        closeButton.controlSize = .small
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.toolTip = "Close Tab (⌘W)"

        addSubview(label)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
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

    private func applyStyle() {
        let background: NSColor
        let text: NSColor
        if isActive, isPaneActive {
            background = .controlAccentColor
            text = .alternateSelectedControlTextColor
        } else if isActive {
            background = .unemphasizedSelectedContentBackgroundColor
            text = .labelColor
        } else {
            background = .clear
            text = .secondaryLabelColor
        }
        layer?.backgroundColor = background.cgColor
        label.textColor = text
        closeButton.contentTintColor = isActive && isPaneActive ? text : .secondaryLabelColor
    }

    /// Route clicks anywhere on the chip to the chip; only the close button keeps its
    /// own hit area, so the label never swallows a select click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === closeButton ? closeButton : self
    }

    override func mouseDown(with event: NSEvent) {
        pressOriginX = event.locationInWindow.x
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        if abs(event.locationInWindow.x - pressOriginX) > 4 {
            didDrag = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let bar else { return }
        if didDrag {
            let x = bar.convert(event.locationInWindow, from: nil).x
            bar.chipDidDrag(self, toLocationX: x)
        } else {
            bar.chipDidClick(self)
        }
    }

    @objc private func closeClicked() {
        bar?.chipDidClose(self)
    }
}
