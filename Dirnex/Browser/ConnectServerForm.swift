import AppKit
import DirnexCore

/// The editable body of the Connect-to-Server dialog: a protocol picker (SFTP | SMB) over two
/// per-protocol field sets, with the SMB set's `smb://user@host/share` address field parsing
/// live into editable host / share / user fields and back (PLAN.md §M5 "Address entry is
/// Finder-⌘K-style … parses into editable host / share / user fields shown below it … kept in
/// sync"). `ConnectServerPrompt` wraps this in an `NSAlert`; this owns the controls, the toggles,
/// the two-way URL sync, and reading a validated `Form` back out.
///
/// The two protocols keep independent field sets (rather than sharing host/user) so switching
/// protocols never carries one's values — or one's defaults, like SFTP's `NSUserName()` — into the
/// other. Only the rows for the selected protocol are shown; the accessory is sized once to the
/// taller layout so toggling never resizes the modal.
@MainActor
final class ConnectServerForm: NSObject, NSTextFieldDelegate {
    /// The view to hand `NSAlert.accessoryView` — a fixed-size container holding the grid.
    let accessoryView: NSView
    /// The field the dialog should focus first, per the initially-selected protocol.
    private(set) var initialFirstResponder: NSView

    // Protocol picker.
    private let protocolControl: NSSegmentedControl

    // SMB fields.
    private let address = ConnectFormFactory.textField(placeholder: "smb://host/share")
    private let smbHost = ConnectFormFactory.textField(placeholder: "nas.local")
    private let smbShare = ConnectFormFactory.textField(placeholder: "Media")
    private let smbUser = ConnectFormFactory.textField(placeholder: "guest (leave blank)")
    private let smbPassword = ConnectFormFactory.secureField(
        placeholder: "Password (blank for guest)"
    )

    // SFTP fields.
    private let sftpHost = ConnectFormFactory.textField(placeholder: "example.com")
    private let sftpPort = ConnectFormFactory.textField(placeholder: "22")
    private let sftpUser = ConnectFormFactory.textField(placeholder: NSUserName())
    private let keyFile = ConnectFormFactory.textField(placeholder: "~/.ssh/id_ed25519")
    private let sftpSecret = ConnectFormFactory.secureField(placeholder: "Password")

    // SFTP auth toggle: a Tab-reachable switch flanked by its two mode labels. Off = private key
    // (the default), on = password; the active label is emphasized and the inactive one dimmed.
    private let authSwitch = KeyNavigableSwitch()
    private let authKeyLabel = ConnectFormFactory.label("Private Key")
    private let authPasswordLabel = ConnectFormFactory.label("Password")
    private lazy var authControlView = ConnectFormFactory.authToggle(
        keyLabel: authKeyLabel,
        toggle: authSwitch,
        passwordLabel: authPasswordLabel
    )

    // Shared.
    private let saveName = ConnectFormFactory.textField(placeholder: "Optional — save in sidebar")

    // Rows toggled per protocol / auth method.
    private var smbRows: [NSGridRow] = []
    /// The SFTP rows shown regardless of auth method (host / port / user / the auth toggle).
    private var sftpSharedRows: [NSGridRow] = []
    /// The two auth-dependent SFTP rows; exactly one shows, matching the selected method.
    private var sftpKeyRow: NSGridRow!
    private var sftpPasswordRow: NSGridRow!

    /// The SMB port isn't a visible field — it rides the address URL (default 445 elided). Parsed
    /// out of the URL and folded back in when rebuilding it, so a non-default port round-trips.
    private var smbPort = SMBLocation.defaultPort
    /// Guards the two-way sync from re-entrancy while it writes the paired field.
    private var isSyncing = false

    init(prefill: ServerConnection?) {
        protocolControl = NSSegmentedControl(
            labels: ["SFTP", "SMB"],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        let grid = NSGridView(views: [[ConnectFormFactory.label("Protocol:"), protocolControl]])
        accessoryView = NSView()
        initialFirstResponder = sftpHost
        super.init()

        buildRows(in: grid)
        wireControls()
        applyPrefill(prefill)
        layout(grid: grid)
        updateVisibility()
    }

    // MARK: - Building

    private func buildRows(in grid: NSGridView) {
        smbRows = [
            grid.addRow(with: [ConnectFormFactory.label("Address:"), address]),
            grid.addRow(with: [ConnectFormFactory.label("Host:"), smbHost]),
            grid.addRow(with: [ConnectFormFactory.label("Share:"), smbShare]),
            grid.addRow(with: [ConnectFormFactory.label("User:"), smbUser]),
            grid.addRow(with: [ConnectFormFactory.label("Password:"), smbPassword])
        ]
        sftpSharedRows = [
            grid.addRow(with: [ConnectFormFactory.label("Host:"), sftpHost]),
            grid.addRow(with: [ConnectFormFactory.label("Port:"), sftpPort]),
            grid.addRow(with: [ConnectFormFactory.label("User:"), sftpUser]),
            grid.addRow(with: [ConnectFormFactory.label("Auth:"), authControlView])
        ]
        sftpKeyRow = grid.addRow(with: [ConnectFormFactory.label("Key file:"), keyFile])
        sftpPasswordRow = grid.addRow(with: [ConnectFormFactory.label("Password:"), sftpSecret])
        grid.addRow(with: [ConnectFormFactory.label("Save as:"), saveName])

        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        let controls: [NSView] = [
            protocolControl, address, smbHost, smbShare, smbUser, smbPassword,
            sftpHost, sftpPort, sftpUser, keyFile, sftpSecret, saveName
        ]
        for control in controls {
            control.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
    }

    private func wireControls() {
        protocolControl.selectedSegment = 0
        protocolControl.target = self
        protocolControl.action = #selector(protocolChanged)

        authSwitch.state = .off
        authSwitch.target = self
        authSwitch.action = #selector(authChanged)

        sftpPort.stringValue = String(SFTPLocation.defaultPort)
        sftpUser.stringValue = NSUserName()
        if let known = ConnectFormFactory.defaultIdentityFile() { keyFile.stringValue = known }

        // Only the SMB set needs live field⇄URL syncing.
        for field in [address, smbHost, smbShare, smbUser] { field.delegate = self }
    }

    /// Wrap the grid in a fixed-size container sized to the *taller* of the two protocol layouts, so
    /// switching protocols (which hides/shows rows) never resizes the modal mid-flight — the slack
    /// just sits below the shorter layout. The container keeps an explicit **frame** (autoresizing,
    /// not `false`): `NSAlert` sizes an accessory view by its frame, so a constraint-only container
    /// collapses to zero and overlaps the alert's message. The grid is pinned to the top-left inside
    /// it and keeps its own intrinsic size (so a shorter layout just leaves slack below).
    private func layout(grid: NSGridView) {
        let reserved = reservedSize(of: grid)
        accessoryView.frame = NSRect(origin: .zero, size: reserved)
        grid.translatesAutoresizingMaskIntoConstraints = false
        accessoryView.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: accessoryView.topAnchor),
            grid.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor)
        ])
    }

    /// The size to reserve for the accessory: the larger fitting size across both protocol layouts,
    /// measured by toggling visibility. The final visibility is restored by `updateVisibility()`.
    private func reservedSize(of grid: NSGridView) -> CGSize {
        // SFTP shows its shared rows plus exactly one auth field; the key and password rows are the
        // same height, so measuring with the key row visible captures the layout's true maximum.
        setRows(smbRows, hidden: true)
        setRows(sftpSharedRows, hidden: false)
        sftpKeyRow.isHidden = false
        sftpPasswordRow.isHidden = true
        grid.layoutSubtreeIfNeeded()
        let sftpSize = grid.fittingSize

        setRows(sftpSharedRows, hidden: true)
        sftpKeyRow.isHidden = true
        setRows(smbRows, hidden: false)
        grid.layoutSubtreeIfNeeded()
        let smbSize = grid.fittingSize

        return CGSize(
            width: max(sftpSize.width, smbSize.width),
            height: max(sftpSize.height, smbSize.height)
        )
    }

    // MARK: - Toggles & sync

    private var isSMB: Bool { protocolControl.selectedSegment == 1 }
    /// Whether SFTP key auth is selected (switch off); password auth is the on state.
    private var usingKey: Bool { authSwitch.state == .off }

    @objc private func protocolChanged() {
        updateVisibility()
    }

    @objc private func authChanged() {
        updateVisibility()
    }

    /// Show only the rows relevant to the current protocol and, for SFTP, the current auth method:
    /// the key-file row for key auth or the password row for password auth (never both). SFTP always
    /// shows the four shared rows plus one auth field, so toggling auth keeps the height fixed.
    private func updateVisibility() {
        let smb = isSMB
        setRows(smbRows, hidden: !smb)
        setRows(sftpSharedRows, hidden: smb)
        sftpKeyRow.isHidden = smb || !usingKey
        sftpPasswordRow.isHidden = smb || usingKey
        updateAuthEmphasis()
        initialFirstResponder = smb ? address : sftpHost
    }

    private func setRows(_ rows: [NSGridRow], hidden: Bool) {
        for row in rows { row.isHidden = hidden }
    }

    /// Emphasize the active auth-mode label and dim the inactive one, so the switch's two states
    /// stay legible at a glance.
    private func updateAuthEmphasis() {
        authKeyLabel.textColor = usingKey ? .labelColor : .secondaryLabelColor
        authPasswordLabel.textColor = usingKey ? .secondaryLabelColor : .labelColor
    }

    func controlTextDidChange(_ notification: Notification) {
        guard isSMB, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let object = notification.object as AnyObject
        if object === address {
            syncFieldsFromURL()
        } else if object === smbHost || object === smbShare || object === smbUser {
            syncURLFromFields()
        }
    }

    /// Parse the address field into the host / share / user fields. A malformed, mid-typed URL just
    /// leaves the fields at their last good values rather than clearing them.
    private func syncFieldsFromURL() {
        guard let location = SMBLocation(url: address.stringValue) else { return }
        smbHost.stringValue = location.host
        smbShare.stringValue = location.share ?? ""
        smbUser.stringValue = location.username ?? ""
        smbPort = location.port
    }

    /// Rebuild the address field from the host / share / user fields (folding the remembered port
    /// back in). Skipped while the host is empty — there's no URL to form yet.
    private func syncURLFromFields() {
        let host = smbHost.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        let location = SMBLocation(
            host: host,
            share: smbShare.stringValue,
            username: smbUser.stringValue,
            port: smbPort
        )
        address.stringValue = location.url
    }

    // MARK: - Prefill

    private func applyPrefill(_ prefill: ServerConnection?) {
        guard let prefill else { return }
        saveName.stringValue = prefill.name
        switch prefill.endpoint {
        case let .sftp(location, authentication):
            protocolControl.selectedSegment = 0
            sftpHost.stringValue = location.host
            sftpPort.stringValue = String(location.port)
            sftpUser.stringValue = location.username
            switch authentication {
            case let .key(identityFile):
                authSwitch.state = .off
                keyFile.stringValue = identityFile
            case .password:
                authSwitch.state = .on
                sftpSecret.stringValue = SFTPKeychain.password(for: location) ?? ""
            }
        case let .smb(location):
            protocolControl.selectedSegment = 1
            address.stringValue = location.url
            smbHost.stringValue = location.host
            smbShare.stringValue = location.share ?? ""
            smbUser.stringValue = location.username ?? ""
            smbPort = location.port
            if location.username != nil {
                smbPassword.stringValue = SMBKeychain.password(for: location) ?? ""
            }
        }
    }

    // MARK: - Reading

    /// The validated form, or `nil` when a required field is empty/unsafe — the same "reject rather
    /// than send a broken value" contract the SFTP-only prompt had, now branched per protocol.
    func readForm() -> ConnectServerPrompt.Form? {
        let trimmedName = saveName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? nil : trimmedName
        return isSMB ? readSMBForm(saveName: name) : readSFTPForm(saveName: name)
    }

    private func readSMBForm(saveName: String?) -> ConnectServerPrompt.Form? {
        // The fields are authoritative (the address URL may be mid-edit); they stay in sync with it.
        let host = smbHost.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        let location = SMBLocation(
            host: host,
            share: smbShare.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            username: smbUser.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            port: smbPort
        )
        // A guest mount (no username) carries no password; an authenticated one takes the field as
        // typed (an empty password is legitimate for some servers, so it isn't rejected).
        let password = location.username == nil ? nil : smbPassword.stringValue
        return ConnectServerPrompt.Form(
            endpoint: .smb(location),
            password: password,
            saveName: saveName
        )
    }

    private func readSFTPForm(saveName: String?) -> ConnectServerPrompt.Form? {
        let hostValue = ConnectFormFactory.trimmed(sftpHost)
        let userValue = ConnectFormFactory.trimmed(sftpUser)
        // Reject empties, and anything starting with "-" so a value can't be read as an sftp option.
        guard ConnectFormFactory.isSafeArgument(hostValue),
              ConnectFormFactory.isSafeArgument(userValue) else { return nil }
        let portValue = Int(ConnectFormFactory.trimmed(sftpPort)) ?? SFTPLocation.defaultPort
        let location = SFTPLocation(host: hostValue, port: portValue, username: userValue)

        if usingKey {
            let keyValue = ConnectFormFactory.expandingTilde(ConnectFormFactory.trimmed(keyFile))
            guard !keyValue.isEmpty else { return nil }
            return ConnectServerPrompt.Form(
                endpoint: .sftp(location: location, authentication: .key(identityFile: keyValue)),
                password: nil,
                saveName: saveName
            )
        }
        // Passwords aren't trimmed — leading/trailing spaces can be significant — but a blank one is
        // certainly a mistake, so it's rejected rather than sent as an empty password.
        let secretValue = sftpSecret.stringValue
        guard !secretValue.isEmpty else { return nil }
        return ConnectServerPrompt.Form(
            endpoint: .sftp(location: location, authentication: .password),
            password: secretValue,
            saveName: saveName
        )
    }
}

/// The small view factories and value helpers the form is built from — split out of
/// `ConnectServerForm` so its class body stays within the length limit while everything stays in
/// one file. `@MainActor` because it vends AppKit controls.
@MainActor
private enum ConnectFormFactory {
    static func isSafeArgument(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-")
    }

    static func expandingTilde(_ path: String) -> String {
        path.hasPrefix("~") ? NSHomeDirectory() + path.dropFirst() : path
    }

    static func defaultIdentityFile() -> String? {
        let candidates = ["id_ed25519", "id_rsa"].map {
            NSHomeDirectory() + "/.ssh/" + $0
        }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    static func trimmed(_ field: NSTextField) -> String {
        field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func textField(placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    static func secureField(placeholder: String) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    /// The auth-method cell: the switch centered between its two mode labels ("Private Key" | switch |
    /// "Password"), so both choices stay visible the way the old segmented control showed them.
    static func authToggle(
        keyLabel: NSTextField,
        toggle: NSSwitch,
        passwordLabel: NSTextField
    ) -> NSStackView {
        let stack = NSStackView(views: [keyLabel, toggle, passwordLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
}

/// An `NSSwitch` that always joins the window's key-view loop, so Tab reaches it even when the
/// system's "Full Keyboard Access" setting is off — AppKit otherwise keeps non-text controls out of
/// the loop. Returning `acceptsFirstResponder` (true while enabled) is what the base class does, but
/// only under Full Keyboard Access; overriding makes it unconditional.
private final class KeyNavigableSwitch: NSSwitch {
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
}
