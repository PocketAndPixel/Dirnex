import AppKit
import DirnexCore

/// The license reminder (PLAN.md §M29 "What it is"): a sheet over the browser window with a large
/// **Buy a License…** (or **Renew License…**), **Enter License…**, and a small **OK**.
///
/// **Escape and Return do nothing.** It's the one surface in Dirnex where that is intended, because
/// the sheet must not be dismissed by habit. It isn't a trap: OK is one click away, Tab reaches every
/// button (`KeyboardReachableControls`) and Space presses the focused one, and VoiceOver reads and
/// presses them all. That's also why it's a window of its own rather than an `NSAlert`, which binds
/// Escape and Return by design (`scripts/check_alert_escape.py` enforces that it does).
///
/// Buy is in the accent color but deliberately **not** the default button, and no button has focus
/// when the sheet opens, so neither Return nor a stray Space can buy anything.
@MainActor
final class LicenseReminderSheet: NSWindowController {
    enum Choice: Equatable {
        case buy
        case enterLicense
        case ok
    }

    /// Called once, after the sheet has closed, with the button that closed it.
    var onChoice: ((Choice) -> Void)?

    let variant: LicenseReminderVariant
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let bodyLabel = NSTextField(wrappingLabelWithString: "")
    let buyButton = NSButton()
    let enterLicenseButton = NSButton()
    let okButton = NSButton()

    private weak var sheetParent: NSWindow?
    private var didChoose = false

    private static let contentWidth: CGFloat = 400
    private static let inset: CGFloat = 24

    init(variant: LicenseReminderVariant) {
        self.variant = variant
        let window = LicenseReminderWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.contentView = makeContentView()
        window.initialFirstResponder = nil
        if let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            window.setContentSize(
                NSSize(width: Self.contentWidth, height: content.fittingSize.height)
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Presentation

    func present(over parent: NSWindow) {
        guard let window else { return }
        sheetParent = parent
        parent.beginSheet(window) { _ in }
        // Nothing focused, so Space presses nothing until the user chooses a button with Tab.
        window.makeFirstResponder(nil)
    }

    private func choose(_ choice: Choice) {
        guard !didChoose else { return }
        didChoose = true
        if let window, let sheetParent {
            sheetParent.endSheet(window)
        }
        window?.orderOut(nil)
        onChoice?(choice)
    }

    @objc private func buyPressed(_ sender: NSButton) {
        choose(.buy)
    }

    @objc private func enterLicensePressed(_ sender: NSButton) {
        choose(.enterLicense)
    }

    @objc private func okPressed(_ sender: NSButton) {
        choose(.ok)
    }

    // MARK: - Words

    static var title: String {
        String(localized: "Thank you for using Dirnex", comment: "License reminder title.")
    }

    static func body(for variant: LicenseReminderVariant) -> String {
        switch variant {
        case .buy:
            String(
                localized: """
                Dirnex grows from its users’ wishes and feedback. If it’s useful to you, a license \
                keeps it going.
                """,
                comment: "License reminder text when there is no license."
            )
        case let .renew(until):
            String(
                localized: """
                Your license covers versions released until \(until.displayText). This version \
                came out later. Renew to remove this reminder.
                """,
                comment: "License reminder text when the license ended before this version; %@ is a date."
            )
        }
    }

    static func buyTitle(for variant: LicenseReminderVariant) -> String {
        switch variant {
        case .buy: String(localized: "Buy a License…")
        case .renew: String(
                localized: "Renew License…",
                comment: "License reminder button that opens the store to renew."
            )
        }
    }

    // MARK: - Layout

    private func makeContentView() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown

        let textWidth = Self.contentWidth - 2 * Self.inset
        titleLabel.stringValue = Self.title
        titleLabel.font = .boldSystemFont(ofSize: 15)
        titleLabel.alignment = .center
        titleLabel.preferredMaxLayoutWidth = textWidth
        bodyLabel.stringValue = Self.body(for: variant)
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.alignment = .center
        bodyLabel.preferredMaxLayoutWidth = textWidth

        configure(
            buyButton,
            title: Self.buyTitle(for: variant),
            size: .large,
            action: #selector(buyPressed)
        )
        buyButton.bezelColor = AppPreferences.shared.palette.resolvedAccent
        configure(
            enterLicenseButton,
            title: String(
                localized: "Enter License…",
                comment: "License reminder button that opens Settings ▸ License."
            ),
            size: .regular,
            action: #selector(enterLicensePressed)
        )
        configure(
            okButton,
            title: String(localized: "OK"),
            size: .small,
            action: #selector(okPressed)
        )

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [enterLicenseButton, spacer, okButton])
        row.orientation = .horizontal
        row.alignment = .centerY

        let stack = NSStackView(views: [icon, titleLabel, bodyLabel, buyButton, row])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(20, after: bodyLabel)
        stack.edgeInsets = NSEdgeInsets(
            top: Self.inset,
            left: Self.inset,
            bottom: Self.inset,
            right: Self.inset
        )
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            titleLabel.widthAnchor.constraint(equalToConstant: textWidth),
            bodyLabel.widthAnchor.constraint(equalToConstant: textWidth),
            buyButton.widthAnchor.constraint(equalToConstant: textWidth),
            row.widthAnchor.constraint(equalToConstant: textWidth)
        ])
        return content
    }

    private func configure(
        _ button: NSButton,
        title: String,
        size: NSControl.ControlSize,
        action: Selector
    ) {
        button.title = title
        button.bezelStyle = .push
        button.controlSize = size
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: size))
        button.keyEquivalent = ""
        button.target = self
        button.action = action
    }
}

/// The reminder's window: it lets Escape, Return, keypad Enter and ⌘. fall on the floor, silently,
/// rather than beeping or closing. Space still presses a focused button, and every other key behaves
/// as usual.
final class LicenseReminderWindow: NSWindow {
    /// Return, keypad Enter and Escape.
    static let inertKeyCodes: Set<UInt16> = [36, 76, 53]

    override func keyDown(with event: NSEvent) {
        guard !Self.inertKeyCodes.contains(event.keyCode) else { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {}
}
