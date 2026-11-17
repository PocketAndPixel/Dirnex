import AppKit
import DirnexCore

/// The copy and move dialog's view (PLAN.md §M41): first the question, then, in the same sheet, the
/// progress. ``TransferDialog`` drives it; this only lays out, draws and reports its buttons.
///
/// **Return and Escape are the same two buttons in both phases**, retitled rather than replaced:
/// OK becomes Background and Cancel stays Cancel. So Return, Return starts a copy and sends it to the
/// queue bar, Escape on the question copies nothing, and Escape, Return on the progress stops it.
/// Both keys ride the buttons' own key equivalents, and an ``AlertKeyCatcher`` behind them answers
/// a key still carrying the chord that raised the dialog: Copy can be rebound to a ⌃, ⌥ or ⌘ chord,
/// the question is up while that modifier is down, and AppKit refuses a key equivalent whose
/// modifiers differ (docs/NOTES.md ▸ The keyboard in a dialog). Shift is not one of them: measured
/// 2026-11-17, a plain button's Return and Escape answer with Shift held, so ⇧F5 needs no help.
@MainActor
final class TransferDialogController: NSViewController {
    enum Phase { case asking, progress }

    /// OK, with whether "Don't ask again" was ticked.
    var onConfirm: ((_ dontAskAgain: Bool) -> Void)?
    /// Cancel or Escape, in either phase.
    var onCancel: (() -> Void)?
    var onPause: (() -> Void)?
    /// Background, Return in the progress phase.
    var onBackground: (() -> Void)?

    private static let width: CGFloat = 460
    private static let inset: CGFloat = 20

    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let pathLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let fileBar = NSProgressIndicator()
    let totalBar = NSProgressIndicator()
    let detailLabel = NSTextField(labelWithString: "")
    let dontAskCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let pauseButton = NSButton(title: "", target: nil, action: nil)
    let cancelButton = NSButton(title: "", target: nil, action: nil)
    let defaultButton = NSButton(title: "", target: nil, action: nil)
    private let progressGroup = NSStackView()

    private(set) var phase: Phase = .asking
    private let summary: TransferSummary
    /// Held when the dialog was built: the chord that raised it, forgiven on Return and Escape.
    private let heldModifiers: NSEvent.ModifierFlags

    init(summary: TransferSummary, heldModifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        self.summary = summary
        self.heldModifiers = heldModifiers
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        // Width fixed, height from the content: presented with `presentAsSheet`, the sheet follows the
        // constraints, so it grows when the progress rows appear.
        let root = NSView()
        let content = NSStackView(views: [titleLabel, pathLabel, progressGroup, buttonRow()])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.setCustomSpacing(16, after: progressGroup)
        content.setCustomSpacing(16, after: pathLabel)
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        buildLabels()
        buildProgressGroup()
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.inset),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.inset),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.inset),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.inset)
        ])
        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        // Last, so it is walked last: reached only when no button took the key (`AlertKeyCatcher`).
        let catcher = AlertKeyCatcher(frame: .zero)
        catcher.escapeButton = cancelButton
        catcher.staleModifiers = heldModifiers.intersection(.deviceIndependentFlagsMask).subtracting(
            .capsLock
        )
        root.addSubview(catcher)
        view = root
        showAsking()
    }

    // MARK: - Phases

    private func showAsking() {
        phase = .asking
        title = TransferDialogText.question(summary)
        titleLabel.stringValue = TransferDialogText.question(summary)
        pathLabel.stringValue = TransferDialogText.location(summary.destination)
        progressGroup.isHidden = true
        dontAskCheckbox.isHidden = false
        pauseButton.isHidden = true
        cancelButton.title = String(
            localized: "Cancel",
            comment: "Copy dialog button that closes it."
        )
        defaultButton.title = String(
            localized: "OK",
            comment: "Copy dialog button that starts the copy or move."
        )
    }

    /// Turn the question into the progress dialog, in place.
    func showProgress() {
        phase = .progress
        title = TransferDialogText.title(kind: summary.kind, destination: summary.destination)
        titleLabel.stringValue = title ?? ""
        progressGroup.isHidden = false
        dontAskCheckbox.isHidden = true
        pauseButton.isHidden = false
        defaultButton.title = String(
            localized: "Background",
            comment: "Copy progress dialog button: closes the dialog and leaves the copy running in the queue bar."
        )
        render(TransferDialogState(phase: .preparing), detail: "")
    }

    /// Draw `state`. `detail` is the readout under the bars, which the dialog refreshes on its own
    /// clock so the rate stays readable; `nil` leaves it as it is.
    func render(_ state: TransferDialogState, detail: String?) {
        statusLabel.stringValue = TransferDialogText.status(state)
        let measuring = state.phase == .preparing
        totalBar.isIndeterminate = measuring
        if measuring { totalBar.startAnimation(nil) } else { totalBar.stopAnimation(nil) }
        totalBar.doubleValue = state.fraction
        fileBar.doubleValue = state.currentFile == nil ? (state.phase == .done ? 1 : 0) : state.currentFileFraction
        if let detail { detailLabel.stringValue = detail }
        pauseButton.title = state.isHeld
            ? String(
                localized: "Resume",
                comment: "Queue-bar button that resumes paused file operations."
            )
            : String(
                localized: "Pause",
                comment: "Queue-bar button that pauses all running file operations."
            )
        pauseButton.isEnabled = state.phase != .done
    }

    // MARK: - Building

    private func buildLabels() {
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleLabel.preferredMaxLayoutWidth = Self.width - 2 * Self.inset
        pathLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.isSelectable = true
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dontAskCheckbox.title = String(
            localized: "Don’t ask again",
            comment: "Copy dialog checkbox: start later copies and moves without this dialog."
        )
        dontAskCheckbox.toolTip = String(
            localized: "Settings ▸ Operations turns the dialog back on.",
            comment: "Tooltip on the copy dialog's Don’t ask again checkbox."
        )
    }

    private func buildProgressGroup() {
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for bar in [fileBar, totalBar] {
            bar.style = .bar
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
        }
        for view in [statusLabel, fileBar, totalBar, detailLabel] {
            progressGroup.addArrangedSubview(view)
        }
        progressGroup.orientation = .vertical
        progressGroup.alignment = .leading
        progressGroup.spacing = 6
        for view in progressGroup.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: progressGroup.widthAnchor).isActive = true
        }
    }

    private func buttonRow() -> NSView {
        dontAskCheckbox.target = self
        for (button, action) in [
            (pauseButton, #selector(pause(_:))),
            (cancelButton, #selector(cancel(_:))),
            (defaultButton, #selector(confirm(_:)))
        ] {
            button.bezelStyle = .push
            button.target = self
            button.action = action
        }
        cancelButton.keyEquivalent = "\u{1b}"
        defaultButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(
            views: [dontAskCheckbox, pauseButton, spacer, cancelButton, defaultButton]
        )
        row.orientation = .horizontal
        row.spacing = 12
        return row
    }

    // MARK: - Buttons

    @objc private func confirm(_ sender: Any?) {
        switch phase {
        case .asking: onConfirm?(dontAskCheckbox.state == .on)
        case .progress: onBackground?()
        }
    }

    @objc private func cancel(_ sender: Any?) {
        onCancel?()
    }

    @objc private func pause(_ sender: Any?) {
        onPause?()
    }
}
