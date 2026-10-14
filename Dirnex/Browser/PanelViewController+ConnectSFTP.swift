import AppKit
import DirnexCore

/// The SFTP half of Connect-to-Server (PLAN.md §M5), split from `PanelViewController+Connect` when
/// that file reached SwiftLint's `file_length`, along the line the FTP and S3 halves already drew:
/// each protocol's connect, its failure sentences and its trust question live together, and the
/// file they left keeps what every protocol shares — the dispatch from a sidebar row or the sheet,
/// and the landing.
///
/// A throwaway transport probes the connection (resolving the remote home doubles as an auth and
/// host test), then the same config is registered on the pane's `CompositeBackend` so listings
/// route to it. Password auth feeds `sftp` via `SSH_ASKPASS`. A changed host key is not a dead end:
/// the user is shown the new fingerprint and, on their explicit acceptance, the stale `known_hosts`
/// pin is removed and the connect retried.
extension PanelViewController {
    /// Everything one SFTP connect attempt needs, bundled so the connect and its host-key-change
    /// retry pass it around as a single value. `activityName` is the sidebar Servers row's name when
    /// the connect was launched from that row (so its busy spinner can be started/stopped), and `nil`
    /// for a one-off Connect to Server… sheet, which has no row to spin.
    struct SFTPConnectRequest {
        let location: SFTPLocation
        let authentication: SFTPAuthentication
        let password: String?
        let saveName: String?
        let activityName: String?
        /// Whether the connection lands in a new tab: a saved server picked with ⌘, or the prompt
        /// that row fell back to. Carried to the landing rather than acted on up front, so the tab
        /// opens only once there is something to show; the host-key retry copies the request, which
        /// is what keeps it.
        var inNewTab = false
        /// Whether a changed host key has already been put to the user in this attempt. The branch
        /// retries once the stale pin is removed, so a refusal that outlives the removal — a pin the
        /// repair could not reach — would otherwise raise the same question for as long as the user
        /// kept accepting it. The FTPS twin is `FTPConnectRequest.hasWeighedCertificate`.
        var hasWeighedHostKey = false
    }

    func connectSFTP(_ request: SFTPConnectRequest) async -> ConnectServerPrompt.Attempt {
        guard let composite = backend as? CompositeBackend else { return .failed(
            Self.genericConnectError
        ) }
        let location = request.location
        let authentication = request.authentication
        let password = request.password
        let transport = SFTPProcessTransport(
            location: location,
            authentication: authentication,
            password: password
        )
        let token = loadToken
        // A saved server clicked in the sidebar spins a busy indicator on its row until the probe
        // resolves; `defer` clears it at every exit below.
        if let activityName = request.activityName { SidebarRowActivity.shared.begin(
            activityName
        ) }
        defer { if let activityName = request.activityName { SidebarRowActivity.shared.end(
            activityName
        ) } }

        let result = await BlockingWork.run { () -> Result<String, Error> in
            do { return .success(try transport.resolveHomeDirectory()) } catch { return .failure(
                error
            ) }
        }
        guard token == loadToken else { return .succeeded } // the pane moved on while we probed

        switch result {
        case let .success(home):
            // Only persist a password once it actually authenticated, so a typo isn't cached.
            if case .password = authentication, let password {
                SecretKeychain.store(password: password, for: location)
            }
            composite.connectSFTP(
                location: location,
                authentication: authentication,
                password: password
            )
            if let saveName = request.saveName {
                saveServer(
                    name: saveName,
                    endpoint: .sftp(location: location, authentication: authentication)
                )
            }
            navigate(to: VFSPath(backend: .sftp(location), path: home), inNewTab: request.inNewTab)
            return .succeeded
        case let .failure(error):
            // A changed host key isn't a dead end — offer to re-trust the new key and reconnect,
            // preserving the auth and save name so the retry behaves exactly like the first try.
            if case let .hostKeyChanged(change)? = error as? SFTPTransportError {
                // One question per connect: a refusal that survives the repair is reported, since
                // asking again could only loop.
                guard !request.hasWeighedHostKey else {
                    return .failed(Self.knownHostsRepairFailed(file: change.knownHostsFile))
                }
                guard await Self.confirmHostKeyChange(
                    location: location, change: change, over: view.window
                ) else {
                    return .failed(Self.connectFailureDetail(error))
                }
                guard await repairKnownHosts(location: location, change: change) else {
                    return .failed(Self.knownHostsRepairFailed(file: change.knownHostsFile))
                }
                var retry = request
                retry.hasWeighedHostKey = true
                return await connectSFTP(retry)
            }
            return .failed(Self.connectFailureDetail(error))
        }
    }

    /// A human-readable reason for a failed connect, mapped from the transport's error vocabulary.
    private static func connectFailureDetail(_ error: Error) -> String {
        guard let transportError = error as? SFTPTransportError else {
            return (error as NSError).localizedDescription
        }
        switch transportError {
        case .notFound:
            return String(
                localized: "The remote path wasn’t found.",
                comment: "SFTP connect failure detail: the remote path does not exist."
            )
        case .permissionDenied:
            return String(
                localized: "Permission denied. Check the username and that the key is authorized on the server.",
                comment: "SFTP connect failure detail: authentication was rejected."
            )
        case let .hostKeyChanged(change):
            // Reached when the user declined to re-trust a changed host key.
            return String(
                localized: "The server’s host key has changed (new fingerprint \(change.fingerprint)).",
                comment: "SFTP connect failure detail; %@ is the new host-key fingerprint."
            )
        case .copyExtensionUnavailable:
            // Unreachable from a connect, and answered rather than asserted: only `cp` produces it
            // and the probe here is a `pwd`. It gets the same generic sentence an empty failure
            // does, because a wording of its own would put a string no user can reach in front of
            // fourteen translators.
            return Self.unexplainedServerError
        case let .failure(message):
            // The server's own words when it said anything; ours when it said nothing, since
            // `classify` leaves the payload empty rather than authoring an untranslatable
            // sentence in the core (PLAN.md §M12 Slice 11).
            return message.isEmpty ? Self.unexplainedServerError : message
        }
    }

    /// What a connect failure says when the server gave no reason of its own. One constant because
    /// two sites need it and `String(localized:comment:)` takes a `StaticString`, so a shared comment
    /// would have to be repeated verbatim to key the same entry (docs/NOTES.md ▸ Localization).
    private static let unexplainedServerError = String(
        localized: "The SFTP server reported an error.",
        comment: "SFTP connect failure detail when the server gave no reason."
    )

    // MARK: - Host key changed

    /// Warn that a host's key no longer matches the one pinned in `known_hosts`, and ask whether to
    /// re-trust it. A critical alert whose default and rightmost button is the safe "Cancel", so
    /// re-trusting a changed key — usually a reinstalled server, but possibly a man-in-the-middle —
    /// is always a deliberate click. Returns `true` when the user chose to trust the new key.
    ///
    /// Presented on `NSAlert.sheetHost`: the Connect sheet when the connect came from there, the
    /// browser window when it came from the sidebar. It used to be `runModal()`, which lands in the
    /// center of the *display* rather than the app — the sheet host is what makes attaching it
    /// possible without queueing it invisibly behind the Connect sheet (see `AlertSheet`).
    ///
    /// Cancel also starts with the keyboard focus, because Space presses the focused button, and that
    /// has to be arranged once the alert is up (``NSAlert/focusFirstButton()`` says why). Static and
    /// internal so a test can present it over a bare window: a live pane in a window upsets
    /// `PanelPassiveRefreshTests` (docs/NOTES.md).
    static func confirmHostKeyChange(
        location: SFTPLocation,
        change: SFTPHostKeyChange,
        over window: NSWindow?
    ) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            localized: "The identity of “\(location.host)” has changed",
            // Shared verbatim with the FTPS changed-certificate alert, which asks the same question
            // about a TLS key. `String(localized:comment:)` takes a `StaticString`, so a shared
            // comment cannot be hoisted and two spellings would hand the translator whichever one
            // `xcstringstool` kept (docs/NOTES.md).
            comment: "Alert title when a server’s identity (host key or TLS certificate) changed; %@ is the host."
        )
        alert.informativeText = Self.hostKeyChangeDetail(change)
        // "Cancel" is added first so it's the rightmost and answers Escape. AppKit gives it Escape
        // only in English — it matches the literal string "Cancel" — so name it, or a translated
        // build leaves this alert with no way out (docs/NOTES.md).
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Cancel button."))
        alert.addButton(withTitle: String(
            localized: "Trust New Key & Connect",
            comment: "Host-key-change alert: accept the new key and reconnect."
        ))
        alert.enableEscapeToCancel(safe: .alertFirstButtonReturn)
        return await alert.runSheet(over: window) { alert.focusFirstButton() }
            == .alertSecondButtonReturn
    }

    private static func hostKeyChangeDetail(_ change: SFTPHostKeyChange) -> String {
        // "key" vs. "RSA key" is composed as its own unit so the surrounding sentence stays one
        // localizable literal and Russian can reorder "%@ key" → "ключ %@" (docs/NOTES.md).
        let keyLabel = change.keyType.isEmpty
            ? String(
                localized: "key",
                comment: "Host-key-change body: generic word for the host key."
            )
            : String(
                localized: "\(change.keyType) key",
                comment: "Host-key-change body; %@ is the key type, e.g. RSA."
            )
        let fingerprint = change.fingerprint.isEmpty
            ? String(
                localized: "(unavailable)",
                comment: "Shown in place of a host-key fingerprint that couldn’t be read."
            )
            : change.fingerprint
        return String(
            localized: """
            This server is presenting a different host \(keyLabel) than the one you trusted before. \
            If you reinstalled the server or pointed a new SFTP app at this address, this is expected — \
            but it can also mean someone is intercepting the connection (a man-in-the-middle attack).

            New fingerprint:
            \(fingerprint)

            Only continue if you recognize this fingerprint. Trusting it replaces the old key so future \
            connections to this server succeed.
            """,
            comment: "Host-key-change alert body; %1$@ is the key label, %2$@ the fingerprint."
        )
    }

    /// Drop the stale `known_hosts` pin (via `ssh-keygen -R`) so the reconnect pins the server's
    /// current key as if it were a fresh host. Returns `false` when the old key couldn't be removed.
    private func repairKnownHosts(location: SFTPLocation, change: SFTPHostKeyChange) async -> Bool {
        // The name OpenSSH refused on, not the location's: a saved `nas` is dialed as `nas.local`, and
        // removing `nas` removes nothing while `ssh-keygen` still exits 0.
        let target = SFTPKnownHosts.removalTarget(
            for: change,
            host: location.host,
            port: location.port
        )
        let file = change.knownHostsFile
        return await BlockingWork.run {
            SFTPKnownHostsRepair.removeKey(target: target, knownHostsFile: file)
        }
    }

    private static func knownHostsRepairFailed(file: String) -> String {
        let path = file.isEmpty ? "~/.ssh/known_hosts" : file
        return String(
            localized: """
            The old host key couldn’t be removed automatically. Remove it from \(path) and try \
            connecting again.
            """,
            comment: "Known-hosts update failure detail; %@ is the known_hosts file path."
        )
    }
}
