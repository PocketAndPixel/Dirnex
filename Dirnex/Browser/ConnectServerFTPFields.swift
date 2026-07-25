import AppKit
import DirnexCore

/// The FTP half of the Connect-to-Server form: security mode, host, port, user (or anonymous) and
/// password, plus the cleartext note that appears only when plain FTP is chosen.
///
/// It is its own object rather than more stored properties on `ConnectServerForm` because that class
/// already sits at SwiftLint's `type_body_length` with two protocols in it; a third would not fit,
/// and the FTP rows have enough behaviour of their own (the security picker retargets the port, the
/// anonymous checkbox hides the credential rows) to be worth reading in one place.
///
/// **The security picker defaults to FTPS**, which is the resolution of PLAN.md §7's open question:
/// plain FTP sends the password in cleartext, so it is a deliberate switch the user flips rather
/// than the path of least resistance — and the note is shown once, right there, instead of nagging
/// on every later connect to a NAS they have used for years.
@MainActor
final class ConnectServerFTPFields {
    let host = ConnectFormFactory.textField(placeholder: "nas.local")
    let port = ConnectFormFactory.textField(placeholder: "21")
    let user = ConnectFormFactory.textField(placeholder: ConnectText.userHint)
    let password = ConnectFormFactory.secureField(placeholder: ConnectText.passwordHint)

    /// FTPS (explicit) | FTPS (implicit) | FTP — a dropdown whose first (and initially selected)
    /// item is the safe choice. The order is the message.
    let securityControl = NSPopUpButton(frame: .zero, pullsDown: false)

    let anonymousCheckbox = NSButton(
        checkboxWithTitle: ConnectText.anonymous,
        target: nil,
        action: nil
    )

    /// The cleartext note. Shown only for plain FTP — a warning that is always on screen is one
    /// nobody reads.
    private let securityNote = ConnectFormFactory.note(ConnectText.plainFTPNote)

    /// The rows shown whenever FTP is the selected protocol (host / port / security / anonymous).
    private var rows: [NSGridRow] = []
    /// The cleartext note; shown only for plain FTP.
    private var noteRow: NSGridRow!
    /// User and password; shown only when *not* anonymous — a public login uses neither.
    private var credentialRows: [NSGridRow] = []
    /// Whether FTP is the currently selected protocol, so the conditional rows stay hidden for the
    /// other two even as the security mode or the anonymous checkbox change.
    private var ftpSelected = false

    /// The field to focus when FTP is the selected protocol.
    var firstResponder: NSView { host }

    // MARK: - Building

    func buildRows(in grid: NSGridView) -> [NSView] {
        // Security leads, directly under the Protocol picker: it sets the port and decides whether the
        // connection is encrypted, so it comes before the host and credentials it governs.
        rows = [
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.security), securityControl])
        ]
        // The cleartext note sits right under Security (plain FTP only), warning about the mode just
        // picked.
        noteRow = grid.addRow(with: [NSGridCell.emptyContentView, securityNote])
        rows.append(grid.addRow(with: [ConnectFormFactory.label(ConnectText.host), host]))
        rows.append(grid.addRow(with: [ConnectFormFactory.label(ConnectText.port), port]))
        // Anonymous sits on its own row between the connection details and the credentials it governs:
        // checking it hides the User and Password rows outright, since a public login uses neither.
        rows.append(grid.addRow(with: [NSGridCell.emptyContentView, anonymousCheckbox]))
        credentialRows = [
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.user), user]),
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.password), password])
        ]

        securityControl.addItems(withTitles: [
            ConnectText.ftpsExplicit, ConnectText.ftpsImplicit, ConnectText.ftpPlain
        ])
        securityControl.selectItem(at: 0)
        securityControl.target = self
        securityControl.action = #selector(securityChanged)
        anonymousCheckbox.target = self
        anonymousCheckbox.action = #selector(anonymousChanged)
        port.stringValue = String(FTPSecurity.explicit.defaultPort)

        // The controls that should span the standard field width.
        //
        // `securityNote` is in this list for a different reason than the rest: a wrapping label with
        // no width constraint takes its *intrinsic single-line* width, so it doesn't wrap — it
        // overruns. The English note happened to fit and the Russian one ran past the sheet's edge,
        // losing its final period (caught only by the live Russian run — docs/NOTES.md). Pinning it
        // to the field width makes it wrap instead, and `reservedSize` measures the FTP layout with
        // the note visible, so the second line is already inside the reserved height.
        return [host, port, securityControl, user, password, securityNote]
    }

    /// Every row this field set owns, for the form's show/hide and its size reservation.
    var allRows: [NSGridRow] { rows + [noteRow] + credentialRows }

    // MARK: - State

    var security: FTPSecurity {
        switch securityControl.indexOfSelectedItem {
        case 1: return .implicit
        case 2: return .plain
        default: return .explicit
        }
    }

    private var isAnonymous: Bool { anonymousCheckbox.state == .on }

    /// Show the always-on FTP rows, then the note and credential rows per their own conditions.
    func setHidden(_ hidden: Bool) {
        ftpSelected = !hidden
        for row in rows { row.isHidden = hidden }
        refreshConditionalRows()
    }

    /// The note (plain FTP only) and the credential rows (non-anonymous only), both gated on FTP
    /// being the selected protocol so they stay hidden for SFTP and SMB.
    private func refreshConditionalRows() {
        noteRow.isHidden = !ftpSelected || security != .plain
        for row in credentialRows { row.isHidden = !ftpSelected || isAnonymous }
    }

    /// Retarget the port when the mode changes, but only when it still holds the *other* mode's
    /// default — a port the user typed is theirs and must survive the switch.
    @objc private func securityChanged() {
        let defaults = Set(FTPSecurity.allCases.map { String($0.defaultPort) })
        if defaults.contains(port.stringValue) || port.stringValue.isEmpty {
            port.stringValue = String(security.defaultPort)
        }
        refreshConditionalRows()
        onLayoutChanged?()
    }

    @objc private func anonymousChanged() {
        syncAnonymousField()
        refreshConditionalRows()
        onLayoutChanged?()
    }

    /// Keep the (now hidden) user field consistent with the checkbox: anonymous fills the well-known
    /// public username and clears any password, and un-checking clears the placeholder name again so
    /// a real one can be typed.
    private func syncAnonymousField() {
        if isAnonymous {
            user.stringValue = FTPLocation.anonymousUsername
            password.stringValue = ""
        } else if user.stringValue == FTPLocation.anonymousUsername {
            user.stringValue = ""
        }
    }

    /// Called when a change alters the layout's height, so the sheet can re-fit.
    var onLayoutChanged: (() -> Void)?

    // MARK: - Prefill

    func apply(location: FTPLocation, authentication: FTPAuthentication) {
        host.stringValue = location.host
        port.stringValue = String(location.port)
        user.stringValue = location.username
        switch location.security {
        case .explicit: securityControl.selectItem(at: 0)
        case .implicit: securityControl.selectItem(at: 1)
        case .plain: securityControl.selectItem(at: 2)
        }
        if case .anonymous = authentication {
            anonymousCheckbox.state = .on
        } else {
            password.stringValue = FTPKeychain.password(for: location) ?? ""
        }
        syncAnonymousField()
    }

    // MARK: - Reading

    /// The validated endpoint and secret, or `nil` when a required field is empty or unusable.
    func readForm(saveName: String?) -> ConnectServerPrompt.Form? {
        let hostValue = ConnectFormFactory.trimmed(host)
        guard ConnectFormFactory.isSafeArgument(hostValue) else { return nil }

        let security = security
        let portValue = Int(ConnectFormFactory.trimmed(port)) ?? security.defaultPort

        if isAnonymous {
            let location = FTPLocation(
                host: hostValue,
                port: portValue,
                username: FTPLocation.anonymousUsername,
                security: security
            )
            return ConnectServerPrompt.Form(
                endpoint: .ftp(location: location, authentication: .anonymous),
                password: nil,
                saveName: saveName
            )
        }

        let userValue = ConnectFormFactory.trimmed(user)
        guard ConnectFormFactory.isSafeArgument(userValue) else { return nil }
        // Passwords aren't trimmed — leading/trailing spaces can be significant — but a blank one is
        // certainly a mistake, so it is rejected rather than sent empty.
        let secretValue = password.stringValue
        guard !secretValue.isEmpty else { return nil }

        let location = FTPLocation(
            host: hostValue,
            port: portValue,
            username: userValue,
            security: security
        )
        return ConnectServerPrompt.Form(
            endpoint: .ftp(location: location, authentication: .password),
            password: secretValue,
            saveName: saveName
        )
    }
}
