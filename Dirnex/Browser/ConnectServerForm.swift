import AppKit
import DirnexCore

/// The editable body of the Connect-to-Server dialog: a protocol picker (SFTP | FTP | SMB) over
/// three per-protocol field sets. This owns the picker, the SFTP rows and their auth toggle, the
/// shared "Save as" row, and the layout; `ConnectServerFTPFields` and `ConnectServerSMBFields` own
/// theirs, in their own files — three protocols' worth of stored controls does not fit in one type
/// under SwiftLint's `type_body_length`.
///
/// The three protocols keep independent field sets (rather than sharing host/user) so switching
/// protocols never carries one's values — or one's defaults, like SFTP's `NSUserName()` — into
/// another. Only the rows for the selected protocol are shown; the accessory is sized once to the
/// tallest layout so toggling never resizes the sheet.
@MainActor
final class ConnectServerForm: NSObject {
    /// The view to hand `NSAlert.accessoryView` — a fixed-size container holding the grid.
    let accessoryView: NSView
    /// The field the dialog should focus first, per the initially-selected protocol.
    private(set) var initialFirstResponder: NSView

    // Protocol picker.
    private let protocolControl: NSSegmentedControl

    // SFTP fields.
    private let sftpHost = ConnectFormFactory.textField(placeholder: "example.com")
    private let sftpPort = ConnectFormFactory.textField(placeholder: "22")
    private let sftpUser = ConnectFormFactory.textField(placeholder: NSUserName())
    private let keyFile = ConnectFormFactory.textField(placeholder: "~/.ssh/id_ed25519")
    private let sftpSecret = ConnectFormFactory.secureField(placeholder: ConnectText.authPassword)

    // SFTP auth toggle: a Tab-reachable switch flanked by its two mode labels. Off = private key
    // (the default), on = password; the active label is emphasized and the inactive one dimmed.
    private let authSwitch = KeyNavigableSwitch()
    private let authKeyLabel = ConnectFormFactory.label(ConnectText.privateKey)
    private let authPasswordLabel = ConnectFormFactory.label(ConnectText.authPassword)
    private lazy var authControlView = ConnectFormFactory.authToggle(
        keyLabel: authKeyLabel,
        toggle: authSwitch,
        passwordLabel: authPasswordLabel
    )

    // Shared.
    private let saveName = ConnectFormFactory.textField(placeholder: ConnectText.saveHint)

    // Rows toggled per protocol / auth method.
    /// The SFTP rows shown regardless of auth method (host / port / user / the auth toggle).
    private var sftpSharedRows: [NSGridRow] = []
    /// The two auth-dependent SFTP rows; exactly one shows, matching the selected method.
    private var sftpKeyRow: NSGridRow!
    private var sftpPasswordRow: NSGridRow!

    /// The FTP and SMB field sets, each in its own object and its own file (see the type comment).
    private let ftp = ConnectServerFTPFields()
    private let smb = ConnectServerSMBFields()

    init(prefill: ServerConnection?) {
        // SFTP first (the secure default and the most-used), then FTP, then SMB.
        protocolControl = NSSegmentedControl(
            labels: ["SFTP", "FTP", "SMB"],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        let grid = NSGridView(views: [[
            ConnectFormFactory.label(ConnectText.proto), protocolControl
        ]])
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
        let smbControls = smb.buildRows(in: grid)
        sftpSharedRows = [
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.host), sftpHost]),
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.port), sftpPort]),
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.user), sftpUser]),
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.auth), authControlView])
        ]
        sftpKeyRow = grid.addRow(
            with: [ConnectFormFactory.label(ConnectText.keyFile), keyFile]
        )
        sftpPasswordRow = grid.addRow(
            with: [ConnectFormFactory.label(ConnectText.password), sftpSecret]
        )
        let ftpControls = ftp.buildRows(in: grid)
        ftp.onLayoutChanged = { [weak self] in self?.onLayoutChanged?() }
        grid.addRow(with: [ConnectFormFactory.label(ConnectText.saveAs), saveName])

        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        let controls: [NSView] = [
            protocolControl, sftpHost, sftpPort, sftpUser, keyFile, sftpSecret, saveName
        ] + ftpControls + smbControls
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
    }

    /// Wrap the grid in a fixed-size container sized to the *taller* of the two protocol layouts, so
    /// switching protocols (which hides/shows rows) never resizes the sheet mid-flight — the slack
    /// just sits below the shorter layout. The container is pinned to an explicit width/height via
    /// constraints (not a frame) so it carries a fixed size into the sheet's stack view. The grid is
    /// pinned to the top-left inside it and keeps its own intrinsic size (so a shorter layout just
    /// leaves slack below).
    private func layout(grid: NSGridView) {
        let reserved = reservedSize(of: grid)
        accessoryView.translatesAutoresizingMaskIntoConstraints = false
        grid.translatesAutoresizingMaskIntoConstraints = false
        accessoryView.addSubview(grid)
        NSLayoutConstraint.activate([
            accessoryView.widthAnchor.constraint(equalToConstant: reserved.width),
            accessoryView.heightAnchor.constraint(equalToConstant: reserved.height),
            grid.topAnchor.constraint(equalTo: accessoryView.topAnchor),
            grid.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor)
        ])
    }

    /// The size to reserve for the accessory: the larger fitting size across both protocol layouts,
    /// measured by toggling visibility. The final visibility is restored by `updateVisibility()`.
    private func reservedSize(of grid: NSGridView) -> CGSize {
        // SFTP shows its shared rows plus exactly one auth field; the key and password rows are the
        // same height, so measuring with the key row visible captures the layout's true maximum.
        setRows(smb.rows, hidden: true)
        setRows(sftpSharedRows, hidden: false)
        sftpKeyRow.isHidden = false
        sftpPasswordRow.isHidden = true
        grid.layoutSubtreeIfNeeded()
        let sftpSize = grid.fittingSize

        setRows(sftpSharedRows, hidden: true)
        sftpKeyRow.isHidden = true
        setRows(smb.rows, hidden: false)
        grid.layoutSubtreeIfNeeded()
        let smbSize = grid.fittingSize

        // FTP is measured with its cleartext note *visible*, which is its tallest state — so
        // toggling to plain FTP grows into reserved slack instead of resizing the sheet.
        setRows(smb.rows, hidden: true)
        setRows(ftp.allRows, hidden: false)
        grid.layoutSubtreeIfNeeded()
        let ftpSize = grid.fittingSize
        setRows(ftp.allRows, hidden: true)

        return CGSize(
            width: max(sftpSize.width, max(smbSize.width, ftpSize.width)),
            height: max(sftpSize.height, max(smbSize.height, ftpSize.height))
        )
    }

    // MARK: - Toggles & sync

    /// Which protocol the picker has selected. Named rather than compared by index, so adding a
    /// third one could not silently re-point `isSMB` at FTP — which is exactly what it would have
    /// done, since SMB moved from segment 1 to segment 2.
    private enum Protocols: Int {
        case sftp = 0
        case ftp = 1
        case smb = 2
    }

    private var selectedProtocol: Protocols {
        Protocols(rawValue: protocolControl.selectedSegment) ?? .sftp
    }

    private var isSMB: Bool { selectedProtocol == .smb }
    private var isFTP: Bool { selectedProtocol == .ftp }
    /// Whether SFTP key auth is selected (switch off); password auth is the on state.
    private var usingKey: Bool { authSwitch.state == .off }

    @objc private func protocolChanged() {
        updateVisibility()
        onLayoutChanged?()
    }

    @objc private func authChanged() {
        updateVisibility()
    }

    /// Show only the rows relevant to the current protocol and, for SFTP, the current auth method:
    /// the key-file row for key auth or the password row for password auth (never both). SFTP always
    /// shows the four shared rows plus one auth field, so toggling auth keeps the height fixed.
    private func updateVisibility() {
        let selected = selectedProtocol
        setRows(smb.rows, hidden: selected != .smb)
        setRows(sftpSharedRows, hidden: selected != .sftp)
        sftpKeyRow.isHidden = selected != .sftp || !usingKey
        sftpPasswordRow.isHidden = selected != .sftp || usingKey
        ftp.setHidden(selected != .ftp)
        updateAuthEmphasis()
        switch selected {
        case .smb: initialFirstResponder = smb.firstResponder
        case .ftp: initialFirstResponder = ftp.firstResponder
        case .sftp: initialFirstResponder = sftpHost
        }
    }

    /// Raised when a toggle changes the layout's height, so the sheet can re-fit around it — the
    /// plain-FTP note appears and disappears with the security picker.
    var onLayoutChanged: (() -> Void)?

    private func setRows(_ rows: [NSGridRow], hidden: Bool) {
        for row in rows { row.isHidden = hidden }
    }

    /// Emphasize the active auth-mode label and dim the inactive one, so the switch's two states
    /// stay legible at a glance.
    private func updateAuthEmphasis() {
        authKeyLabel.textColor = usingKey ? .labelColor : .secondaryLabelColor
        authPasswordLabel.textColor = usingKey ? .secondaryLabelColor : .labelColor
    }

    // MARK: - Prefill

    private func applyPrefill(_ prefill: ServerConnection?) {
        guard let prefill else { return }
        saveName.stringValue = prefill.name
        switch prefill.endpoint {
        case let .sftp(location, authentication):
            protocolControl.selectedSegment = Protocols.sftp.rawValue
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
        case let .ftp(location, authentication, _):
            protocolControl.selectedSegment = Protocols.ftp.rawValue
            ftp.apply(location: location, authentication: authentication)
        case let .smb(location):
            protocolControl.selectedSegment = Protocols.smb.rawValue
            smb.apply(location: location)
        }
    }

    // MARK: - Reading

    /// The validated form, or `nil` when a required field is empty/unsafe — the same "reject rather
    /// than send a broken value" contract the SFTP-only prompt had, now branched per protocol.
    func readForm() -> ConnectServerPrompt.Form? {
        let trimmedName = saveName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? nil : trimmedName
        switch selectedProtocol {
        case .smb: return smb.readForm(saveName: name)
        case .ftp: return ftp.readForm(saveName: name)
        case .sftp: return readSFTPForm(saveName: name)
        }
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
/// `ConnectServerForm` so its class body stays within the length limit. `@MainActor` because it
/// vends AppKit controls. `internal` rather than `private` so `ConnectServerFTPFields`, which lives
/// in its own file for the same length reason, builds its controls from the same factory —
/// `private` does not cross files (docs/NOTES.md).
@MainActor
enum ConnectFormFactory {
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
        configureSingleLine(field)
        return field
    }

    static func secureField(placeholder: String) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        configureSingleLine(field)
        return field
    }

    /// Keep an entry field to a single, horizontally-scrolling line. A long value — a full
    /// `smb://user@host/share` address is easily wider than the 280 pt field — otherwise wraps and
    /// grows the row, which pushed the grid apart and made the field read as empty. Single-line mode
    /// scrolls to follow the cursor instead; `.byTruncatingHead` keeps the business end (host and
    /// share) visible when the field isn't being edited. Set the break mode *after* single-line mode,
    /// which forces `.byTruncatingTail` of its own.
    private static func configureSingleLine(_ field: NSTextField) {
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.lineBreakMode = .byTruncatingHead
    }

    static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    /// A small secondary-colour explanatory line under a control — used for the plain-FTP cleartext
    /// note. Wraps, so a longer translation grows downward instead of being clipped.
    static func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
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
