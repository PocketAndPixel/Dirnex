import AppKit
import DirnexCore

/// The FTP/FTPS half of Connect-to-Server (PLAN.md §M13), in its own file so
/// `PanelViewController+Connect` stays under the length ceiling. It mirrors the SFTP path exactly —
/// probe on a throwaway transport, register the connection on the pane's `CompositeBackend`, file
/// the password only once it has authenticated, navigate — with one addition the protocol forces:
///
/// **The certificate-trust decision.** A self-signed certificate is the norm on NAS firmware, and
/// `--cacert` cannot be used to accept one (measured: it still fails the host-name check, because a
/// NAS certificate names itself, not the address the user typed). So an untrusted certificate is not
/// a dead end: the user is shown its fingerprint, and on their explicit acceptance the **public key**
/// is pinned for that server and the connect retried. This is the same shape as the SFTP host-key
/// flow, and never a blanket "don't verify" — `curl` refuses a key that doesn't match the pin before
/// any data moves.
///
/// **A stored pin that stops matching gets the same treatment**, which is the other half of that
/// mirror and shipped later than it should have: the flow was gated on `certificateUntrusted`
/// alone, so once a pin existed a changed key was an informational alert telling the user to delete
/// their saved server — advice that loses the record and gives them nothing to compare, for what a
/// certificate renewal produces routinely (pinning a key survives a reissue only when the server
/// reuses the key, and most renewals do not). It now fetches the new certificate, shows it under
/// changed-key wording, and on acceptance re-pins **and writes that back into the saved server**,
/// the way SFTP repairs `known_hosts`.
extension PanelViewController {
    /// Everything one FTP connect attempt needs, bundled so the connect and its trust retry pass it
    /// around as a single value — the shape `SFTPConnectRequest` already established. `activityName`
    /// is the sidebar row's name when the connect came from that row, `nil` for the sheet.
    struct FTPConnectRequest {
        let location: FTPLocation
        let authentication: FTPAuthentication
        let password: String
        var trustedPublicKey: String?
        let saveName: String?
        let activityName: String?
        /// The saved server this connect came from, when it came from one — the record a re-trusted
        /// certificate has to be written back into. Distinct from `saveName`, which means "save
        /// under this name on success" and is `nil` for a sidebar connect precisely because the
        /// server is *already* saved; without this the new pin would have nowhere to go and the
        /// next click on the same row would present the old one again.
        let savedServerName: String?
        /// Whether a certificate has already been put to the user in this attempt. One decision per
        /// connect: the changed-certificate branch retries, so without this a server that keeps
        /// answering with a key that doesn't match the one just accepted — a load balancer serving
        /// the probe and the connect from two different machines — would raise the same question
        /// forever.
        var hasWeighedCertificate = false
    }

    func connectFTP(_ request: FTPConnectRequest) async -> ConnectServerPrompt.Attempt {
        guard let composite = backend as? CompositeBackend else {
            return .failed(Self.genericFTPConnectError)
        }
        let location = request.location
        let transport = FTPCurlTransport(
            location: location,
            authentication: request.authentication,
            password: request.password,
            trustedPublicKey: request.trustedPublicKey
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

        let result = await BlockingWork.run { () -> Result<Void, Error> in
            do { return .success(try transport.probeConnection()) } catch { return .failure(error) }
        }
        guard token == loadToken else { return .succeeded } // the pane moved on while we probed

        switch result {
        case .success:
            // Only persist a password once it actually authenticated, so a typo isn't cached.
            if case .password = request.authentication, !request.password.isEmpty {
                SecretKeychain.store(password: request.password, for: location)
            }
            composite.connectFTP(
                location: location,
                authentication: request.authentication,
                password: request.password,
                trustedPublicKey: request.trustedPublicKey
            )
            if let saveName = request.saveName {
                saveFTPServer(name: saveName, request: request)
            } else if let savedName = request.savedServerName {
                repinSavedFTPServer(name: savedName, request: request)
            }
            navigate(to: VFSPath(backend: .ftp(location), path: "/"))
            return .succeeded
        case let .failure(error):
            return await handleFTPFailure(error, request: request)
        }
    }

    /// A certificate the user has not weighed yet is recoverable, whether this is the first sight of
    /// it or a key that has stopped matching the stored pin — fetch it, show the user its
    /// fingerprint, and pin it on their explicit acceptance. Everything else is reported.
    private func handleFTPFailure(
        _ error: Error,
        request: FTPConnectRequest
    ) async -> ConnectServerPrompt.Attempt {
        switch error as? FTPTransportError {
        case .certificateUntrusted:
            return await weighCertificate(request: request, changed: false, error: error)
        case .certificateChanged:
            return await weighCertificate(request: request, changed: true, error: error)
        default:
            return .failed(Self.ftpConnectFailureDetail(error))
        }
    }

    /// Put the server's certificate to the user and, on acceptance, pin it and retry.
    ///
    /// `changed` is what separates the two questions this answers, and they are genuinely different
    /// ones: first contact with a self-signed certificate is *expected* on a NAS, while a key that
    /// no longer matches a stored pin is the FTPS analogue of SSH's changed-host-key refusal —
    /// usually a reissued certificate (pinning the key survives a renewal only when the server
    /// reuses it, which corporate PKI and ACME renewals typically do not), but possibly an
    /// interception. So the wording differs and the decision is always the user's; what does *not*
    /// differ is that declining leaves the old pin standing and nothing is written.
    private func weighCertificate(
        request: FTPConnectRequest,
        changed: Bool,
        error: Error
    ) async -> ConnectServerPrompt.Attempt {
        guard !request.hasWeighedCertificate else {
            return .failed(Self.certificateStillMismatched)
        }
        guard let certificate = await fetchFTPCertificate(for: request) else {
            return .failed(Self.ftpConnectFailureDetail(error))
        }
        guard let pin = certificate.publicKeyPin else {
            // A certificate whose key can't be read cannot be pinned, and connecting without a pin
            // would mean connecting unverified — which is the one thing this flow must never do.
            return .failed(Self.unreadableCertificate)
        }
        let accepted = changed
            ? await confirmCertificateChange(location: request.location, certificate: certificate)
            : await confirmCertificateTrust(location: request.location, certificate: certificate)
        guard accepted else {
            return .failed(changed ? Self.certificateChangeNotTrusted : Self.certificateNotTrusted)
        }
        var retry = request
        retry.trustedPublicKey = pin
        retry.hasWeighedCertificate = true
        return await connectFTP(retry)
    }

    /// Fetch the server's certificate without trusting it, so the prompt can show what it is asking
    /// the user to accept. Transfers nothing.
    private func fetchFTPCertificate(for request: FTPConnectRequest) async -> FTPCertificate? {
        let transport = FTPCurlTransport(
            location: request.location,
            authentication: request.authentication,
            password: request.password
        )
        return await BlockingWork.run { () -> FTPCertificate? in
            try? transport.fetchCertificate()
        }
    }

    // MARK: - Trust prompt

    /// Show the certificate's fingerprint and ask whether to trust this server's key from now on.
    /// Presented as a critical alert whose default and rightmost button is the safe "Cancel", so
    /// pinning is always a deliberate click — the same treatment the SFTP host-key change gets.
    ///
    /// A sheet on `NSAlert.sheetHost`, which is the Connect sheet itself when the connect came from
    /// there and the browser window when it came from the sidebar. It used to be `runModal()`,
    /// which puts it in the middle of the *display* rather than the app.
    private func confirmCertificateTrust(
        location: FTPLocation,
        certificate: FTPCertificate
    ) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            localized: "Can’t verify the identity of “\(location.host)”",
            comment: "FTPS certificate-trust alert title; %@ is the host name."
        )
        alert.informativeText = Self.certificateDetail(
            certificate,
            explanation: String(
                localized: """
                The server presented a certificate that isn’t signed by a trusted authority. This \
                is normal for a NAS or a home server, but it can also mean someone is intercepting \
                the connection.

                Compare this fingerprint with the one shown on the server before trusting it.
                """,
                comment: "FTPS certificate-trust alert body, above the certificate's details."
            )
        )
        // "Cancel" is added first so it is the rightmost and answers Escape. AppKit only binds
        // Escape by matching the literal English "Cancel", so a translated build needs the explicit
        // `enableEscapeToCancel(safe:)` or the alert has no way out (docs/NOTES.md).
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Cancel button."))
        alert.addButton(withTitle: String(
            localized: "Trust & Connect",
            comment: "FTPS certificate-trust alert: pin this certificate and connect."
        ))
        alert.enableEscapeToCancel(safe: .alertFirstButtonReturn)
        return await alert.runSheet(over: view.window) == .alertSecondButtonReturn
    }

    /// Warn that a server's key no longer matches the pin stored for it, and ask whether to re-trust
    /// it — the FTPS twin of `confirmHostKeyChange`, down to the safe rightmost Cancel, so replacing
    /// a pin is always a deliberate click. Returns `true` when the user chose to trust the new
    /// certificate.
    private func confirmCertificateChange(
        location: FTPLocation,
        certificate: FTPCertificate
    ) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            localized: "The identity of “\(location.host)” has changed",
            // Verbatim the SFTP host-key alert's comment, and deliberately the same string: the two
            // ask the same question about the same server, so they read the same and share one
            // translation (docs/NOTES.md — a shared comment cannot be hoisted into a constant).
            comment: "Alert title when a server’s identity (host key or TLS certificate) changed; %@ is the host."
        )
        alert.informativeText = Self.certificateDetail(
            certificate,
            explanation: String(
                localized: """
                This server is presenting a different certificate than the one you trusted before. \
                If it was reissued — a renewal usually generates a new key — this is expected, but \
                it can also mean someone is intercepting the connection (a man-in-the-middle \
                attack).

                Only continue if you recognize this fingerprint. Trusting it replaces the old one \
                so future connections to this server succeed.
                """,
                comment: "FTPS changed-certificate alert body, above the certificate's details."
            )
        )
        // Rightmost and bound to Escape, for the reason spelled out in `confirmCertificateTrust`.
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Cancel button."))
        alert.addButton(withTitle: String(
            localized: "Trust New Certificate & Connect",
            comment: "FTPS changed-certificate alert: replace the stored pin and connect."
        ))
        alert.enableEscapeToCancel(safe: .alertFirstButtonReturn)
        return await alert.runSheet(over: view.window) == .alertSecondButtonReturn
    }

    /// The body of a trust alert: `explanation`, then what the certificate claims, how long it is
    /// valid, and the fingerprint to compare against the server. The fingerprint is the
    /// *certificate's* SHA-256 — the value every other tool shows, so a user can check it against
    /// their NAS's admin page — while what actually gets pinned is the public key inside it.
    private static func certificateDetail(
        _ certificate: FTPCertificate,
        explanation: String
    ) -> String {
        let fingerprint = certificate.fingerprintLines(groupsPerLine: 8).joined(separator: "\n")
        let details = String(
            localized: """
            Issued to: \(certificate.subject)
            Issued by: \(certificate.issuer)
            Expires: \(certificate.notAfter)

            SHA-256 fingerprint:
            \(fingerprint)
            """,
            comment: """
            FTPS certificate details in the trust alert: subject, issuer, expiry, and the SHA-256 \
            fingerprint. The arguments are the certificate's own fields.
            """
        )
        return "\(explanation)\n\n\(details)"
    }

    // MARK: - Errors

    private static var genericFTPConnectError: String {
        String(
            localized: "The connection couldn’t be set up.",
            comment: "Generic server-connect failure with no more specific reason."
        )
    }

    private static var certificateNotTrusted: String {
        String(
            localized: "The server’s certificate wasn’t trusted, so the connection was canceled.",
            comment: "FTP connect failure detail: the user declined to trust the certificate."
        )
    }

    private static var certificateChangeNotTrusted: String {
        String(
            localized: """
            The server’s certificate has changed and wasn’t trusted, so the connection was \
            canceled. The certificate you trusted before is still the one Dirnex expects.
            """,
            comment: "FTP connect failure detail: the user declined to re-trust a changed certificate."
        )
    }

    /// Reached only when a certificate the user has *just* accepted still doesn't satisfy the pin —
    /// the one state in which asking again would be a loop rather than a question.
    private static var certificateStillMismatched: String {
        String(
            localized: """
            The server is still presenting a certificate that doesn’t match the one you just \
            trusted. It may be answering from more than one machine.
            """,
            comment: "FTP connect failure detail: the pin accepted moments ago already doesn’t match."
        )
    }

    private static var unreadableCertificate: String {
        String(
            localized: "The server’s certificate couldn’t be read, so it can’t be trusted safely.",
            comment: "FTP connect failure detail: the certificate's public key could not be parsed."
        )
    }

    /// A human-readable reason for a failed FTP connect, mapped from the transport's vocabulary.
    static func ftpConnectFailureDetail(_ error: Error) -> String {
        guard let transportError = error as? FTPTransportError else {
            return (error as NSError).localizedDescription
        }
        switch transportError {
        case .notFound:
            return String(
                localized: "The remote path wasn’t found.",
                comment: "FTP connect failure detail: the remote path does not exist."
            )
        case .permissionDenied:
            return String(
                localized: "The server refused access to that path.",
                comment: "FTP connect failure detail: the account may not use the path."
            )
        case .loginDenied:
            return String(
                localized: "Login failed. Check the user name and password.",
                comment: "FTP connect failure detail: authentication was rejected."
            )
        case .tlsRequired:
            return String(
                localized: """
                This server requires an encrypted connection. Choose FTPS (explicit or implicit) \
                instead of plain FTP.
                """,
                comment: "FTP connect failure detail: the server requires TLS and refused a plain login."
            )
        case .tlsNotAvailable:
            return String(
                localized: """
                This server doesn’t offer encryption on this port. Choose plain FTP, or connect on \
                the port that provides FTPS.
                """,
                comment: "FTP connect failure detail: explicit FTPS asked for but no TLS on this port."
            )
        case .certificateUntrusted:
            return String(
                localized: "The server’s certificate couldn’t be verified.",
                comment: "FTP connect failure detail: TLS certificate verification failed."
            )
        case .certificateChanged:
            return String(
                localized: """
                The server is presenting a different certificate than the one you trusted, and the \
                new one couldn’t be read to show you.
                """,
                comment: """
                FTP connect failure detail: the pin no longer matches and the new certificate \
                could not be fetched to weigh.
                """
            )
        case .unreachable:
            return String(
                localized: "The server couldn’t be reached. Check the host name and port.",
                comment: "FTP connect failure detail: the host could not be resolved or connected."
            )
        case .timedOut:
            return String(
                localized: "The server stopped responding.",
                comment: "FTP connect failure detail: the operation exceeded its time budget."
            )
        case let .failure(message):
            // `curl`'s own words when it said anything; ours when it said nothing, since `classify`
            // leaves the payload empty rather than authoring an untranslatable sentence in the core
            // (PLAN.md §M12 Slice 11).
            return message.isEmpty
                ? String(
                    localized: "The FTP server reported an error.",
                    comment: "FTP connect failure detail when the server gave no reason."
                )
                : message
        }
    }

    /// Write a re-trusted certificate's pin back into the saved server it came from, so the next
    /// connect from that row presents the key the user just accepted rather than the old one.
    ///
    /// Only the pin is rewritten, and only when it actually differs: the record is reloaded and
    /// matched by name at this moment rather than carried through the connect, so a rename or an
    /// edit made while the connection was being weighed is not clobbered by a stale copy. A record
    /// that has since been deleted is simply not recreated — the connection stays live for this
    /// session, which is what the user asked for, and nothing is resurrected in the sidebar.
    private func repinSavedFTPServer(name: String, request: FTPConnectRequest) {
        var store = ServerConnectionStore.load()
        guard store.repinFTP(name: name, trustedPublicKey: request.trustedPublicKey) else { return }
        ServerConnectionStore.save(store)
    }

    private func saveFTPServer(name: String, request: FTPConnectRequest) {
        var store = ServerConnectionStore.load()
        store.save(ServerConnection(
            name: name,
            endpoint: .ftp(
                location: request.location,
                authentication: request.authentication,
                trustedPublicKey: request.trustedPublicKey
            )
        ))
        ServerConnectionStore.save(store)
    }
}
