import AppKit
import DirnexCore

/// Opens Report a Bug… and remembers what it held (PLAN.md §M30).
///
/// A report closed without sending is kept until Dirnex quits, so Escape or a stray Cancel loses
/// nothing: the next Report a Bug… opens with the same texts and boxes. A report that was sent
/// starts the next one fresh. The reply email is remembered across launches, as the plan asks;
/// it is the one thing written to disk, and only when a report is sent.
@MainActor
enum BugReportPresenter {
    /// The report closed without sending, for the next opening.
    private static var draft: BugReportForm?
    /// The dialog on screen, so a second Report a Bug… brings it forward rather than opening two.
    private weak static var current: BugReportController?

    static func present(
        from host: NSViewController,
        endpoint: URL,
        defaults: UserDefaults = .standard
    ) {
        if let current, let window = current.view.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        var form = draft ?? BugReportForm()
        if form.email.isEmpty { form.email = defaults.string(
            forKey: AppPreferences.Keys.bugReportEmail
        ) ?? "" }
        let controller = BugReportController(form: form, context: context(endpoint: endpoint))
        controller.onClose = { [weak host] form, outcome in
            guard case let .sent(reference)? = outcome else {
                draft = form
                return
            }
            draft = nil
            remember(email: controller.report.email, in: defaults)
            thank(reference: reference, over: host?.view.window)
        }
        current = controller
        host.presentAsMovableWindow(controller)
    }

    /// What the dialog shows about this Mac, read once.
    static func context(
        endpoint: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> BugReportController.Context {
        BugReportController.Context(
            endpoint: endpoint,
            system: .current(),
            licensed: LicensingSwitch.isOn ? LicenseStore.shared.key != nil : nil,
            crashReport: CrashReportLocator.newestReport(home: home),
            redaction: .current
        )
    }

    /// The email of a report that was sent, or none when it was sent without one.
    static func remember(email: String?, in defaults: UserDefaults) {
        if let email {
            defaults.set(email, forKey: AppPreferences.Keys.bugReportEmail)
        } else {
            defaults.removeObject(forKey: AppPreferences.Keys.bugReportEmail)
        }
    }

    private static func thank(reference: String?, over window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Thank you for the report",
            comment: "Title of the alert after a bug report was sent."
        )
        if let reference {
            alert.informativeText = String(
                localized: "It was sent. If you write about it later, mention the reference \(reference).",
                comment: "Text of the alert after a bug report was sent; %@ is the server's reference for it."
            )
        } else {
            alert.informativeText = String(
                localized: "It was sent.",
                comment: "Text of the alert after a bug report was sent, when there is no reference."
            )
        }
        alert.addButton(withTitle: String(localized: "OK"))
        alert.enableEscapeToCancel()
        alert.beginSheetIfVisible(over: window)
    }
}
