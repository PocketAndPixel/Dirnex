import AppKit
import DirnexCore

/// The "Connect to Server" dialog: pick a protocol (SFTP | SMB), fill in the coordinates and
/// credentials, and optionally name the connection to save it in the sidebar's Servers section.
///
/// Unlike the original `NSAlert` shell, this is a **sheet that stays open until the connection
/// actually succeeds**. Clicking Connect runs the attempt (`attempt`), a spinner shows while it's in
/// flight, and a failure — a wrong password, an unreachable host, a missing share — is reported
/// *inline* with every field the user typed left intact, so they can fix one thing and retry rather
/// than reopening the dialog and starting over. Only success (or Cancel) dismisses it.
///
/// The form body, the protocol/auth toggles, and the SMB address⇄fields sync all live in
/// `ConnectServerForm`; this owns the sheet chrome and the Connect/spinner/error loop around it.
@MainActor
final class ConnectServerPrompt: NSObject {
    struct Form {
        /// Where and how to connect, without the secret — exactly what a saved `ServerConnection`
        /// stores. SFTP carries its location + auth *method*; SMB carries its location.
        let endpoint: ServerEndpoint
        /// The plaintext secret for this session: an SFTP `.password` password, or an SMB
        /// authenticated-mount password; `nil` for SFTP key auth or an SMB guest mount.
        let password: String?
        /// The name under which to save this connection in the sidebar, or `nil` to connect without
        /// saving.
        let saveName: String?
    }

    /// The outcome of one Connect attempt, reported back to the still-open sheet.
    enum Attempt: Sendable {
        case succeeded
        /// An inline reason to show; the sheet stays open with every field intact.
        case failed(String)
    }

    // MARK: - State

    private let form: ConnectServerForm
    private let attempt: (Form) async -> Attempt
    private let onSucceeded: () -> Void
    private weak var parent: NSWindow?
    private let sheet = NSWindow(
        contentRect: .zero,
        styleMask: [.titled],
        backing: .buffered,
        defer: true
    )

    private let connectButton = NSButton()
    private let cancelButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let errorLabel = NSTextField(labelWithString: "")

    /// Retains the presenter for the sheet's lifetime (there's no other owner); cleared on dismissal.
    private var selfRetain: ConnectServerPrompt?

    // MARK: - Presentation

    /// Present the dialog as a sheet over `window`, optionally prefilled from a saved connection.
    /// `attempt` performs one connection attempt and reports back; `onSucceeded` runs after the sheet
    /// closes on success (e.g. to hand keyboard focus to the freshly connected pane).
    static func present(
        over window: NSWindow,
        prefill: ServerConnection? = nil,
        attempt: @escaping (Form) async -> Attempt,
        onSucceeded: @escaping () -> Void
    ) {
        let prompt = ConnectServerPrompt(
            prefill: prefill,
            attempt: attempt,
            onSucceeded: onSucceeded
        )
        prompt.selfRetain = prompt
        prompt.parent = window
        window.beginSheet(prompt.sheet)
        prompt.sheet.makeFirstResponder(prompt.form.initialFirstResponder)
    }

    private init(
        prefill: ServerConnection?,
        attempt: @escaping (Form) async -> Attempt,
        onSucceeded: @escaping () -> Void
    ) {
        form = ConnectServerForm(prefill: prefill)
        self.attempt = attempt
        self.onSucceeded = onSucceeded
        super.init()
        buildLayout()
    }

    // MARK: - Layout

    private func buildLayout() {
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 0
        errorLabel.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        ConnectPromptChrome.configure(cancelButton, title: ConnectPromptChrome.cancel, key: "\u{1b}")
        ConnectPromptChrome.configure(connectButton, title: ConnectPromptChrome.connect, key: "\r")
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        connectButton.target = self
        connectButton.action = #selector(connectClicked)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spinner, spacer, cancelButton, connectButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        let (header, subtitle) = ConnectPromptChrome.header()
        let stack = NSStackView(
            views: [header, form.accessoryView, errorLabel, buttons]
        )
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            // Everything spans the form width, so the error and buttons align to it. The subtitle
            // gets its own width (the form width minus the icon it sits beside) so it wraps within
            // the window instead of running to the right edge while the form sits padded — a direct
            // width constraint on the label is what makes a wrapping NSTextField actually wrap, the
            // same trick errorLabel uses.
            subtitle.widthAnchor.constraint(
                equalTo: form.accessoryView.widthAnchor,
                constant: -(ConnectPromptChrome.iconSize + ConnectPromptChrome.headerSpacing)
            ),
            buttons.widthAnchor.constraint(equalTo: form.accessoryView.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: form.accessoryView.widthAnchor)
        ])
        sheet.contentView = content
        resizeToFit()
    }

    private func resizeToFit() {
        guard let content = sheet.contentView else { return }
        content.layoutSubtreeIfNeeded()
        sheet.setContentSize(content.fittingSize)
    }

    // MARK: - Actions

    @objc private func connectClicked() {
        guard let validForm = form.readForm() else {
            showError(ConnectPromptChrome.incomplete)
            return
        }
        setAttempting(true)
        Task { [weak self] in
            guard let self else { return }
            let result = await attempt(validForm)
            setAttempting(false)
            switch result {
            case .succeeded:
                dismiss()
                onSucceeded()
            case let .failed(message):
                showError(message)
            }
        }
    }

    @objc private func cancelClicked() { dismiss() }

    private func dismiss() {
        parent?.endSheet(sheet)
        sheet.orderOut(nil)
        selfRetain = nil
    }

    /// While an attempt is in flight, lock the buttons and spin — the form fields stay editable, but
    /// the captured `validForm` is what the attempt used, so mid-flight edits only matter on a retry.
    private func setAttempting(_ attempting: Bool) {
        connectButton.isEnabled = !attempting
        cancelButton.isEnabled = !attempting
        if attempting {
            spinner.startAnimation(nil)
            errorLabel.isHidden = true
            resizeToFit()
        } else {
            spinner.stopAnimation(nil)
        }
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = message.isEmpty
        resizeToFit()
    }
}

/// The sheet's chrome — the header (icon + title + subtitle), the two buttons, and the strings around
/// them — split out of `ConnectServerPrompt` so its class body stays within the length limit. The
/// literals live *at* the `String(localized:)` call so Xcode extracts them (docs/NOTES.md).
@MainActor
private enum ConnectPromptChrome {
    static var title: String {
        String(localized: "Connect to Server", comment: "Title of the Connect to Server dialog.")
    }

    static var subtitle: String {
        String(
            localized: "Browse a remote SFTP account or an SMB share on your network.",
            comment: "Subtitle of the Connect to Server dialog."
        )
    }

    static var connect: String {
        String(localized: "Connect", comment: "Confirm button in the Connect to Server dialog.")
    }

    static var cancel: String {
        String(localized: "Cancel", comment: "Cancel button.")
    }

    static var incomplete: String {
        String(
            localized: "Fill in the required fields to connect.",
            comment: "Inline error when Connect is clicked with a required field empty."
        )
    }

    /// The app icon's side, and the gap between it and the titles — shared with `buildLayout`, which
    /// derives the subtitle's wrap width from the form width by subtracting the space the icon takes.
    static let iconSize: CGFloat = 56
    static let headerSpacing: CGFloat = 12

    /// The icon-and-titles row shown above the form, matching the shape `NSAlert` drew for free.
    /// Returns the subtitle alongside the row so the caller can pin its wrap width to the form.
    static func header() -> (row: NSStackView, subtitle: NSTextField) {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: iconSize),
            icon.heightAnchor.constraint(equalToConstant: iconSize)
        ])

        let title = NSTextField(labelWithString: ConnectPromptChrome.title)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        let subtitle = NSTextField(wrappingLabelWithString: ConnectPromptChrome.subtitle)
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2

        let header = NSStackView(views: [icon, titles])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = headerSpacing
        return (header, subtitle)
    }

    static func configure(_ button: NSButton, title: String, key: String) {
        button.title = title
        button.bezelStyle = .rounded
        button.keyEquivalent = key
        button.translatesAutoresizingMaskIntoConstraints = false
    }
}
