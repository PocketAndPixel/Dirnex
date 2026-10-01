import AppKit
import DirnexCore

/// `dirnex://license?key=…`, the link a license email opens (PLAN.md §M29 "Holding a key").
///
/// **It always asks first**, naming who the key is for, because any web page can open this URL: a
/// link must never change the license on this Mac without the person in front of it agreeing. On
/// yes, the key is kept and Settings ▸ License shows the result. A link whose key doesn't check out
/// says why, in the same words the License tab uses.
@MainActor
enum LicenseLinkActivation {
    /// Handles `url` if it's the activation link, and says whether it was. A build that shows
    /// nothing about licenses ignores the link, as it would any other.
    @discardableResult
    static func handle(
        _ url: URL,
        store: LicenseStore = .shared,
        over window: NSWindow?,
        isOn: Bool = LicensingSwitch.isOn
    ) -> Bool {
        guard isOn, let text = LicenseLinks.keyText(in: url) else { return false }
        Task { await activate(text, store: store, over: window) }
        return true
    }

    private static func activate(_ text: String, store: LicenseStore, over window: NSWindow?) async {
        NSApp.activate(ignoringOtherApps: true)
        switch store.check(text) {
        case let .failure(error):
            _ = await runAlert(refusalAlert(for: error), in: window)
        case let .success(key) where key == store.key:
            SettingsWindowController.shared.present(tab: .license)
        case let .success(key):
            let response = await runAlert(
                confirmationAlert(for: key, replacing: store.key),
                in: window
            )
            guard response == .alertFirstButtonReturn else { return }
            store.activate(text)
            SettingsWindowController.shared.present(tab: .license)
        }
    }

    /// The question before a link's key is kept. **Activate** is the default and Escape cancels.
    static func confirmationAlert(for key: LicenseKey, replacing current: LicenseKey?) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Activate the license for “\(key.licensee)”?",
            comment: "Confirmation after a license link was opened; %@ is the name the license is for."
        )
        let until = key.until.displayText
        if let current {
            alert.informativeText = String(
                localized: """
                It covers every version of Dirnex released until \(until), and replaces the license \
                for “\(current.licensee)” on this Mac. Activate it only if the link came from your \
                own license email.
                """,
                comment: "License link confirmation, replacing a key; %1$@ is a date, %2$@ the current license's name."
            )
        } else {
            alert.informativeText = String(
                localized: """
                It covers every version of Dirnex released until \(until). Activate it only if the \
                link came from your own license email.
                """,
                comment: "License link confirmation; %@ is the last release date the license covers."
            )
        }
        alert.addButton(
            withTitle: String(localized: "Activate", comment: "Button that activates a license key.")
        )
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.enableEscapeToCancel()
        return alert
    }

    /// Why a link's key was refused, with one OK.
    static func refusalAlert(for error: LicenseKeyError) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "This link doesn’t hold a valid license key",
            comment: "Alert title when a license link's key was refused."
        )
        alert.informativeText = error.message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.enableEscapeToCancel()
        return alert
    }

    /// Show the alert as a sheet on the window, or app-modal if there is none (a link opened while
    /// no browser window is up).
    private static func runAlert(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}

extension LicenseDay {
    /// The day as the user's language writes a date in full ("12 March 2027", "March 12, 2027"),
    /// without ever shifting it to the day before (`LicenseDay.date(in:)`).
    var displayText: String {
        date(in: .current).formatted(date: .long, time: .omitted)
    }
}
