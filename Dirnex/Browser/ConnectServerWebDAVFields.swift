import AppKit
import DirnexCore

/// The WebDAV half of the Connect-to-Server form (PLAN.md §M32 Slice 3): security, host or URL,
/// port, the root path, user and password, plus the cleartext note that appears only for plain HTTP.
///
/// **The Host field takes a whole URL.** A WebDAV account is usually handed over as one — Nextcloud
/// prints `https://cloud.example.com/remote.php/dav/files/me/` in its settings — so pasting it and
/// leaving the field spreads it over the security picker, the port, the path and the user
/// (``WebDAVAddress``), and the fields then say exactly what will be dialed. Connect does the same
/// for a URL still in the field, so nothing typed is lost to not having pressed Tab.
///
/// **The security picker defaults to HTTPS**, as FTP's defaults to FTPS: Basic authentication sends
/// the password with every request, so plain HTTP is a deliberate switch with a note. It cannot be
/// refused, because the NAS's own default WebDAV port is plain HTTP.
///
/// **The user may be left blank** for a public share, which is a location without credentials
/// (``WebDAVLocation/hasCredentials``), and the password is then not asked for.
@MainActor
final class ConnectServerWebDAVFields: NSObject, NSTextFieldDelegate {
    let host = ConnectFormFactory.textField(placeholder: "https://nas.local:5006")
    let port = ConnectFormFactory.textField(placeholder: "443")
    let path = ConnectFormFactory.textField(placeholder: "/")
    let user = ConnectFormFactory.textField(placeholder: ConnectText.webDAVUserHint)
    let password = ConnectFormFactory.secureField(placeholder: ConnectText.passwordHint)

    /// HTTPS | HTTP — the safe choice first and selected, as FTP's picker orders its modes.
    let securityControl = NSPopUpButton(frame: .zero, pullsDown: false)

    /// The cleartext note, shown only for plain HTTP.
    private let securityNote = ConnectFormFactory.note(ConnectText.plainHTTPNote)

    /// The rows shown whenever WebDAV is the selected protocol.
    private var rows: [NSGridRow] = []
    /// The cleartext note; shown only for plain HTTP.
    private var noteRow: NSGridRow!
    /// Whether WebDAV is the selected protocol, so the note stays hidden for the others.
    private var webDAVSelected = false

    /// What a prefilled record's connects settled — the scheme and the certificate pin — and the
    /// location they were settled *for*.
    ///
    /// Neither has a row: both are answers the server gave, not fields anyone types. So both are
    /// carried by hand into ``readForm(saveName:)``, or an edit would erase them — which is what a
    /// `_` in a pattern did to FTPS's pin until 2026-08-13 (`ConnectServerFTPFields.trusted`). They
    /// are dropped when the form is pointed at another server, since a pin belongs to one server's
    /// certificate and a mismatched one would raise the changed-certificate alarm for a server that
    /// has merely been edited.
    private var settled: Settled?

    /// One record's settled answers, and the server they belong to.
    private struct Settled {
        let location: WebDAVLocation
        let scheme: WebDAVAuthScheme?
        let publicKey: String?
    }

    /// The field to focus when WebDAV is the selected protocol.
    var firstResponder: NSView { host }

    // MARK: - Building

    func buildRows(in grid: NSGridView) -> [NSView] {
        rows = [grid.addRow(with: [ConnectFormFactory.label(ConnectText.security), securityControl])]
        noteRow = grid.addRow(with: [NSGridCell.emptyContentView, securityNote])
        rows.append(grid.addRow(with: [ConnectFormFactory.label(ConnectText.host), host]))
        rows.append(grid.addRow(with: [ConnectFormFactory.label(ConnectText.port), port]))
        rows.append(grid.addRow(with: [ConnectFormFactory.label(ConnectText.path), path]))
        rows.append(grid.addRow(with: [ConnectFormFactory.label(ConnectText.user), user]))
        rows.append(grid.addRow(with: [ConnectFormFactory.label(ConnectText.password), password]))

        securityControl.addItems(withTitles: ["HTTPS", "HTTP"])
        securityControl.selectItem(at: 0)
        securityControl.target = self
        securityControl.action = #selector(securityChanged)
        port.stringValue = "443"
        path.toolTip = ConnectText.webDAVPathHelp
        host.delegate = self

        // The note is pinned to the field width for the reason `ConnectServerFTPFields` gives: a
        // wrapping label with no width runs past the sheet's edge in a longer language.
        return [host, port, path, user, password, securityControl, securityNote]
    }

    /// Every row this field set owns, for the form's show/hide and its size reservation.
    var allRows: [NSGridRow] { rows + [noteRow] }

    // MARK: - State

    private var usesTLS: Bool { securityControl.indexOfSelectedItem != 1 }

    private static func defaultPort(usesTLS: Bool) -> Int { usesTLS ? 443 : 80 }

    func setHidden(_ hidden: Bool) {
        webDAVSelected = !hidden
        for row in rows { row.isHidden = hidden }
        noteRow.isHidden = !webDAVSelected || usesTLS
    }

    /// Retarget the port when the scheme changes, but only while it still holds the other
    /// scheme's default — a port the user typed (5006) is theirs and survives the switch.
    @objc private func securityChanged() {
        if ["", "443", "80"].contains(ConnectFormFactory.trimmed(port)) {
            port.stringValue = String(Self.defaultPort(usesTLS: usesTLS))
        }
        noteRow.isHidden = !webDAVSelected || usesTLS
        onLayoutChanged?()
    }

    /// Called when a change alters the layout's height, so the sheet can re-fit.
    var onLayoutChanged: (() -> Void)?

    // MARK: - A URL in the Host field

    func controlTextDidEndEditing(_ notification: Notification) {
        guard (notification.object as AnyObject) === host else { return }
        spreadAddress()
    }

    /// Spread whatever the Host field holds beyond a host name over the other fields, leaving the
    /// host alone in it. Fields the text did not mention keep what the user set: `nas:5006` moves
    /// the port and leaves the scheme. A scheme with no port resets the port to that scheme's
    /// default, since `https://nas` says 443 as plainly as it says HTTPS.
    ///
    /// Returns `false` when the text cannot be an address, so Connect can refuse it.
    @discardableResult
    func spreadAddress() -> Bool {
        guard let address = WebDAVAddress.parse(host.stringValue) else { return false }
        guard address.carriesMoreThanHost else { return true }
        host.stringValue = address.host
        if let usesTLS = address.usesTLS {
            securityControl.selectItem(at: usesTLS ? 0 : 1)
            noteRow.isHidden = !webDAVSelected || usesTLS
            port.stringValue = String(address.port ?? Self.defaultPort(usesTLS: usesTLS))
        } else if let explicitPort = address.port {
            port.stringValue = String(explicitPort)
        }
        if let rootPath = address.rootPath { path.stringValue = rootPath.isEmpty ? "/" : rootPath }
        if let username = address.username { user.stringValue = username }
        onLayoutChanged?()
        return true
    }

    // MARK: - Prefill

    func apply(
        location: WebDAVLocation,
        authentication: WebDAVAuthScheme?,
        trustedPublicKey: String?
    ) {
        settled = Settled(location: location, scheme: authentication, publicKey: trustedPublicKey)
        securityControl.selectItem(at: location.usesTLS ? 0 : 1)
        host.stringValue = location.host
        port.stringValue = String(location.port)
        path.stringValue = location.rootPath.isEmpty ? "/" : location.rootPath
        user.stringValue = location.username
        if location.hasCredentials {
            password.stringValue = SecretKeychain.password(for: location) ?? ""
        }
    }

    // MARK: - Reading

    /// The validated endpoint and secret, or `nil` when a required field is empty or unusable.
    func readForm(saveName: String?) -> ConnectServerPrompt.Form? {
        guard spreadAddress() else { return nil }
        let hostValue = ConnectFormFactory.trimmed(host)
        guard !hostValue.isEmpty else { return nil }
        let portValue = Int(ConnectFormFactory.trimmed(port)) ?? Self.defaultPort(usesTLS: usesTLS)
        guard (1...65535).contains(portValue) else { return nil }
        let userValue = ConnectFormFactory.trimmed(user)
        // Passwords aren't trimmed — leading and trailing spaces can be significant — but an account
        // with a blank one is certainly a mistake. A public share has neither.
        let secretValue = password.stringValue
        guard userValue.isEmpty || !secretValue.isEmpty else { return nil }

        let location = WebDAVLocation(
            host: hostValue,
            port: portValue,
            username: userValue,
            usesTLS: usesTLS,
            rootPath: ConnectFormFactory.trimmed(path)
        )
        let kept = settledValues(for: location)
        return ConnectServerPrompt.Form(
            endpoint: .webdav(
                location: location,
                authentication: kept.scheme,
                trustedPublicKey: kept.publicKey
            ),
            password: userValue.isEmpty ? nil : secretValue,
            saveName: saveName
        )
    }

    /// The prefilled scheme and pin, kept only while the form still points at the server they were
    /// settled for — the same scheme, host and port, since each of the three decides which
    /// certificate is presented and which challenge is sent. The user and the root are free to
    /// change: neither moves the server.
    ///
    /// The scheme is dropped with an account that no longer sends credentials, because `nil` is
    /// what a public share's endpoint says.
    private func settledValues(for location: WebDAVLocation) -> (
        scheme: WebDAVAuthScheme?,
        publicKey: String?
    ) {
        guard let settled,
              settled.location.host == location.host,
              settled.location.port == location.port,
              settled.location.usesTLS == location.usesTLS
        else { return (nil, nil) }
        return (location.hasCredentials ? settled.scheme : nil, settled.publicKey)
    }
}
