import AppKit
import DirnexCore

/// The copy and move dialog's view (PLAN.md §M41): first the question, then, in the same sheet, the
/// progress. ``TransferDialog`` drives it; this only lays out, draws and reports its buttons.
///
/// **The question's folder is a field** (asked 2026-11-19): it opens on the other pane's folder with
/// the insertion point after the path, so typing adds a folder below it (Oleg's call the same day,
/// over selecting the whole path as Total Commander's F5 does).
/// The progress names the folder in a plain label instead, since it can no longer change.
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
    /// Where the items go, while the dialog asks: a path on the destination's own location, with `~`
    /// for home on this Mac, and the path on the server for a server, whose name stands in front of
    /// the field in ``locationLabel``.
    let destinationField = NSTextField.singleLine(truncating: .byTruncatingMiddle)
    let locationLabel = NSTextField(labelWithString: "")
    /// Why the typed folder cannot take the items, under the field.
    let refusalLabel = NSTextField(wrappingLabelWithString: "")
    /// The folder the progress is writing into.
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
    private let destinationRow = NSStackView()
    private let content = NSStackView()
    /// What the field opened with, so an untouched field answers the summary's own folder exactly.
    private var initialDestinationText = ""

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
        for view in [titleLabel, destinationRow, refusalLabel, pathLabel, progressGroup, buttonRow()] {
            content.addArrangedSubview(view)
        }
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        for view in [destinationRow, refusalLabel, pathLabel, progressGroup] {
            content.setCustomSpacing(16, after: view)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        buildLabels()
        buildDestination()
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

    override func viewDidAppear() {
        super.viewDidAppear()
        // Return and Escape still answer the buttons: key equivalents run ahead of the field editor
        // (docs/LIVE-VERIFICATION.md, the field editor and a button's Escape).
        if phase == .asking { focusDestinationField() }
    }

    // MARK: - Phases

    private func showAsking() {
        phase = .asking
        title = TransferDialogText.question(summary)
        titleLabel.stringValue = TransferDialogText.question(summary)
        destinationRow.isHidden = false
        refusalLabel.isHidden = true
        pathLabel.isHidden = true
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

    /// Turn the question into the progress dialog, in place, naming `destination`: the folder the
    /// field named when OK was pressed, the summary's own when none is given.
    func showProgress(destination: VFSPath? = nil) {
        phase = .progress
        let destination = destination ?? summary.destination
        title = TransferDialogText.title(kind: summary.kind, destination: destination)
        titleLabel.stringValue = title ?? ""
        // The field goes, and the keys with it: a hidden field editor would still take typing.
        view.window?.makeFirstResponder(nil)
        destinationRow.isHidden = true
        refusalLabel.isHidden = true
        pathLabel.stringValue = TransferDialogText.location(destination)
        pathLabel.isHidden = false
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
    ///
    /// **Both bars stay determinate, even while the transfer is measured.** An indeterminate bar
    /// switched to determinate keeps sweeping for as long as its value keeps changing: measured
    /// 2026-11-17, `overallIndeterminateAnimation` was still on the layer 4 s after
    /// `stopAnimation` with the value set every 0.1 s, and ended 1.6 s after it only when nothing
    /// was set. Live, the job bar swept across the whole of a 19 GB copy. "Preparing…" says in
    /// words what the sweep said, and the queue bar has never swept either (docs/NOTES.md ▸
    /// Progress and status displays).
    func render(_ state: TransferDialogState, detail: String?) {
        statusLabel.stringValue = TransferDialogText.status(state)
        fileBar.isHidden = !Self.showsFileBar(state, sources: summary.sources)
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

    /// Whether the file's own bar earns its place above the job's: only when more than one file is
    /// going, since with one the two bars draw the same fraction (asked 2026-11-17). Hidden, it
    /// leaves the stack, so the sheet is one bar shorter rather than showing a gap.
    static func showsFileBar(_ state: TransferDialogState, sources: [FileEntry]) -> Bool {
        // Counted by the pre-scan once a job has reported…
        if state.totalFiles > 0 { return state.totalFiles > 1 }
        // …and before that, one marked file is known to be one file, while a folder may hold many.
        return !(sources.count == 1 && sources[0].kind != .directory)
    }

    // MARK: - Building

    private func buildLabels() {
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleLabel.preferredMaxLayoutWidth = Self.width - 2 * Self.inset
        // The title's size, in regular weight: at the small size the destination read as a footnote
        // (asked 2026-11-19), though it is the half of the question the dialog is there to confirm.
        pathLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
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

// MARK: - The destination field

extension TransferDialogController {
    /// The folder the field names: the summary's own while the field reads as it opened, so the round
    /// trip through `~` cannot move it, and otherwise the typed path on the same location.
    var typedDestination: VFSPath {
        let text = destinationField.stringValue
        return text == initialDestinationText
            ? summary.destination
            : TypedFolder.resolve(text, from: summary.destination)
    }

    /// Say why the typed folder cannot take the items, and put the insertion point back in the field.
    func showRefusal(_ sentence: String) {
        refusalLabel.stringValue = sentence
        refusalLabel.isHidden = false
        content.setCustomSpacing(6, after: destinationRow)
        focusDestinationField()
    }

    /// Put the insertion point after the path, with nothing selected. A field made first responder
    /// selects all of its text, so the range is set once its editor exists.
    func focusDestinationField() {
        guard view.window?.makeFirstResponder(destinationField) == true,
              let editor = destinationField.currentEditor() else { return }
        let end = (destinationField.stringValue as NSString).length
        editor.selectedRange = NSRange(location: end, length: 0)
    }

    /// The field opens on the summary's folder. Empty, it means that folder too, which the
    /// placeholder shows.
    private func buildDestination() {
        let destination = summary.destination
        let server = destination.backendRootTitle
        initialDestinationText = server == nil
            ? (destination.path as NSString).abbreviatingWithTildeInPath
            : destination.path
        destinationField.stringValue = initialDestinationText
        destinationField.placeholderString = initialDestinationText
        destinationField.delegate = self
        destinationField.setAccessibilityTitleUIElement(titleLabel)
        destinationField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        destinationField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        locationLabel.stringValue = server ?? ""
        locationLabel.isHidden = server == nil
        locationLabel.textColor = .secondaryLabelColor
        locationLabel.lineBreakMode = .byTruncatingMiddle
        locationLabel.setContentHuggingPriority(.required, for: .horizontal)
        locationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        destinationRow.orientation = .horizontal
        destinationRow.alignment = .firstBaseline
        destinationRow.spacing = 6
        for view in [locationLabel, destinationField] {
            destinationRow.addArrangedSubview(view)
        }
        refusalLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        refusalLabel.textColor = .systemRed
        refusalLabel.preferredMaxLayoutWidth = Self.width - 2 * Self.inset
    }
}

extension TransferDialogController: NSTextFieldDelegate {
    /// An edit answers the refusal: the sentence was about what the field said before.
    func controlTextDidChange(_ obj: Notification) {
        guard !refusalLabel.isHidden else { return }
        refusalLabel.isHidden = true
        content.setCustomSpacing(16, after: destinationRow)
    }
}
