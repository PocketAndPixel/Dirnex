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
/// - **SFTP** browses through a `VFSBackend`: a throwaway transport probes the connection, then the
///   same config is registered on the pane's `CompositeBackend` so listings route to it. Its connect
///   and its changed-host-key prompt live in `PanelViewController+ConnectSFTP`.
/// - **FTP / FTPS** browses through a `VFSBackend` too, over the system `curl`; its connect and its
///   certificate-trust prompt live in `PanelViewController+ConnectFTP`.
/// - **SMB** rides the OS mounter: `SMBMounter` mounts the share into `/Volumes/…` and the pane
///   navigates onto the resulting local path, so every M2 op works unchanged.
///
/// One connect *attempt* is an `async` function returning `ConnectServerPrompt.Attempt`. The
/// Connect-to-Server sheet stays open across it and shows a failure inline (so a typo doesn't discard
/// the whole form); a saved server clicked in the sidebar has no sheet and falls back to an error
/// alert. Secrets are filed in the Keychain only after they authenticate, so a typo isn't cached.
///
/// **Every attempt lands itself**, in its own `navigate` once the connection is up, which is why a
/// sidebar row picked with ⌘ hands its `inNewTab` to the request rather than opening a tab here: the
/// tab then opens only when there is something to show, so a connect that fails, a changed key the
/// user turns down or a sheet they cancel leaves no tab behind. The retries copy the request, and
/// the flag with it.
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
    ///
    /// `inNewTab` (the row picked with ⌘) lands the connection in a new tab, and the prompt carries
    /// it too, so a sheet the user cancels leaves the pane as it was.
    func connect(to server: ServerConnection, inNewTab: Bool = false) {
        guard let request = Self.connectRequest(
            for: server,
            secret: Self.storedSecret(for: server.endpoint),
            inNewTab: inNewTab
        ) else {
            editServer(server, inNewTab: inNewTab)
            return
        }
        runConnect(host: request.host) { [self] in await attempt(request) }
    }

    func apply(
        _ form: ConnectServerPrompt.Form,
        inNewTab: Bool = false
    ) async -> ConnectServerPrompt.Attempt {
        await attempt(Self.connectRequest(for: form, inNewTab: inNewTab))
    }

    // MARK: - Dispatch

    /// One connect attempt, whichever protocol it speaks — what a saved server's row and the sheet
    /// each come down to before anything is dialed.
    enum ServerConnectRequest {
        case sftp(SFTPConnectRequest)
        case ftp(FTPConnectRequest)
        case s3(S3ConnectRequest)
        case s3Account(S3AccountConnectRequest)
        case smb(SMBConnectRequest)

        /// The host a failure alert names.
        var host: String {
            switch self {
            case let .sftp(request): request.location.host
            case let .ftp(request): request.location.host
            case let .s3(request): request.location.host
            case let .s3Account(request): request.account.host
            case let .smb(request): request.location.host
            }
        }
    }

    private func attempt(_ request: ServerConnectRequest) async -> ConnectServerPrompt.Attempt {
        switch request {
        case let .sftp(request): await connectSFTP(request)
        case let .ftp(request): await connectFTP(request)
        case let .s3(request): await connectS3(request)
        case let .s3Account(request): await connectS3Account(request)
        case let .smb(request): await mountSMB(request)
        }
    }

    /// The attempt a saved server's row stands for, given the secret the Keychain holds for it — or
    /// `nil` when it needs one that isn't there, which is the prefilled prompt's cue.
    ///
    /// Pure and `static` so a test can pin, protocol by protocol, which rows fall back to the prompt
    /// and that a ⌘-click's `inNewTab` reaches the attempt. Acting on the attempt dials a server.
    static func connectRequest(
        for server: ServerConnection,
        secret: String?,
        inNewTab: Bool
    ) -> ServerConnectRequest? {
        switch server.endpoint {
        case let .sftp(location, authentication):
            if case .password = authentication, secret == nil { return nil }
            return .sftp(SFTPConnectRequest(
                location: location,
                authentication: authentication,
                password: secret,
                saveName: nil,
                activityName: server.name,
                inNewTab: inNewTab
            ))
        case let .ftp(location, authentication, trustedPublicKey):
            // A named account whose password was never saved (or has been cleared) falls back to the
            // prefilled sheet rather than failing silently. Anonymous needs no secret at all.
            if case .password = authentication, secret == nil { return nil }
            return .ftp(FTPConnectRequest(
                location: location,
                authentication: authentication,
                password: secret ?? "",
                trustedPublicKey: trustedPublicKey,
                saveName: nil,
                activityName: server.name,
                savedServerName: server.name,
                inNewTab: inNewTab
            ))
        case let .s3(location):
            // The secret access key is the only way in — there is no anonymous or key-file variant
            // to fall back to — so a saved bucket whose secret was never stored (or has been
            // cleared) opens the prefilled sheet rather than failing.
            guard let secret else { return nil }
            return .s3(S3ConnectRequest(
                location: location,
                secretAccessKey: secret,
                saveName: nil,
                activityName: server.name,
                // Already saved, so an addressing correction has a record to land in — without
                // this the next click on this row would re-discover the same failure.
                savedServerName: server.name,
                inNewTab: inNewTab
            ))
        case let .s3Account(account):
            // Same rule one level up: an account has no anonymous variant either, so a saved one
            // whose secret is gone opens the prefilled sheet rather than failing.
            guard let secret else { return nil }
            return .s3Account(S3AccountConnectRequest(
                account: account,
                secretAccessKey: secret,
                saveName: nil,
                activityName: server.name,
                inNewTab: inNewTab
            ))
        case let .smb(location):
            // A guest share needs no secret, and is handed none.
            if location.username != nil, secret == nil { return nil }
            return .smb(SMBConnectRequest(
                location: location,
                password: location.username == nil ? nil : secret,
                saveName: nil,
                activityName: server.name,
                inNewTab: inNewTab
            ))
        }
    }

    /// The attempt the Connect sheet's form stands for. `inNewTab` is set only when the sheet is
    /// the fallback of a sidebar row picked with ⌘.
    static func connectRequest(
        for form: ConnectServerPrompt.Form,
        inNewTab: Bool
    ) -> ServerConnectRequest {
        switch form.endpoint {
        case let .sftp(location, authentication):
            .sftp(SFTPConnectRequest(
                location: location,
                authentication: authentication,
                password: form.password,
                saveName: form.saveName,
                activityName: nil,
                inNewTab: inNewTab
            ))
        case let .ftp(location, authentication, trustedPublicKey):
            .ftp(FTPConnectRequest(
                location: location,
                authentication: authentication,
                password: form.password ?? "",
                trustedPublicKey: trustedPublicKey,
                saveName: form.saveName,
                activityName: nil,
                // The sheet's own `saveName` is the record to write, when there is one — a re-trust
                // reaches the store through the success branch's `saveFTPServer`.
                savedServerName: nil,
                inNewTab: inNewTab
            ))
        case let .s3(location):
            .s3(S3ConnectRequest(
                location: location,
                secretAccessKey: form.password ?? "",
                saveName: form.saveName,
                activityName: nil,
                // The sheet's own `saveName` is the record to write, when there is one — a corrected
                // addressing mode reaches the store through the success branch's `saveS3Server`.
                savedServerName: nil,
                inNewTab: inNewTab
            ))
        case let .s3Account(account):
            // The form's bucket field was left blank, which is the answer "browse the account"
            // rather than a field forgotten (`ConnectServerS3Fields.readForm`).
            .s3Account(S3AccountConnectRequest(
                account: account,
                secretAccessKey: form.password ?? "",
                saveName: form.saveName,
                activityName: nil,
                inNewTab: inNewTab
            ))
        case let .smb(location):
            .smb(SMBConnectRequest(
                location: location,
                password: form.password,
                saveName: form.saveName,
                activityName: nil,
                inNewTab: inNewTab
            ))
        }
    }

    /// What the Keychain holds for a saved server, read once. A guest share is not asked: it keeps
    /// no secret, and its location has no user to file one under.
    private static func storedSecret(for endpoint: ServerEndpoint) -> String? {
        switch endpoint {
        case let .sftp(location, _): SecretKeychain.password(for: location)
        case let .ftp(location, _, _): SecretKeychain.password(for: location)
        case let .s3(location): SecretKeychain.password(for: location)
        case let .s3Account(account): SecretKeychain.password(for: account)
        case let .smb(location):
            location.username == nil ? nil : SecretKeychain.password(for: location)
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

    // MARK: - SMB

    /// Everything one SMB mount needs, bundled like `SFTPConnectRequest`.
    struct SMBConnectRequest {
        let location: SMBLocation
        let password: String?
        let saveName: String?
        let activityName: String?
        /// As `SFTPConnectRequest.inNewTab`.
        var inNewTab = false
    }

    private func mountSMB(_ request: SMBConnectRequest) async -> ConnectServerPrompt.Attempt {
        let location = request.location
        let password = request.password
        let activityName = request.activityName
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
            if let saveName = request.saveName {
                saveServer(name: saveName, endpoint: .smb(location))
            }
            navigate(to: .local(mountPoint.path), inNewTab: request.inNewTab)
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

    /// `internal` because the SFTP half, one file over, saves through it too.
    func saveServer(name: String, endpoint: ServerEndpoint) {
        var store = ServerConnectionStore.load()
        store.save(ServerConnection(name: name, endpoint: endpoint))
        ServerConnectionStore.save(store)
    }
}
