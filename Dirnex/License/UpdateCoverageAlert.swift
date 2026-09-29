import AppKit
import DirnexCore

/// The notice before an update the license doesn't cover (PLAN.md §M29 "Updates for a key whose
/// period has ended"). `AppUpdater` shows it once a user-initiated check that
/// `UpdateCoverageGate` held back has ended.
///
/// **It says what the update does, and how to move past it: renew.** It doesn't add that the current
/// version stays reminder-free. That's true, since a license covers its versions for good, but said
/// here it reads as advice to stop updating (Oleg, 2026-09-30).
///
/// **Not Now is the default**, and Escape and Return both choose it. The notice exists so that a
/// customer doesn't update into the reminder by habit, so the key a habit presses must not be
/// Update Anyway. Renew isn't the default either, for the same reason Buy isn't on the reminder: a
/// purchase is never one keypress away. Not Now also starts with the keyboard focus, so Space
/// chooses it too: left to itself, the alert put the focus on the last button, Renew License….
@MainActor
enum UpdateCoverageAlert {
    enum Choice: Equatable {
        case notNow
        case updateAnyway
        case renew
    }

    static func alert(for notice: UpdateCoverageNotice) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Your license doesn’t cover Dirnex \(notice.version)",
            comment: "Title of the notice before an update the license doesn't cover; %@ is the update's version."
        )
        alert.informativeText = String(
            localized: """
            Your license covers versions released until \(notice.until.displayText). Dirnex \
            \(notice.version) came out later, so it will show the license reminder until you renew.
            """,
            comment: "Notice before an update the license doesn't cover; %1$@ is a date, %2$@ the update's version."
        )
        alert.addButton(withTitle: String(localized: "Not Now"))
        alert.addButton(withTitle: String(
            localized: "Update Anyway",
            comment: "Button that installs an update the license doesn't cover."
        ))
        alert.addButton(withTitle: String(
            localized: "Renew License…",
            comment: "License reminder button that opens the store to renew."
        ))
        alert.enableEscapeToCancel(safe: .alertFirstButtonReturn)
        alert.window.initialFirstResponder = alert.buttons.first
        return alert
    }

    static func choice(for response: NSApplication.ModalResponse) -> Choice {
        switch response {
        case .alertSecondButtonReturn: .updateAnyway
        case .alertThirdButtonReturn: .renew
        default: .notNow
        }
    }

    /// Shows the notice as a sheet on `window`, or app-modal if there's none, and reports the
    /// choice.
    static func present(_ notice: UpdateCoverageNotice, over window: NSWindow?) async -> Choice {
        let alert = alert(for: notice)
        guard let window else { return choice(for: alert.runModal()) }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: choice(for: $0)) }
        }
    }
}
