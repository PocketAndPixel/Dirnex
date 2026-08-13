import AppKit
import DirnexCore

/// Browsing a whole S3 **account** — the pane whose rows are buckets (PLAN.md §M21 Slice 9).
///
/// **It is a second root, never the only one**, which is what answers the objection this project
/// recorded against account-rooted browsing: a key scoped to one bucket cannot call
/// `ListAllMyBuckets` at all, so an account-rooted design fails for exactly the users whose
/// credentials are set up properly. Everything here is reached by leaving the bucket field blank or
/// by asking to go up, and the bucket-rooted connect the app has shipped since Slice 1 is untouched.
///
/// Three gestures, and each one is a **backend crossing** rather than a path walk — which is why
/// none of them could fall out of the existing navigation:
///
/// - *Connect with no bucket* registers an `S3AccountBackend` and lands the pane on its root.
/// - *Enter a bucket row* is a connect: it builds the `S3Location` for that row and goes through
///   `connectS3`, so the wrong-region correction, the Keychain filing and the certificate sentences
///   all apply exactly as they do from the sheet. Nothing here re-implements them.
/// - *Go up from a bucket root* is the inverse. A bucket root's path is `/`, so there is no parent
///   to find; the place above it is the account that holds it. It **probes before navigating** —
///   one `ListAllMyBuckets` — so a key that cannot list buckets gets a sentence where it is standing
///   instead of a pane it has landed in that can only show an error.
extension PanelViewController {
    /// Everything one account connect attempt needs, bundled like `S3ConnectRequest`.
    struct S3AccountConnectRequest {
        let account: S3Account
        let secretAccessKey: String
        let saveName: String?
        /// The sidebar Servers row's name when the connect was launched from that row (so its busy
        /// spinner can be started and stopped), `nil` for a sheet or a pane gesture.
        let activityName: String?
        /// The row to land the cursor on once the account lists — the bucket we came out of, when
        /// this connect is a walk upwards. `nil` leaves the cursor at the top, which is right for a
        /// connect that is arriving rather than returning.
        var focus: VFSPath?
    }

    // MARK: - Connecting

    func connectS3Account(
        _ request: S3AccountConnectRequest
    ) async -> ConnectServerPrompt.Attempt {
        guard let composite = backend as? CompositeBackend else {
            return .failed(Self.genericS3ConnectError)
        }
        let account = request.account
        let transport = S3AccountCurlTransport(
            account: account,
            secretAccessKey: request.secretAccessKey
        )
        let token = loadToken
        if let activityName = request.activityName {
            SidebarRowActivity.shared.begin(activityName)
        }
        defer {
            if let activityName = request.activityName {
                SidebarRowActivity.shared.end(activityName)
            }
        }

        let result = await Task.detached(priority: .userInitiated) { () -> Result<S3Response, Error> in
            do {
                return .success(try transport.listBuckets(continuationToken: nil))
            } catch {
                return .failure(error)
            }
        }.value
        guard token == loadToken else { return .succeeded } // the pane moved on while we probed

        switch result {
        case let .success(response):
            // The server answered, which is not the same as saying yes: `curl` exits 0 for a key
            // that cannot list buckets exactly as it does for one that can (docs/NOTES.md ▸ curl
            // for S3), so the refusal is read out of the response rather than out of a thrown error.
            if let service = S3Backend.serviceError(from: response) {
                return .failed(Self.s3AccountRefusalDetail(service, account: account))
            }
            // Only persist the secret once it has actually signed something the service accepted,
            // so a typo isn't cached.
            SecretKeychain.store(password: request.secretAccessKey, for: account)
            composite.connectS3Account(
                account: account,
                secretAccessKey: request.secretAccessKey
            )
            if let saveName = request.saveName {
                saveS3Account(name: saveName, account: account)
            }
            navigate(to: VFSPath(backend: .s3Account(account), path: "/"), focus: request.focus)
            return .succeeded
        case let .failure(error):
            return .failed(Self.s3ConnectFailureDetail(
                error,
                // An account request never carries a bucket in the host, so a TLS failure here is
                // about the endpoint the user typed — the path-style advice a bucket connection
                // gives would name a checkbox that could not have caused this.
                certificateDetail: Self.s3EndpointCertificateDetail
            ))
        }
    }

    // MARK: - Entering a bucket

    /// Enter the bucket row under the cursor by **connecting to it**.
    ///
    /// Not a path walk: a bucket is another backend, and the connection to it is the thing that
    /// carries the region, the credential and the addressing mode. Routing through `connectS3` is
    /// what makes the wrong-region correction apply here — a bucket list spans regions while an
    /// account is signed for one, so the row the user pressed Enter on may well not live where the
    /// account does, and the 301 that says so is already handled one file over.
    func enterS3Bucket(named name: String) {
        guard let account = panel.path.backend.s3Account else { return }
        guard let secret = SecretKeychain.password(for: account) else {
            presentOperationFailure(
                message: connectFailureTitle(account.host),
                detail: Self.genericS3ConnectError
            )
            return
        }
        let location = account.bucketLocation(named: name)
        // An addressing correction discovered here belongs to the **account**, not to this bucket:
        // nothing asked for this bucket to be saved, while the account may well be a sidebar row —
        // and it is that row which would otherwise re-discover the same failure on every bucket
        // anyone enters from it. The live account is deliberately left alone: correcting it would
        // change its descriptor, hence its backend id, and pull this pane out from under the listing
        // the user is standing in. Each entry re-pays one failed handshake, which happens below HTTP
        // and is quick.
        let savedAccountName = ServerConnectionStore.load().name(of: .s3Account(account))
        runConnect(host: account.host) { [self] in
            await connectS3(S3ConnectRequest(
                location: location,
                secretAccessKey: secret,
                saveName: nil,
                activityName: nil,
                savedServerName: savedAccountName
            ))
        }
    }

    // MARK: - Leaving a bucket

    /// Whether this pane is standing at a bucket's own root, where "up" means the account rather
    /// than a directory.
    ///
    /// The one place the `..` row is not about the path: every other pane answers this question with
    /// `panel.parentPath`, and a bucket root's path is `/`, which has none. Read by `canGoToParent`
    /// so the row, the Backspace key and the Go menu item all agree — the rule that had three
    /// spellings once already (docs/NOTES.md ▸ AppKit).
    var leavesBucketForItsAccount: Bool {
        panel.path.backend.isS3 && panel.path.isRoot
    }

    /// Walk out of a bucket into the account that holds it, landing the cursor on the bucket we came
    /// from.
    ///
    /// The secret is read back under the **bucket's** Keychain key rather than the account's,
    /// because that is the one a bucket connection files: the user may never have connected to this
    /// account at all, which is the ordinary case for a bucket typed into the sheet.
    func leaveBucketForItsAccount() {
        guard let location = panel.path.backend.s3Location else { return }
        let account = location.account
        guard let secret = SecretKeychain.password(for: location) else {
            presentOperationFailure(
                message: connectFailureTitle(account.host),
                detail: Self.genericS3ConnectError
            )
            return
        }
        runConnect(host: account.host) { [self] in
            await connectS3Account(S3AccountConnectRequest(
                account: account,
                secretAccessKey: secret,
                saveName: nil,
                activityName: nil,
                focus: VFSPath(backend: .s3Account(account), path: "/\(location.bucket)")
            ))
        }
    }

    // MARK: - Errors

    /// What a refused account request says.
    ///
    /// The `<Code>` element separates the two 403s, exactly as it does for a bucket: a key that
    /// authenticated and may not list buckets is a *permission*, while a key the service never
    /// recognized is something the user retypes. They are indistinguishable by status alone
    /// (measured 2026-08-13), and they send the user to completely different places.
    static func s3AccountRefusalDetail(_ service: S3ServiceError, account: S3Account) -> String {
        if service.isCredentialFailure {
            return String(
                localized: "The access key or secret key wasn’t accepted.",
                comment: "S3 connect failure detail: the credentials themselves were rejected."
            )
        }
        guard service.status == 403 else { return Self.s3StatusDetail(service) }
        // Keyed on the status as well as `AccessDenied`, so a server refusing in its own vocabulary
        // still lands on the explanation rather than on an alarming sentence about credentials that
        // are fine. This is the ordinary case, not a fault — a key scoped to one bucket is how these
        // are normally issued — so it names the way forward instead of reporting an error.
        return String(
            localized: """
            That key signed in, but it isn’t allowed to list the buckets on \(account.host). \
            Type a bucket name to connect to just that one.
            """,
            comment: """
            S3 connect failure detail when the key lacks s3:ListAllMyBuckets; %@ is the endpoint. \
            Not a fault: a key scoped to one bucket is the ordinary way these are issued.
            """
        )
    }

    private func saveS3Account(name: String, account: S3Account) {
        var store = ServerConnectionStore.load()
        store.save(ServerConnection(name: name, endpoint: .s3Account(account)))
        ServerConnectionStore.save(store)
    }
}
