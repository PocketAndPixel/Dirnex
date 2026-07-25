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
            ServerConnectionActivity.shared.begin(activityName)
        }
        defer {
            if let activityName = request.activityName {
                ServerConnectionActivity.shared.end(activityName)
            }
        }

        let result = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
            do { return .success(try transport.probeConnection()) } catch { return .failure(error) }
        }.value
        guard token == loadToken else { return .succeeded } // the pane moved on while we probed

        switch result {
        case .success:
            // Only persist a password once it actually authenticated, so a typo isn't cached.
            if case .password = request.authentication, !request.password.isEmpty {
                FTPKeychain.store(password: request.password, for: location)
            }
            composite.connectFTP(
                location: location,
                authentication: request.authentication,
                password: request.password,
                trustedPublicKey: request.trustedPublicKey
            )
            if let saveName = request.saveName {
                saveFTPServer(name: saveName, request: request)
            }
            navigate(to: VFSPath(backend: .ftp(location), path: "/"))
            return .succeeded
        case let .failure(error):
            return await handleFTPFailure(error, request: request)
        }
    }

    /// An untrusted certificate is recoverable — fetch it, show the user its fingerprint, and pin it
    /// on their explicit acceptance. Everything else is reported.
    private func handleFTPFailure(
        _ error: Error,
        request: FTPConnectRequest
    ) async -> ConnectServerPrompt.Attempt {
        guard case .certificateUntrusted = error as? FTPTransportError else {
            return .failed(Self.ftpConnectFailureDetail(error))
        }
        guard let certificate = await fetchFTPCertificate(for: request) else {
            return .failed(Self.ftpConnectFailureDetail(error))
        }
        guard let pin = certificate.publicKeyPin else {
            // A certificate whose key can't be read cannot be pinned, and connecting without a pin
            // would mean connecting unverified — which is the one thing this flow must never do.
            return .failed(Self.unreadableCertificate)
        }
        guard confirmCertificateTrust(location: request.location, certificate: certificate) else {
            return .failed(Self.certificateNotTrusted)
        }
        var retry = request
        retry.trustedPublicKey = pin
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
        return await Task.detached(priority: .userInitiated) { () -> FTPCertificate? in
            try? transport.fetchCertificate()
        }.value
    }

    // MARK: - Trust prompt

    /// Show the certificate's fingerprint and ask whether to trust this server's key from now on.
    /// Presented as a critical alert whose default and rightmost button is the safe "Cancel", so
    /// pinning is always a deliberate click — the same treatment the SFTP host-key change gets.
    private func confirmCertificateTrust(
        location: FTPLocation,
        certificate: FTPCertificate
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            localized: "Can’t verify the identity of “\(location.host)”",
            comment: "FTPS certificate-trust alert title; %@ is the host name."
        )
        alert.informativeText = Self.certificateTrustDetail(certificate)
        // "Cancel" is added first so it is the rightmost and answers Escape. AppKit only binds
        // Escape by matching the literal English "Cancel", so a translated build needs the explicit
        // `enableEscapeToCancel(safe:)` or the alert has no way out (docs/NOTES.md).
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Cancel button."))
        alert.addButton(withTitle: String(
            localized: "Trust & Connect",
            comment: "FTPS certificate-trust alert: pin this certificate and connect."
        ))
        alert.enableEscapeToCancel(safe: .alertFirstButtonReturn)
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// The body of the trust alert: what the certificate claims, how long it is valid, and the
    /// fingerprint to compare against the server. The fingerprint is the *certificate's* SHA-256 —
    /// the value every other tool shows, so a user can check it against their NAS's admin page —
    /// while what actually gets pinned is the public key inside it, which survives a routine
    /// certificate renewal the way SSH's key pinning does.
    private static func certificateTrustDetail(_ certificate: FTPCertificate) -> String {
        let explanation = String(
            localized: """
            The server presented a certificate that isn’t signed by a trusted authority. This is \
            normal for a NAS or a home server, but it can also mean someone is intercepting the \
            connection.

            Compare this fingerprint with the one shown on the server before trusting it.
            """,
            comment: "FTPS certificate-trust alert body, above the certificate's details."
        )
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
            localized: "The server’s certificate wasn’t trusted, so the connection was cancelled.",
            comment: "FTP connect failure detail: the user declined to trust the certificate."
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
        case .certificateUntrusted:
            return String(
                localized: "The server’s certificate couldn’t be verified.",
                comment: "FTP connect failure detail: TLS certificate verification failed."
            )
        case .certificateChanged:
            return String(
                localized: """
                The server is presenting a different certificate than the one you trusted. Remove \
                the saved server and connect again only if you know why it changed.
                """,
                comment: "FTP connect failure detail: the pinned public key no longer matches."
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
