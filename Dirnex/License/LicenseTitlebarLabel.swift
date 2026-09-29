import AppKit
import DirnexCore

/// The quiet **Unlicensed** (or **Renew License**) label in the browser window's titlebar (PLAN.md
/// §M29 "A quiet label"). Clicking it opens Settings ▸ License.
///
/// It shows exactly while the reminder is due: hidden during the thirty quiet days, whenever a key
/// covers this build, and in every build that doesn't remind. It is its own leading accessory, placed
/// after the sidebar toggle and the update indicator, rather than a view in their stack: that stack's
/// container is clipped to a fixed width, while this one is sized to its title, and to nothing while
/// hidden.
@MainActor
final class LicenseTitlebarLabel: NSTitlebarAccessoryViewController {
    let button = NSButton()
    private let reminders: LicenseReminderController

    init(reminders: LicenseReminderController = .shared) {
        self.reminders = reminders
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .leading
        button.bezelStyle = .inline
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        button.target = self
        button.action = #selector(pressed)
        button.toolTip = String(
            localized: "Show the license settings",
            comment: "Tooltip of the titlebar label shown while the license reminder is due."
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 28))
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        ])
        view = container
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dueDidChange),
            name: LicenseReminderController.dueDidChange,
            object: nil
        )
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func title(for variant: LicenseReminderVariant) -> String {
        switch variant {
        case .buy:
            String(
                localized: "Unlicensed",
                comment: "Titlebar label while the license reminder is due and there is no license."
            )
        case .renew:
            String(
                localized: "Renew License",
                comment: "Titlebar label while the license reminder is due and the license has ended."
            )
        }
    }

    @objc private func dueDidChange() {
        update()
    }

    /// Show or hide the label against the reminder's state, and size the accessory to fit.
    ///
    /// It hides the **button** and collapses the accessory to no width. The accessory's own
    /// `isHidden` is not used: on a leading titlebar accessory it hides nothing, at launch or later
    /// (seen live; the property read back `true` while the label stayed on screen, and a label never
    /// shown drew the button's default title, "Button").
    func update() {
        guard let variant = reminders.dueVariant else {
            button.isHidden = true
            view.setFrameSize(NSSize(width: 0, height: view.frame.height))
            return
        }
        button.title = Self.title(for: variant)
        button.isHidden = false
        view.setFrameSize(NSSize(width: button.fittingSize.width + 8, height: view.frame.height))
    }

    /// Whether the label is showing, as drawn.
    var isShowing: Bool {
        !button.isHidden && view.frame.width > 0
    }

    @objc private func pressed(_ sender: NSButton) {
        SettingsWindowController.shared.present(tab: .license)
    }
}
