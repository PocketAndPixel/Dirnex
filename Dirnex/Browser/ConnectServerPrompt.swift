import AppKit
import DirnexCore

/// The modal "Connect to Server" dialog: pick a protocol (SFTP | SMB), fill in the coordinates and
/// credentials, and optionally name the connection to save it in the sidebar's Servers section
/// (PLAN.md §M5 "a generalized prompt … with a protocol segmented control (SFTP | SMB) … and a
/// 'Save connection' name field"). Returns a validated `Form` — a `ServerEndpoint` (SFTP location +
/// auth method, or SMB location), the plaintext secret to use for this session, and the optional
/// save name — or `nil` when cancelled or left incomplete.
///
/// The form body, the protocol/auth toggles, and the SMB address⇄fields sync all live in
/// `ConnectServerForm`; this is just the `NSAlert` shell around it.
enum ConnectServerPrompt {
    struct Form {
        /// Where and how to connect, without the secret — exactly what a saved `ServerConnection`
        /// stores. SFTP carries its location + auth *method*; SMB carries its location.
        let endpoint: ServerEndpoint
        /// The plaintext secret for this session: an SFTP `.password` auth password, or an SMB
        /// authenticated-mount password; `nil` for SFTP key auth or an SMB guest mount. The caller
        /// files it in the Keychain (on success) and hands it to the transport / mounter.
        let password: String?
        /// The name under which to save this connection in the sidebar, or `nil` to connect without
        /// saving (the SFTP-only prompt's original behaviour).
        let saveName: String?
    }

    /// Present the dialog over `window`, optionally prefilled from an existing saved connection (the
    /// sidebar's "Edit…"). Returns the validated form, or `nil` on cancel / incomplete input.
    @MainActor
    static func run(over window: NSWindow?, prefill: ServerConnection? = nil) -> Form? {
        let form = ConnectServerForm(prefill: prefill)

        let alert = NSAlert()
        alert.messageText = String(
            localized: "Connect to Server",
            comment: "Title of the Connect to Server dialog."
        )
        alert.informativeText = String(
            localized: "Browse a remote SFTP account or an SMB share on your network.",
            comment: "Subtitle of the Connect to Server dialog."
        )
        alert.addButton(withTitle: String(
            localized: "Connect",
            comment: "Confirm button in the Connect to Server dialog."
        ))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Cancel button."))
        alert.accessoryView = form.accessoryView
        alert.window.initialFirstResponder = form.initialFirstResponder

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return form.readForm()
    }
}
