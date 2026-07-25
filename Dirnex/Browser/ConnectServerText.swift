import Foundation

/// The Connect-to-Server dialog's on-screen strings — the field labels (reused across the two
/// protocol layouts, which share the Host / User / Password rows), the auth-mode labels, and the
/// field placeholders that carry English hints. Split out of `ConnectServerForm` so that file stays
/// under the length ceiling; the literals live *at* the `String(localized:)` call, so extraction
/// works — unlike passing a variable to `String(localized:)`, which extracts nothing (docs/NOTES.md).
/// `internal` (not `private`) so `ConnectServerForm` reaches it from the other file.
@MainActor
enum ConnectText {
    static var proto: String {
        String(localized: "Protocol:", comment: "Connect field label: SFTP, FTP or SMB.")
    }

    static var security: String {
        String(
            localized: "Security:",
            comment: "Connect field label: which FTP security mode (FTPS or plain FTP)."
        )
    }

    /// The three FTP security modes, in the order the picker shows them — the safe one first.
    /// "FTPS" is the product-level name users see in every other client; the parenthetical says
    /// which of the two FTPS handshakes it is.
    static var ftpsExplicit: String {
        String(
            localized: "FTPS",
            comment: "FTP security mode: TLS negotiated on the normal port (AUTH TLS). The default."
        )
    }

    static var ftpsImplicit: String {
        String(
            localized: "FTPS (implicit)",
            comment: "FTP security mode: TLS from the first byte, on its own port (usually 990)."
        )
    }

    static var ftpPlain: String {
        String(
            localized: "FTP",
            comment: "FTP security mode: no encryption at all. Deliberately last in the picker."
        )
    }

    /// Shown under the picker only while plain FTP is selected. States the tradeoff once, where it
    /// is actionable, rather than warning on every later connect (PLAN.md §7).
    static var plainFTPNote: String {
        String(
            localized: "Plain FTP sends your password and files unencrypted.",
            comment: "Note under the FTP security picker, shown only when plain FTP is selected."
        )
    }

    static var anonymous: String {
        String(
            localized: "Anonymous",
            comment: "Checkbox in the Connect dialog: log in to FTP as the public anonymous user."
        )
    }

    static var address: String {
        String(localized: "Address:", comment: "Connect field label: the SMB URL.")
    }

    static var host: String {
        String(localized: "Host:", comment: "Connect field label: server host name.")
    }

    static var share: String {
        String(localized: "Share:", comment: "Connect field label: SMB share name.")
    }

    static var user: String {
        String(localized: "User:", comment: "Connect field label: user name.")
    }

    static var password: String {
        String(localized: "Password:", comment: "Connect field label: password.")
    }

    static var port: String {
        String(localized: "Port:", comment: "Connect field label: SFTP port.")
    }

    static var auth: String {
        String(localized: "Auth:", comment: "Connect field label: SFTP authentication method.")
    }

    static var keyFile: String {
        String(localized: "Key file:", comment: "Connect field label: SFTP key-file path.")
    }

    static var saveAs: String {
        String(localized: "Save as:", comment: "Connect field label: name to save under.")
    }

    /// Auth-mode label, and the SFTP password field's placeholder — both the bare word "Password".
    static var authPassword: String {
        String(
            localized: "Password",
            comment: "Password field label and placeholder in the Connect dialog."
        )
    }

    static var privateKey: String {
        String(
            localized: "Private Key",
            comment: "SFTP auth-mode label: authenticate with a private key file."
        )
    }

    static var smbUserHint: String {
        String(
            localized: "guest (leave blank)",
            comment: "Placeholder in the SMB user field: a blank user connects as guest."
        )
    }

    static var smbPasswordHint: String {
        String(
            localized: "Password (blank for guest)",
            comment: "Placeholder in the SMB password field: a blank password connects as guest."
        )
    }

    static var saveHint: String {
        String(
            localized: "Optional — save in sidebar",
            comment: "Placeholder in the name field: naming the connection saves it to the sidebar."
        )
    }
}
