import AppKit
import DirnexCore

/// Connect-to-Server (PLAN.md §M5 "one place that keeps every saved remote — SFTP and SMB alike",
/// extended by §M13 with FTP). Prompts for a remote server, connects it, and — when named — saves it
/// to the sidebar's Servers section. Three protocols share one entry point:
///
/// - **S3** browses through a `VFSBackend` over the system `curl`, which signs SigV4 itself; its
///   connect and its wrong-region correction live in `PanelViewController+ConnectS3` (§M21). A
///   blank bucket connects to the *account* instead and lists its buckets as rows
///   (`PanelViewController+S3Account`), which is a second root and never the only one.
/// - **SFTP** browses through a `VFSBackend`: a throwaway transport probes the connection (resolving
///   the remote home doubles as an auth/host test), then the same config is registered on the pane's
///   `CompositeBackend` so listings route to it. Password auth feeds `sftp` via `SSH_ASKPASS`.
/// - **FTP / FTPS** browses through a `VFSBackend` too, over the system `curl`; its connect and its
///   certificate-trust prompt live in `PanelViewController+ConnectFTP`.
/// - **SMB** rides the OS mounter: `SMBMounter` mounts the share into `/Volumes/…` and the pane
///   navigates onto the resulting local path, so every M2 op works unchanged.
///
/// One connect *attempt* is an `async` function returning `ConnectServerPrompt.Attempt`. The
/// Connect-to-Server sheet stays open across it and shows a failure inline (so a typo doesn't discard
/// the whole form); a saved server clicked in the sidebar has no sheet and falls back to an error
/// alert. Secrets are filed in the Keychain only after they authenticate, so a typo isn't cached.
extension PanelViewController {
    /// Go ▸ Connect to Server… — open the sheet; on success it connects and, when named, saves.
    @objc func connectToServer(_ sender: Any?) {
        guard let window = view.window else { return }
        ConnectServerPrompt.present(
            over: window,
            attempt: { [weak self] form in await self?.apply(form) ?? .failed(
                Self.genericConnectError
            ) },
            onSucceeded: { [weak self] in self?.focusTable() }
        )
    }

    /// Connect a saved server picked from the sidebar — no prompt when the secret is known. An
    /// authenticated connection whose secret isn't in the Keychain (never saved, or cleared) falls
    /// back to the prefilled prompt so the user can re-enter it, rather than failing silently.
    func connect(to server: ServerConnection) {
        switch server.endpoint {
        case let .sftp(location, authentication):
            if case .password = authentication, SecretKeychain.password(for: location) == nil {
                editServer(server)
                return
            }
            let stored = SecretKeychain.password(for: location)
            runConnect(host: location.host) { [self] in
                await connectSFTP(SFTPConnectRequest(
                    location: location,
                    authentication: authentication,
                    password: stored,
                    saveName: nil,
                    activityName: server.name
                ))
            }
        case let .ftp(location, authentication, trustedPublicKey):
            // A named account whose password was never saved (or has been cleared) falls back to the
            // prefilled sheet rather than failing silently. Anonymous needs no secret at all.
            if case .password = authentication, SecretKeychain.password(for: location) == nil {
                editServer(server)
                return
            }
            let storedFTP = SecretKeychain.password(for: location) ?? ""
            runConnect(host: location.host) { [self] in
                await connectFTP(FTPConnectRequest(
                    location: location,
                    authentication: authentication,
                    password: storedFTP,
                    trustedPublicKey: trustedPublicKey,
                    saveName: nil,
                    activityName: server.name,
                    savedServerName: server.name
                ))
            }
        case let .s3(location):
            // The secret access key is the only way in — there is no anonymous or key-file variant
            // to fall back to — so a saved bucket whose secret was never stored (or has been
            // cleared) opens the prefilled sheet rather than failing.
            guard let secret = SecretKeychain.password(for: location) else {
                editServer(server)
                return
            }
            runConnect(host: location.host) { [self] in
                await connectS3(S3ConnectRequest(
                    location: location,
                    secretAccessKey: secret,
                    saveName: nil,
                    activityName: server.name,
                    // Already saved, so an addressing correction has a record to land in — without
                    // this the next click on this row would re-discover the same failure.
                    savedServerName: server.name
                ))
            }
        case let .s3Account(account):
            // Same rule one level up: an account has no anonymous variant either, so a saved one
            // whose secret is gone opens the prefilled sheet rather than failing.
            guard let secret = SecretKeychain.password(for: account) else {
                editServer(server)
                return
            }
            runConnect(host: account.host) { [self] in
                await connectS3Account(S3AccountConnectRequest(
                    account: account,
                    secretAccessKey: secret,
                    saveName: nil,
                    activityName: server.name
                ))
            }
        case let .smb(location):
            if location.username != nil, SecretKeychain.password(for: location) == nil {
                editServer(server)
                return
            }
            let stored = location.username == nil ? nil : SecretKeychain.password(for: location)
            runConnect(host: location.host) { [self] in
                await mountSMB(
                    location: location, password: stored, saveName: nil, activityName: server.name
                )
            }
        }
    }

    // MARK: - Dispatch

    func apply(_ form: ConnectServerPrompt.Form) async -> ConnectServerPrompt.Attempt {
        switch form.endpoint {
        case let .sftp(location, authentication):
            return await connectSFTP(SFTPConnectRequest(
                location: location,
                authentication: authentication,
                password: form.password,
                saveName: form.saveName,
                activityName: nil
            ))
        case let .ftp(location, authentication, trustedPublicKey):
            return await connectFTP(FTPConnectRequest(
                location: location,
                authentication: authentication,
                password: form.password ?? "",
                trustedPublicKey: trustedPublicKey,
                saveName: form.saveName,
                activityName: nil,
                // The sheet's own `saveName` is the record to write, when there is one — a re-trust
                // reaches the store through the success branch's `saveFTPServer`.
                savedServerName: nil
            ))
        case let .s3(location):
            return await connectS3(S3ConnectRequest(
                location: location,
                secretAccessKey: form.password ?? "",
                saveName: form.saveName,
                activityName: nil,
                // The sheet's own `saveName` is the record to write, when there is one — a corrected
                // addressing mode reaches the store through the success branch's `saveS3Server`.
                savedServerName: nil
            ))
        case let .s3Account(account):
            // The form's bucket field was left blank, which is the answer "browse the account"
            // rather than a field forgotten (`ConnectServerS3Fields.readForm`).
            return await connectS3Account(S3AccountConnectRequest(
                account: account,
                secretAccessKey: form.password ?? "",
                saveName: form.saveName,
                activityName: nil
            ))
        case let .smb(location):
            return await mountSMB(
                location: location, password: form.password, saveName: form.saveName,
                activityName: nil
            )
        }
    }

    /// Run a connect launched from outside the sheet — a saved server clicked in the sidebar, or a
    /// pane gesture that crosses into another backend (entering a bucket from an S3 account pane,
    /// or walking up out of one). There is no sheet to keep open, so success hands focus to the pane
    /// and a failure surfaces the standard error alert.
    func runConnect(
        host: String,
        _ attempt: @escaping () async -> ConnectServerPrompt.Attempt
    ) {
        Task {
            if case let .failed(message) = await attempt() {
                presentOperationFailure(message: connectFailureTitle(host), detail: message)
            } else {
                focusTable()
            }
        }
    }

    // MARK: - SFTP

    /// Everything one SFTP connect attempt needs, bundled so the connect and its host-key-change
    /// retry pass it around as a single value. `activityName` is the sidebar Servers row's name when
    /// the connect was launched from that row (so its busy spinner can be started/stopped), and `nil`
    /// for a one-off Connect to Server… sheet, which has no row to spin.
    private struct SFTPConnectRequest {
        let location: SFTPLocation
        let authentication: SFTPAuthentication
        let password: String?
        let saveName: String?
        let activityName: String?
    }

    private func connectSFTP(_ request: SFTPConnectRequest) async -> ConnectServerPrompt.Attempt {
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

        let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
            do { return .success(try transport.resolveHomeDirectory()) } catch { return .failure(
                error
            ) }
        }.value
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
            navigate(to: VFSPath(backend: .sftp(location), path: home))
            return .succeeded
        case let .failure(error):
            // A changed host key isn't a dead end — offer to re-trust the new key and reconnect,
            // preserving the auth and save name so the retry behaves exactly like the first try.
            if case let .hostKeyChanged(change)? = error as? SFTPTransportError {
                guard await confirmHostKeyChange(location: location, change: change) else {
                    return .failed(Self.connectFailureDetail(error))
                }
                guard await repairKnownHosts(location: location, change: change) else {
                    return .failed(Self.knownHostsRepairFailed(file: change.knownHostsFile))
                }
                return await connectSFTP(request)
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
        case let .failure(message):
            // The server's own words when it said anything; ours when it said nothing, since
            // `classify` leaves the payload empty rather than authoring an untranslatable
            // sentence in the core (PLAN.md §M12 Slice 11).
            return message.isEmpty
                ? String(
                    localized: "The SFTP server reported an error.",
                    comment: "SFTP connect failure detail when the server gave no reason."
                )
                : message
        }
    }

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
    private func confirmHostKeyChange(
        location: SFTPLocation,
        change: SFTPHostKeyChange
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
        return await alert.runSheet(over: view.window) == .alertSecondButtonReturn
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
        let target = SFTPKnownHosts.removalTarget(host: location.host, port: location.port)
        let file = change.knownHostsFile
        return await Task.detached(priority: .userInitiated) {
            SFTPKnownHostsRepair.removeKey(target: target, knownHostsFile: file)
        }.value
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

    // MARK: - SMB

    private func mountSMB(
        location: SMBLocation,
        password: String?,
        saveName: String?,
        activityName: String?
    ) async -> ConnectServerPrompt.Attempt {
        let token = loadToken
        // Mounting an SMB share is async and slow enough to look unresponsive; spin the sidebar row's
        // busy indicator until the mount resolves. `defer` clears it on every exit.
        if let activityName { SidebarRowActivity.shared.begin(activityName) }
        defer { if let activityName { SidebarRowActivity.shared.end(activityName) } }
        do {
            let mountPoint = try await SMBMounter.shared.mount(
                location,
                username: location.username,
                password: password
            )
            guard token == loadToken else { return .succeeded } // the pane moved on while we mounted
            // Persist the password only once the mount succeeded, and only for an authenticated
            // share — a guest mount has no secret to keep.
            if location.username != nil, let password {
                SecretKeychain.store(password: password, for: location)
            }
            if let saveName { saveServer(name: saveName, endpoint: .smb(location)) }
            navigate(to: .local(mountPoint.path))
            return .succeeded
        } catch {
            guard token == loadToken else { return .succeeded }
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failed(detail)
        }
    }

    // MARK: - Shared

    /// `internal` rather than `private` because Swift's `private` does not cross files and the Edit…
    /// half lives in one of its own (docs/NOTES.md ▸ Lint ceilings).
    static var genericConnectError: String {
        String(
            localized: "The connection couldn’t be set up.",
            comment: "Generic server-connect failure with no more specific reason."
        )
    }

    func connectFailureTitle(_ host: String) -> String {
        String(
            localized: "Couldn’t connect to “\(host)”.",
            comment: "Error when a server connection fails; %@ is the host name."
        )
    }

    private func saveServer(name: String, endpoint: ServerEndpoint) {
        var store = ServerConnectionStore.load()
        store.save(ServerConnection(name: name, endpoint: endpoint))
        ServerConnectionStore.save(store)
    }
}
