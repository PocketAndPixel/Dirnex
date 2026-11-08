import AppKit
import DirnexCore

/// The row along the top of the compare window (PLAN.md §M31 Slice 3): the previous and next
/// change, which one is shown, which file is on which side, and what the comparison overlooks.
@MainActor
final class CompareToolbar: NSView {
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onSwap: (() -> Void)?
    var onCopy: ((ComparisonPaneText.Side) -> Void)?
    var onOptionsChange: ((LineDiffOptions) -> Void)?
    var onStop: (() -> Void)?
    var onCompareAgain: (() -> Void)?

    let navigation = NSSegmentedControl()
    /// Copy to Left and Copy to Right, beside the change arrows: the side each segment copies to
    /// is `copySides`'.
    let copy = NSSegmentedControl()
    static let copySides: [ComparisonPaneText.Side] = [.left, .right]
    let counter = NSTextField(labelWithString: "")
    /// Spins beside the counter while a comparison takes a while (PLAN.md §M37 Slice 3).
    let comparingSpinner = NSProgressIndicator()
    /// Stop while a comparison runs, and Compare Again once one has been stopped.
    let stopButton = NSButton(title: "", target: nil, action: nil)
    /// What ``stopButton`` is showing.
    var comparingState = ComparingState.idle
    /// Swap Sides: one momentary segment, so it draws like the change buttons beside it.
    let swap = NSSegmentedControl()
    let whitespace = NSPopUpButton()
    let ignoresCase = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let ignoresLineEndings = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    /// Room for the counter's longest text in this comparison (`reserveCounterWidth`).
    let counterWidth: NSLayoutConstraint
    /// The change count `counterWidth` was last sized for.
    private var reservedCount: Int?

    /// Whether the toolbar is saying a comparison is running, or was stopped.
    enum ComparingState {
        case idle
        case comparing
        case stopped
    }

    /// The whitespace choices, in the popup's order.
    static let whitespaceChoices: [LineDiffOptions.Whitespace] = [
        .compare, .ignoreTrailing, .ignoreChanges, .ignoreAll
    ]

    init() {
        counterWidth = counter.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The controls Tab stops at, left to right. One that cannot take the keyboard is passed over:
    /// Copy with neither side taking a copy, or hidden in a window that takes none.
    var keyViews: [NSView] {
        [navigation, copy, stopButton, swap, whitespace, ignoresCase, ignoresLineEndings]
    }

    /// The options the controls show.
    var options: LineDiffOptions {
        LineDiffOptions(
            whitespace: Self.whitespaceChoices[max(0, whitespace.indexOfSelectedItem)],
            ignoresLineEndings: ignoresLineEndings.state == .on,
            ignoresCase: ignoresCase.state == .on
        )
    }

    func showCounter(current: Int?, count: Int) {
        if count != reservedCount { reserveCounterWidth(for: count) }
        counter.stringValue = Self.counterText(current: current, count: count)
        navigation.setEnabled(count > 0, forSegment: 0)
        navigation.setEnabled(count > 0, forSegment: 1)
    }

    /// Leave only the change arrows and the counter, for the byte view (PLAN.md §M37 Slice 2), which
    /// has no lines to copy and no options to overlook anything by.
    func showOnlyNavigation() {
        for control in [copy, swap, whitespace, ignoresCase, ignoresLineEndings] as [NSView] {
            control.isHidden = true
        }
    }

    /// Enable each copy button when a copy to its side would go through.
    func enableCopy(toLeft: Bool, toRight: Bool) {
        copy.setEnabled(toLeft, forSegment: 0)
        copy.setEnabled(toRight, forSegment: 1)
    }

    /// Size the counter for the longest text it can show in a comparison with `count` changes, so
    /// stepping from "Change 9 of 12" to "Change 10 of 12" never makes it wider than the window has
    /// already made room for.
    func reserveCounterWidth(for count: Int) {
        reservedCount = count
        let texts = [
            Self.counterText(current: nil, count: count),
            Self.counterText(current: max(0, count - 1), count: count)
        ]
        let font = counter.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let widest = texts.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        // The label's cell draws its text inset by two points on each side.
        counterWidth.constant = ceil(widest) + 4
    }

    // MARK: - Building

    private func build() {
        navigation.segmentCount = 2
        navigation.trackingMode = .momentary
        navigation.segmentStyle = .separated
        let previous = String(
            localized: "Previous Change",
            comment: "Compare window button and tooltip."
        )
        let next = String(localized: "Next Change", comment: "Compare window button and tooltip.")
        navigation.setImage(
            NSImage(systemSymbolName: "chevron.up", accessibilityDescription: previous),
            forSegment: 0
        )
        navigation.setImage(
            NSImage(systemSymbolName: "chevron.down", accessibilityDescription: next),
            forSegment: 1
        )
        navigation.setToolTip("\(previous) (⌥⌘↑)", forSegment: 0)
        navigation.setToolTip("\(next) (⌥⌘↓)", forSegment: 1)
        navigation.target = self
        navigation.action = #selector(navigate(_:))
        buildCopy()

        let swapSides = String(
            localized: "Swap Sides",
            comment: "Compare window button and tooltip."
        )
        swap.segmentCount = 1
        swap.trackingMode = .momentary
        swap.segmentStyle = .separated
        swap.setImage(
            NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: swapSides),
            forSegment: 0
        )
        swap.setToolTip("\(swapSides) (⌘U)", forSegment: 0)
        swap.target = self
        swap.action = #selector(swapSides(_:))

        counter.textColor = .secondaryLabelColor
        counter.lineBreakMode = .byTruncatingTail
        // Just under the option controls' 750, and above the 500 a window holds its size at, so the
        // window cannot be made narrower than the counter needs (PLAN.md §M31 Slice 5). At the old
        // `.defaultLow` the counter gave way first and vanished entirely in German at the window's
        // minimum width, and truncated to "Cha…" in English.
        counter.setContentCompressionResistancePriority(.init(740), for: .horizontal)
        counterWidth.priority = .init(740)
        counterWidth.isActive = true

        whitespace.removeAllItems()
        whitespace.addItems(withTitles: Self.whitespaceChoices.map(Self.title(for:)))
        whitespace.target = self
        whitespace.action = #selector(optionsChanged(_:))
        ignoresCase.title = String(localized: "Ignore Case", comment: "Compare window option.")
        ignoresLineEndings.title = String(
            localized: "Ignore Line Endings",
            comment: "Compare window option."
        )
        for box in [ignoresCase, ignoresLineEndings] {
            box.target = self
            box.action = #selector(optionsChanged(_:))
        }

        buildComparing()
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(
            views: [
                navigation, copy, counter, comparingSpinner, stopButton, spacer, swap, whitespace,
                ignoresCase, ignoresLineEndings
            ]
        )
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The stack shrank its own insets by two points when the small Stop button joined it, and
            // the panes below jumped four when it left. Tied to the arrows, which are always there.
            heightAnchor.constraint(equalTo: navigation.heightAnchor, constant: 12)
        ])
    }

    /// Copy to Left and Copy to Right, one momentary control drawn like the change arrows.
    private func buildCopy() {
        copy.segmentCount = 2
        copy.trackingMode = .momentary
        copy.segmentStyle = .separated
        for (segment, side) in Self.copySides.enumerated() {
            let title = Self.copyTitle(to: side)
            let symbol = side == .left ? "arrow.left" : "arrow.right"
            copy.setImage(
                NSImage(systemSymbolName: symbol, accessibilityDescription: title),
                forSegment: segment
            )
            copy.setToolTip("\(title) (\(side == .left ? "⌥⌘←" : "⌥⌘→"))", forSegment: segment)
        }
        copy.target = self
        copy.action = #selector(copyChange(_:))
    }

    @objc private func navigate(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            onPrevious?()
        } else {
            onNext?()
        }
    }

    @objc private func swapSides(_ sender: Any?) {
        onSwap?()
    }

    @objc private func copyChange(_ sender: NSSegmentedControl) {
        guard Self.copySides.indices.contains(sender.selectedSegment) else { return }
        onCopy?(Self.copySides[sender.selectedSegment])
    }

    @objc private func optionsChanged(_ sender: Any?) {
        onOptionsChange?(options)
    }
}
