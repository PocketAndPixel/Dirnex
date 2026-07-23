import AppKit
import DirnexCore

/// Connect-to-Server (PLAN.md §M5 "one place that keeps every saved remote — SFTP and SMB alike").
/// Prompts for a remote server, connects it, and — when named — saves it to the sidebar's Servers
/// section. Two protocols share one entry point:
///
/// - **SFTP** browses through a `VFSBackend`: a throwaway transport probes the connection (resolving
///   the remote home doubles as an auth/host test), then the same config is registered on the pane's
///   `CompositeBackend` so listings route to it. Password auth feeds `sftp` via `SSH_ASKPASS`.
/// - **SMB** rides the OS mounter: `SMBMounter` mounts the share into `/Volumes/…` and the pane
///   navigates onto the resulting local path, so every M2 op works unchanged.
///
/// Secrets are filed in the Keychain only after they authenticate, so a typo isn't cached.
extension PanelViewController {
    /// File ▸ Connect to Server… — open the prompt, connect what the user entered, saving it if named.
    @objc func connectToServer(_ sender: Any?) {
        guard let form = ConnectServerPrompt.run(over: view.window) else { return }
        apply(form)
    }

    /// Connect a saved server picked from the sidebar — no prompt when the secret is known. An
    /// authenticated connection whose secret isn't in the Keychain (never saved, or cleared) falls
    /// back to the prefilled prompt so the user can re-enter it, rather than failing silently.
    func connect(to server: ServerConnection) {
        switch server.endpoint {
        case let .sftp(location, authentication):
            if case .password = authentication {
                guard let stored = SFTPKeychain.password(for: location) else {
                    editServer(server)
                    return
                }
                connectSFTP(SFTPConnectRequest(
                    location: location,
                    authentication: authentication,
                    password: stored,
                    saveName: nil,
                    activityName: server.name
                ))
            } else {
                connectSFTP(SFTPConnectRequest(
                    location: location,
                    authentication: authentication,
                    password: nil,
                    saveName: nil,
                    activityName: server.name
                ))
            }
        case let .smb(location):
            if location.username != nil {
                guard let stored = SMBKeychain.password(for: location) else {
                    editServer(server)
                    return
                }
                mountSMB(
                    location: location,
                    password: stored,
                    saveName: nil,
                    activityName: server.name
                )
            } else {
                mountSMB(location: location, password: nil, saveName: nil, activityName: server.name)
            }
        }
    }

    /// Re-open the connect prompt prefilled from a saved server (the sidebar's "Edit…"). A rename in
    /// the prompt removes the old entry first, so editing updates in place rather than duplicating.
    func editServer(_ server: ServerConnection) {
        guard let form = ConnectServerPrompt.run(over: view.window, prefill: server) else { return }
        if let newName = form.saveName, newName != server.name {
            var store = ServerConnectionStore.load()
            if store.remove(name: server.name) { ServerConnectionStore.save(store) }
        }
        apply(form)
    }

    // MARK: - Dispatch

    private func apply(_ form: ConnectServerPrompt.Form) {
        switch form.endpoint {
        case let .sftp(location, authentication):
            connectSFTP(SFTPConnectRequest(
                location: location,
                authentication: authentication,
                password: form.password,
                saveName: form.saveName,
                activityName: nil
            ))
        case let .smb(location):
            mountSMB(location: location, password: form.password, saveName: form.saveName)
        }
    }

    // MARK: - SFTP

    /// Everything one SFTP connect attempt needs, bundled so the connect and its host-key-change
    /// retry pass it around as a single value. `activityName` is the sidebar Servers row's name when
    /// the connect was launched from that row (so its busy spinner can be started/stopped), and `nil`
    /// for a one-off File ▸ Connect to Server… prompt, which has no row to spin.
    private struct SFTPConnectRequest {
        let location: SFTPLocation
        let authentication: SFTPAuthentication
        let password: String?
        let saveName: String?
        let activityName: String?
    }

    private func connectSFTP(_ request: SFTPConnectRequest) {
        guard let composite = backend as? CompositeBackend else { return }
        let location = request.location
        let authentication = request.authentication
        let password = request.password
        let saveName = request.saveName
        let activityName = request.activityName

        let transport = SFTPProcessTransport(
            location: location,
            authentication: authentication,
            password: password
        )
        let token = loadToken
        // A saved server clicked in the sidebar spins a busy indicator on its row until the probe
        // resolves; `defer` clears it at every exit below (success, the pane moving on, a failure
        // alert, or handing off to the host-key-change retry, which re-marks it).
        if let activityName { ServerConnectionActivity.shared.begin(activityName) }
        Task {
            defer { if let activityName { ServerConnectionActivity.shared.end(activityName) } }
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                do { return .success(try transport.resolveHomeDirectory()) } catch { return .failure(
                    error
                ) }
            }.value
            guard token == loadToken else { return } // the pane moved on while we probed
            switch result {
            case let .success(home):
                // Only persist a password once it actually authenticated, so a typo isn't cached.
                if case .password = authentication, let password {
                    SFTPKeychain.store(password: password, for: location)
                }
                composite.connectSFTP(
                    location: location,
                    authentication: authentication,
                    password: password
                )
                if let saveName {
                    saveServer(
                        name: saveName,
                        endpoint: .sftp(location: location, authentication: authentication)
                    )
                }
                navigate(to: VFSPath(backend: .sftp(location), path: home))
                // Hand keyboard focus to the pane so the freshly connected server is ready to
                // work with immediately — no extra click to activate it first.
                focusTable()
            case let .failure(error):
                // A changed host key isn't a dead end — offer to re-trust the new key and reconnect,
                // preserving the auth and save name so the retry behaves exactly like the first try.
                if case let .hostKeyChanged(change)? = error as? SFTPTransportError {
                    presentHostKeyChangeWarning(location: location, change: change) { [weak self] in
                        self?.repairKnownHostsAndReconnect(request, change: change)
                    }
                    return
                }
                presentOperationFailure(
                    message: String(
                        localized: "Couldn’t connect to “\(location.host)”.",
                        comment: "Error when a server connection fails; %@ is the host name."
                    ),
                    detail: Self.connectFailureDetail(error)
                )
            }
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
            // Reached only if a host-key change surfaces outside the connect probe's re-trust flow.
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

    /// Warn that a host's key no longer matches the one pinned in `known_hosts`, and offer to re-trust
    /// it. Presented as a critical sheet whose default (and rightmost) button is the safe "Cancel", so
    /// re-trusting a changed key — usually a reinstalled server, but possibly a man-in-the-middle — is
    /// always a deliberate click, never the button you hit by reflex. Confirming runs `trust`.
    private func presentHostKeyChangeWarning(
        location: SFTPLocation,
        change: SFTPHostKeyChange,
        trust: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            localized: "The identity of “\(location.host)” has changed",
            comment: "Host-key-change alert title; %@ is the host name."
        )
        alert.informativeText = Self.hostKeyChangeDetail(change)
        // "Cancel" is added first so it's the default (Return / Escape) and rightmost.
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Cancel button."))
        alert.addButton(withTitle: String(
            localized: "Trust New Key & Connect",
            comment: "Host-key-change alert: accept the new key and reconnect."
        ))

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertSecondButtonReturn { trust() }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
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

    /// Drop the stale `known_hosts` pin (via `ssh-keygen -R`) and reconnect. `StrictHostKeyChecking=
    /// accept-new` then pins the server's current key as if it were a fresh host, so the reconnect
    /// verifies cleanly — and password auth, which OpenSSH disables to a *changed*-key host, works
    /// again. Preserves the original save name so a re-trusted connect still lands in the sidebar.
    private func repairKnownHostsAndReconnect(
        _ request: SFTPConnectRequest,
        change: SFTPHostKeyChange
    ) {
        let location = request.location
        let target = SFTPKnownHosts.removalTarget(host: location.host, port: location.port)
        let file = change.knownHostsFile
        Task {
            let removed = await Task.detached(priority: .userInitiated) {
                SFTPKnownHostsRepair.removeKey(target: target, knownHostsFile: file)
            }.value
            guard removed else {
                let path = file.isEmpty ? "~/.ssh/known_hosts" : file
                presentOperationFailure(
                    message: String(
                        localized: "Couldn’t update the known hosts for “\(location.host)”.",
                        comment: "Error when clearing a stale known_hosts entry fails; %@ is the host."
                    ),
                    detail: String(
                        localized: """
                        The old host key couldn’t be removed automatically. Remove it from \(path) \
                        and try connecting again.
                        """,
                        comment: "Known-hosts update failure detail; %@ is the known_hosts file path."
                    )
                )
                return
            }
            connectSFTP(request)
        }
    }

    // MARK: - SMB

    private func mountSMB(
        location: SMBLocation,
        password: String?,
        saveName: String?,
        activityName: String? = nil
    ) {
        let token = loadToken
        // Mounting an SMB share is async and slow enough to look unresponsive; spin the sidebar row's
        // busy indicator until the mount resolves. `defer` clears it on success, failure, or the pane
        // moving on mid-mount.
        if let activityName { ServerConnectionActivity.shared.begin(activityName) }
        Task {
            defer { if let activityName { ServerConnectionActivity.shared.end(activityName) } }
            do {
                let mountPoint = try await SMBMounter.shared.mount(
                    location,
                    username: location.username,
                    password: password
                )
                guard token == loadToken else { return } // the pane moved on while we mounted
                // Persist the password only once the mount succeeded, and only for an authenticated
                // share — a guest mount has no secret to keep.
                if location.username != nil, let password {
                    SMBKeychain.store(password: password, for: location)
                }
                if let saveName { saveServer(name: saveName, endpoint: .smb(location)) }
                navigate(to: .local(mountPoint.path))
                // Hand keyboard focus to the pane so the freshly mounted share is ready to work
                // with immediately — no extra click to activate it first.
                focusTable()
            } catch {
                guard token == loadToken else { return }
                let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                presentOperationFailure(
                    message: String(
                        localized: "Couldn’t connect to “\(location.host)”.",
                        comment: "Error when a server connection fails; %@ is the host name."
                    ),
                    detail: detail
                )
            }
        }
    }

    // MARK: - Saving

    private func saveServer(name: String, endpoint: ServerEndpoint) {
        var store = ServerConnectionStore.load()
        store.save(ServerConnection(name: name, endpoint: endpoint))
        ServerConnectionStore.save(store)
    }
}
