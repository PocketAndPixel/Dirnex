import AppKit
import DirnexCore

/// The FTP half of the Connect-to-Server form: host, port, security mode, user (or anonymous) and
/// password, plus the cleartext note that appears only when plain FTP is chosen.
///
/// It is its own object rather than more stored properties on `ConnectServerForm` because that class
/// already sits at SwiftLint's `type_body_length` with two protocols in it; a third would not fit,
/// and the FTP rows have enough behaviour of their own (the security picker retargets the port, the
/// anonymous checkbox disables the credential fields) to be worth reading in one place.
///
/// **The security picker defaults to FTPS**, which is the resolution of PLAN.md §7's open question:
/// plain FTP sends the password in cleartext, so it is a deliberate switch the user flips rather
/// than the path of least resistance — and the note is shown once, right there, instead of nagging
/// on every later connect to a NAS they have used for years.
@MainActor
final class ConnectServerFTPFields {
    let host = ConnectFormFactory.textField(placeholder: "nas.local")
    let port = ConnectFormFactory.textField(placeholder: "21")
    let user = ConnectFormFactory.textField(placeholder: NSUserName())
    let password = ConnectFormFactory.secureField(placeholder: ConnectText.authPassword)

    /// FTPS (explicit) | FTPS (implicit) | FTP — in that order, so the safe choice is first *and*
    /// selected. The order is the message.
    let securityControl = NSSegmentedControl(
        labels: [ConnectText.ftpsExplicit, ConnectText.ftpsImplicit, ConnectText.ftpPlain],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )

    let anonymousCheckbox = NSButton(
        checkboxWithTitle: ConnectText.anonymous,
        target: nil,
        action: nil
    )

    /// The cleartext note. Shown only for plain FTP — a warning that is always on screen is one
    /// nobody reads.
    private let securityNote = ConnectFormFactory.note(ConnectText.plainFTPNote)

    private var rows: [NSGridRow] = []
    private var noteRow: NSGridRow!

    /// The field to focus when FTP is the selected protocol.
    var firstResponder: NSView { host }

    // MARK: - Building

    func buildRows(in grid: NSGridView) -> [NSView] {
        let credentialRow = NSStackView(views: [user, anonymousCheckbox])
        credentialRow.orientation = .horizontal
        credentialRow.spacing = 8
        credentialRow.translatesAutoresizingMaskIntoConstraints = false

        rows = [
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.host), host]),
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.port), port]),
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.security), securityControl])
        ]
        noteRow = grid.addRow(with: [NSGridCell.emptyContentView, securityNote])
        rows += [
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.user), credentialRow]),
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.password), password])
        ]

        securityControl.selectedSegment = 0
        securityControl.target = self
        securityControl.action = #selector(securityChanged)
        anonymousCheckbox.target = self
        anonymousCheckbox.action = #selector(anonymousChanged)
        port.stringValue = String(FTPSecurity.explicit.defaultPort)

        // The controls that should span the standard field width. The credential row carries the
        // user field plus its checkbox, so it is sized instead of the bare field.
        //
        // `securityNote` is in this list for a different reason than the rest: a wrapping label with
        // no width constraint takes its *intrinsic single-line* width, so it doesn't wrap — it
        // overruns. The English note happened to fit and the Russian one ran past the sheet's edge,
        // losing its final period (caught only by the live Russian run — docs/NOTES.md). Pinning it
        // to the field width makes it wrap instead, and `reservedSize` measures the FTP layout with
        // the note visible, so the second line is already inside the reserved height.
        return [host, port, securityControl, credentialRow, password, securityNote]
    }

    /// Every row this field set owns, for the form's show/hide and its size reservation.
    var allRows: [NSGridRow] { rows + [noteRow] }

    // MARK: - State

    var security: FTPSecurity {
        switch securityControl.selectedSegment {
        case 1: return .implicit
        case 2: return .plain
        default: return .explicit
        }
    }

    private var isAnonymous: Bool { anonymousCheckbox.state == .on }

    /// Show the rows, with the cleartext note visible only for plain FTP.
    func setHidden(_ hidden: Bool) {
        for row in rows { row.isHidden = hidden }
        noteRow.isHidden = hidden || security != .plain
        updateCredentialFields()
    }

    /// Retarget the port when the mode changes, but only when it still holds the *other* mode's
    /// default — a port the user typed is theirs and must survive the switch.
    @objc private func securityChanged() {
        let defaults = Set(FTPSecurity.allCases.map { String($0.defaultPort) })
        if defaults.contains(port.stringValue) || port.stringValue.isEmpty {
            port.stringValue = String(security.defaultPort)
        }
        noteRow.isHidden = security != .plain
        onLayoutChanged?()
    }

    @objc private func anonymousChanged() {
        updateCredentialFields()
    }

    /// Anonymous needs no credentials, so the two fields go dim rather than merely ignored — a
    /// disabled field says "this isn't used" where an ignored one invites typing into it.
    private func updateCredentialFields() {
        user.isEnabled = !isAnonymous
        password.isEnabled = !isAnonymous
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
        case .explicit: securityControl.selectedSegment = 0
        case .implicit: securityControl.selectedSegment = 1
        case .plain: securityControl.selectedSegment = 2
        }
        if case .anonymous = authentication {
            anonymousCheckbox.state = .on
        } else {
            password.stringValue = FTPKeychain.password(for: location) ?? ""
        }
        updateCredentialFields()
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
