import AppKit
import DirnexCore

/// The row along the top of the merge window (PLAN.md §M34 Slice 3): the previous and next
/// conflict, which one is shown, what the current one takes, Show Base and Save. The fifth take
/// keeps both edits where one side changed only whitespace (§M37 Slice 5), and is enabled only on a
/// conflict that offers it.
@MainActor
final class MergeToolbar: NSView {
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onTake: ((TextMerge.Choice) -> Void)?
    var onShowBase: ((Bool) -> Void)?
    var onSave: (() -> Void)?

    let navigation = NSSegmentedControl()
    /// The takes, in `takeChoices`' order.
    let take = NSSegmentedControl()
    let counter = NSTextField(labelWithString: "")
    let showBase = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let save = NSButton()
    /// Room for the counter's longest text in this merge (`reserveCounterWidth`).
    let counterWidth: NSLayoutConstraint
    private var reservedCount: Int?

    /// The takes, in the segments' order: each side, both sides in either order between them, and
    /// last the edit with the other side's whitespace.
    static let takeChoices: [TextMerge.Choice] = [
        .yours,
        .yoursThenTheirs,
        .theirsThenYours,
        .theirs,
        .editWithWhitespace
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

    /// "Conflict 2 of 5", "5 conflicts" or "No conflicts".
    static func counterText(current: Int?, count: Int) -> String {
        guard count > 0 else {
            return String(
                localized: "No conflicts",
                comment: "Merge window: every change merged on its own."
            )
        }
        guard let current else {
            return String(
                localized: "\(count) conflicts",
                comment: "Merge window: how many conflicts; %lld is the count."
            )
        }
        return String(
            localized: "Conflict \(current + 1) of \(count)",
            comment: "Merge window: the conflict on screen; the first %lld is its position, the second the count."
        )
    }

    /// The controls Tab stops at, left to right. One that cannot take the keyboard is passed over:
    /// the takes with no conflict current, and Save until it can save.
    var keyViews: [NSView] {
        [navigation, take, showBase, save]
    }

    /// Show where the merge stands. `count` is `nil` while the merge is being computed, which says
    /// nothing yet rather than "No conflicts". `whitespace` is what whitespace explains in the
    /// current conflict, which names the fifth take and says whether it is offered.
    func showCounter(current: Int?, count: Int?, whitespace: ConflictWhitespace? = nil) {
        if let count, count != reservedCount { reserveCounterWidth(for: count) }
        counter.stringValue = count.map { Self.counterText(current: current, count: $0) } ?? ""
        let hasConflicts = (count ?? 0) > 0
        navigation.setEnabled(hasConflicts, forSegment: 0)
        navigation.setEnabled(hasConflicts, forSegment: 1)
        for (segment, choice) in Self.takeChoices.enumerated() {
            let offered = choice != .editWithWhitespace || whitespace?.combined != nil
            take.setEnabled(current != nil && offered, forSegment: segment)
        }
        if let segment = Self.takeChoices.firstIndex(of: .editWithWhitespace) {
            let title = Self.takeTitle(.editWithWhitespace, editSide: whitespace?.editSide)
            take.setToolTip("\(title) (\(Self.takeKey(.editWithWhitespace)))", forSegment: segment)
            take.image(forSegment: segment)?.accessibilityDescription = title
        }
    }

    /// What the menu's Undo names a take by, and the take's button: "Undo Take Yours". The edit with
    /// the other side's whitespace is named by `editSide`, the side whose text it keeps, and in
    /// general terms while no conflict offers it.
    static func takeTitle(_ choice: TextMerge.Choice, editSide: MergeRow.Column? = nil) -> String {
        switch choice {
        case .yours:
            String(localized: "Take Yours", comment: "Merge window button, tooltip and undo name.")
        case .theirs:
            String(localized: "Take Theirs", comment: "Merge window button, tooltip and undo name.")
        case .yoursThenTheirs:
            String(
                localized: "Take Both, Yours First",
                comment: "Merge window button, tooltip and undo name: your lines, then theirs."
            )
        case .theirsThenYours:
            String(
                localized: "Take Both, Theirs First",
                comment: "Merge window button, tooltip and undo name: their lines, then yours."
            )
        case .editWithWhitespace:
            whitespaceTakeTitle(editSide: editSide)
        }
    }

    private static func whitespaceTakeTitle(editSide: MergeRow.Column?) -> String {
        switch editSide {
        case .theirs?:
            String(
                localized: "Take Theirs with Your Whitespace",
                comment: """
                Merge window button, tooltip and undo name: their lines, with the indentation, spacing \
                and line endings you gave the same lines, where yours changed only whitespace.
                """
            )
        case .yours?:
            String(
                localized: "Take Yours with Their Whitespace",
                comment: """
                Merge window button, tooltip and undo name: your lines, with the indentation, spacing \
                and line endings they gave the same lines, where theirs changed only whitespace.
                """
            )
        default:
            String(
                localized: "Take One Side with the Other’s Whitespace",
                comment: """
                Merge window tooltip, while unavailable: the take offered where one side changed only \
                whitespace, which keeps both edits.
                """
            )
        }
    }

    /// The take's key: the arrow points the way the lines go, from a side into the result in the
    /// middle, and ⇧ adds the other side's after them.
    static func takeKey(_ choice: TextMerge.Choice) -> String {
        switch choice {
        case .yours: "⌥⌘→"
        case .theirs: "⌥⌘←"
        case .yoursThenTheirs: "⇧⌥⌘→"
        case .theirsThenYours: "⇧⌥⌘←"
        case .editWithWhitespace: "⌥⌘I"
        }
    }

    /// Size the counter for the longest text it can show in a merge with `count` conflicts, as the
    /// compare window's counter is sized (`CompareToolbar.reserveCounterWidth`).
    func reserveCounterWidth(for count: Int) {
        reservedCount = count
        let texts = [
            Self.counterText(current: nil, count: count),
            Self.counterText(current: max(0, count - 1), count: count)
        ]
        let font = counter.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let widest = texts.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        counterWidth.constant = ceil(widest) + 4
    }

    // MARK: - Building

    private func build() {
        navigation.segmentCount = 2
        navigation.trackingMode = .momentary
        navigation.segmentStyle = .separated
        let previous = String(
            localized: "Previous Conflict",
            comment: "Merge window button and tooltip."
        )
        let next = String(localized: "Next Conflict", comment: "Merge window button and tooltip.")
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
        buildTake()

        counter.textColor = .secondaryLabelColor
        counter.lineBreakMode = .byTruncatingTail
        counter.setContentCompressionResistancePriority(.init(740), for: .horizontal)
        counterWidth.priority = .init(740)
        counterWidth.isActive = true

        showBase.title = String(localized: "Show Base", comment: "Merge window option.")
        let baseTip = String(
            localized: "Show the version both sides started from",
            comment: "Merge window tooltip for the Show Base option."
        )
        showBase.toolTip = "\(baseTip) (⌥⌘B)"
        showBase.target = self
        showBase.action = #selector(showBaseChanged(_:))

        // The compare window's close prompt keys the same word, and a key takes one comment.
        save.title = String(localized: "Save", comment: "Button that saves the edited files.")
        save.bezelStyle = .push
        save.toolTip = "\(save.title) (⌘S)"
        save.target = self
        save.action = #selector(saveResult(_:))
        save.isEnabled = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [navigation, take, counter, spacer, showBase, save])
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

    /// The takes, one momentary control drawn like the conflict arrows. The arrows point the way the
    /// lines go; the turning ones take both sides, the side they come from first, and the joining
    /// one takes one side's text with the other's whitespace.
    private func buildTake() {
        take.segmentCount = Self.takeChoices.count
        take.trackingMode = .momentary
        take.segmentStyle = .separated
        for (segment, choice) in Self.takeChoices.enumerated() {
            let title = Self.takeTitle(choice)
            let symbol = switch choice {
            case .yours: "arrow.right"
            case .yoursThenTheirs: "arrow.turn.right.down"
            case .theirsThenYours: "arrow.turn.left.down"
            case .theirs: "arrow.left"
            case .editWithWhitespace: "arrow.triangle.merge"
            }
            take.setImage(
                NSImage(systemSymbolName: symbol, accessibilityDescription: title),
                forSegment: segment
            )
            take.setToolTip("\(title) (\(Self.takeKey(choice)))", forSegment: segment)
        }
        take.target = self
        take.action = #selector(takeChoice(_:))
    }

    @objc private func navigate(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            onPrevious?()
        } else {
            onNext?()
        }
    }

    @objc private func takeChoice(_ sender: NSSegmentedControl) {
        guard Self.takeChoices.indices.contains(sender.selectedSegment) else { return }
        onTake?(Self.takeChoices[sender.selectedSegment])
    }

    @objc private func showBaseChanged(_ sender: NSButton) {
        onShowBase?(sender.state == .on)
    }

    @objc private func saveResult(_ sender: Any?) {
        onSave?()
    }
}
