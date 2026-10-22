import AppKit
import DirnexCore

/// The row along the top of the compare window (PLAN.md §M31 Slice 3): the previous and next
/// change, which one is shown, and what the comparison overlooks.
@MainActor
final class CompareToolbar: NSView {
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onOptionsChange: ((LineDiffOptions) -> Void)?

    let navigation = NSSegmentedControl()
    let counter = NSTextField(labelWithString: "")
    let whitespace = NSPopUpButton()
    let ignoresCase = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let ignoresLineEndings = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    /// The whitespace choices, in the popup's order.
    static let whitespaceChoices: [LineDiffOptions.Whitespace] = [
        .compare, .ignoreTrailing, .ignoreChanges, .ignoreAll
    ]

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The options the controls show.
    var options: LineDiffOptions {
        LineDiffOptions(
            whitespace: Self.whitespaceChoices[max(0, whitespace.indexOfSelectedItem)],
            ignoresLineEndings: ignoresLineEndings.state == .on,
            ignoresCase: ignoresCase.state == .on
        )
    }

    /// "Change 3 of 12", "12 changes" or "No differences".
    static func counterText(current: Int?, count: Int) -> String {
        guard count > 0 else {
            return String(
                localized: "No differences",
                comment: "Compare window: the two texts have no changed line."
            )
        }
        guard let current else {
            return String(
                localized: "\(count) changes",
                comment: "Compare window: how many changes; %lld is the count."
            )
        }
        return String(
            localized: "Change \(current + 1) of \(count)",
            comment: "Compare window: the change on screen; the first %lld is its position, the second the count."
        )
    }

    func showCounter(current: Int?, count: Int) {
        counter.stringValue = Self.counterText(current: current, count: count)
        navigation.setEnabled(count > 0, forSegment: 0)
        navigation.setEnabled(count > 0, forSegment: 1)
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

        counter.textColor = .secondaryLabelColor
        counter.lineBreakMode = .byTruncatingTail
        counter.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(
            views: [navigation, counter, spacer, whitespace, ignoresCase, ignoresLineEndings]
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
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    static func title(for whitespace: LineDiffOptions.Whitespace) -> String {
        switch whitespace {
        case .compare:
            String(localized: "Compare Whitespace", comment: "Compare window whitespace option.")
        case .ignoreTrailing:
            String(
                localized: "Ignore Whitespace at Line End",
                comment: "Compare window whitespace option."
            )
        case .ignoreChanges:
            String(
                localized: "Ignore Changes in Whitespace",
                comment: "Compare window whitespace option."
            )
        case .ignoreAll:
            String(localized: "Ignore All Whitespace", comment: "Compare window whitespace option.")
        }
    }

    @objc private func navigate(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            onPrevious?()
        } else {
            onNext?()
        }
    }

    @objc private func optionsChanged(_ sender: Any?) {
        onOptionsChange?(options)
    }
}
