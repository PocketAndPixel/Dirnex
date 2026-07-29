import AppKit
import DirnexCore

/// The SMB half of the Connect-to-Server form: a Finder-⌘K-style `smb://user@host/share` address
/// field that parses live into editable host / share / user fields and back (PLAN.md §M5), plus the
/// password.
///
/// Extracted from `ConnectServerForm` when FTP became the third protocol and the class no longer fit
/// under SwiftLint's `type_body_length`. Each protocol now owns its fields in its own file, which is
/// what the form always implied — the sets are deliberately independent so switching protocols never
/// carries one's values, or one's defaults, into another.
@MainActor
final class ConnectServerSMBFields: NSObject, NSTextFieldDelegate {
    let address = ConnectFormFactory.textField(placeholder: "smb://nas.local/Media")
    let host = ConnectFormFactory.textField(placeholder: "nas.local")
    let share = ConnectFormFactory.textField(placeholder: "Media")
    let user = ConnectFormFactory.textField(placeholder: ConnectText.smbUserHint)
    let password = ConnectFormFactory.secureField(placeholder: ConnectText.smbPasswordHint)

    /// The SMB port isn't a visible field — it rides the address URL (default 445 elided). Parsed
    /// out of the URL and folded back in when rebuilding it, so a non-default port round-trips.
    private var port = SMBLocation.defaultPort
    /// Guards the two-way sync from re-entrancy while it writes the paired field.
    private var isSyncing = false

    private(set) var rows: [NSGridRow] = []

    /// The field to focus when SMB is the selected protocol.
    var firstResponder: NSView { address }

    // MARK: - Building

    func buildRows(in grid: NSGridView) -> [NSView] {
        rows = [
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.address), address]),
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.host), host]),
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.share), share]),
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.user), user]),
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.password), password])
        ]
        // Only the SMB set needs live field⇄URL syncing.
        for field in [address, host, share, user] { field.delegate = self }
        return [address, host, share, user, password]
    }

    // MARK: - Sync

    func controlTextDidChange(_ notification: Notification) {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let object = notification.object as AnyObject
        if object === address {
            syncFieldsFromURL()
        } else if object === host || object === share || object === user {
            syncURLFromFields()
        }
    }

    /// Parse the address field into the host / share / user fields. A malformed, mid-typed URL just
    /// leaves the fields at their last good values rather than clearing them.
    private func syncFieldsFromURL() {
        guard let location = SMBLocation(url: address.stringValue) else { return }
        host.stringValue = location.host
        share.stringValue = location.share ?? ""
        user.stringValue = location.username ?? ""
        port = location.port
    }

    /// Rebuild the address field from the host / share / user fields (folding the remembered port
    /// back in). Skipped while the host is empty — there's no URL to form yet.
    private func syncURLFromFields() {
        let hostValue = ConnectFormFactory.trimmed(host)
        guard !hostValue.isEmpty else { return }
        let location = SMBLocation(
            host: hostValue,
            share: share.stringValue,
            username: user.stringValue,
            port: port
        )
        address.stringValue = location.url
    }

    // MARK: - Prefill

    func apply(location: SMBLocation) {
        address.stringValue = location.url
        host.stringValue = location.host
        share.stringValue = location.share ?? ""
        user.stringValue = location.username ?? ""
        port = location.port
        if location.username != nil {
            password.stringValue = SMBKeychain.password(for: location) ?? ""
        }
    }

    // MARK: - Reading

    func readForm(saveName: String?) -> ConnectServerPrompt.Form? {
        // The fields are authoritative (the address URL may be mid-edit); they stay in sync with it.
        let hostValue = ConnectFormFactory.trimmed(host)
        guard !hostValue.isEmpty else { return nil }
        let location = SMBLocation(
            host: hostValue,
            share: ConnectFormFactory.trimmed(share),
            username: ConnectFormFactory.trimmed(user),
            port: port
        )
        // A guest mount (no username) carries no password; an authenticated one takes the field as
        // typed (an empty password is legitimate for some servers, so it isn't rejected).
        let secret = location.username == nil ? nil : password.stringValue
        return ConnectServerPrompt.Form(
            endpoint: .smb(location),
            password: secret,
            saveName: saveName
        )
    }
}
