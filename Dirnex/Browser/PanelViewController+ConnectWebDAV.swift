import AppKit
import DirnexCore

/// The WebDAV half of Connect-to-Server (PLAN.md §M32 Slice 3), the shape FTP's established: probe
/// on throwaway transports, register the connection on the pane's `CompositeBackend`, file the
/// password only once it has authenticated, navigate.
///
/// **The probe is the core's** (``WebDAVConnectProbe``): two `Depth: 0` PROPFINDs of the root, the
/// first without credentials so the server names its scheme before any password goes out. What it
/// settles — the scheme — is kept for the connection and written into the endpoint, so a restored
/// tab reconnects the way this one did without asking again (``ServerEndpoint/webdav(location:authentication:trustedPublicKey:)``).
///
/// **The certificate flow is FTPS's**, alerts included: the NAS presents the same self-signed
/// certificate on its WebDAV port as on its FTPS one, with an identical key pin, so the question
/// and the answer carry over unchanged. `curl` exits 60 for a certificate nobody has weighed and
/// 90 for a pin that no longer matches, and both lead to the same fetch-show-pin-retry, bounded to
/// one decision per connect.
extension PanelViewController {
    /// Everything one WebDAV connect attempt needs, bundled as `FTPConnectRequest` is.
    struct WebDAVConnectRequest {
        let location: WebDAVLocation
        /// The plaintext password, or empty for a public share.
        let password: String
        var trustedPublicKey: String?
        let saveName: String?
        let activityName: String?
        /// The saved server this connect came from, when it came from one — the record a new pin
        /// or a changed scheme is written back into (`FTPConnectRequest.savedServerName` gives the
        /// reason it is not `saveName`).
        let savedServerName: String?
        /// As `SFTPConnectRequest.inNewTab`; the trust retry copies the request, and the flag with it.
        var inNewTab = false
        /// One certificate decision per connect, for the reason `FTPConnectRequest` gives.
        var hasWeighedCertificate = false
    }

    func connectWebDAV(_ request: WebDAVConnectRequest) async -> ConnectServerPrompt.Attempt {
        guard let composite = backend as? CompositeBackend else {
            return .failed(Self.genericConnectError)
        }
        let location = request.location
        let probe = WebDAVCurlTransport(
            location: location,
            password: request.password,
            trustedPublicKey: request.trustedPublicKey,
            authentication: nil
        )
        let token = loadToken
        if let activityName = request.activityName { SidebarRowActivity.shared.begin(activityName) }
        defer { if let activityName = request.activityName { SidebarRowActivity.shared.end(
            activityName
        ) } }

        let result = await BlockingWork.run { () -> Result<WebDAVConnection, Error> in
            do {
                return .success(try WebDAVConnectProbe.connect(to: location) {
                    probe.authenticating(with: $0)
                })
            } catch {
                return .failure(error)
            }
        }
        guard token == loadToken else { return .succeeded } // the pane moved on while we probed

        switch result {
        case let .success(connection):
            // Only persist a password once it actually authenticated, so a typo isn't cached.
            if location.hasCredentials, !request.password.isEmpty {
                SecretKeychain.store(password: request.password, for: location)
            }
            composite.connectWebDAV(
                location: location,
                password: request.password,
                authentication: connection.authentication,
                trustedPublicKey: request.trustedPublicKey
            )
            recordWebDAVServer(request, authentication: connection.authentication)
            navigate(to: VFSPath(backend: .webDAV(location), path: "/"), inNewTab: request.inNewTab)
            return .succeeded
        case let .failure(error):
            return await handleWebDAVFailure(error, request: request)
        }
    }

    /// A certificate nobody has weighed, or one that stopped matching its pin, goes to the user;
    /// everything else is reported.
    private func handleWebDAVFailure(
        _ error: Error,
        request: WebDAVConnectRequest
    ) async -> ConnectServerPrompt.Attempt {
        switch error as? WebDAVConnectError {
        case .transport(.certificateNotTrusted):
            return await weighWebDAVCertificate(request: request, changed: false, error: error)
        case .transport(.pinnedKeyMismatch):
            return await weighWebDAVCertificate(request: request, changed: true, error: error)
        default:
            return .failed(Self.webDAVConnectFailureDetail(error))
        }
    }

    /// Put the server's certificate to the user and, on acceptance, pin it and retry — FTPS's
    /// `weighCertificate`, down to declining leaving the old pin standing and nothing written.
    private func weighWebDAVCertificate(
        request: WebDAVConnectRequest,
        changed: Bool,
        error: Error
    ) async -> ConnectServerPrompt.Attempt {
        guard !request.hasWeighedCertificate else {
            return .failed(Self.certificateStillMismatched)
        }
        let transport = WebDAVCurlTransport(location: request.location, authentication: nil)
        let certificate = await BlockingWork.run { () -> FTPCertificate? in
            try? transport.fetchCertificate()
        }
        guard let certificate else { return .failed(Self.webDAVConnectFailureDetail(error)) }
        // A key that can't be read cannot be pinned, and connecting without a pin would mean
        // connecting unverified.
        guard let pin = certificate.publicKeyPin else { return .failed(Self.unreadableCertificate) }
        let host = request.location.host
        let accepted = changed
            ? await Self.confirmCertificateChange(
                host: host,
                certificate: certificate,
                over: view.window
            )
            : await Self.confirmCertificateTrust(
                host: host,
                certificate: certificate,
                over: view.window
            )
        guard accepted else {
            return .failed(changed ? Self.certificateChangeNotTrusted : Self.certificateNotTrusted)
        }
        var retry = request
        retry.trustedPublicKey = pin
        retry.hasWeighedCertificate = true
        return await connectWebDAV(retry)
    }

    /// Save the connection under the sheet's name, or write what this connect settled back into
    /// the saved server it came from.
    ///
    /// The second is reloaded and matched by name at this moment, as `repinSavedFTPServer` does, so
    /// an edit made while the connect ran is not clobbered, and a record deleted meanwhile is not
    /// recreated.
    private func recordWebDAVServer(
        _ request: WebDAVConnectRequest,
        authentication: WebDAVAuthScheme?
    ) {
        var store = ServerConnectionStore.load()
        if let saveName = request.saveName {
            store.save(ServerConnection(
                name: saveName,
                endpoint: .webdav(
                    location: request.location,
                    authentication: authentication,
                    trustedPublicKey: request.trustedPublicKey
                )
            ))
        } else if let savedName = request.savedServerName {
            guard store.settleWebDAV(
                name: savedName,
                authentication: authentication,
                trustedPublicKey: request.trustedPublicKey
            ) else { return }
        } else {
            return
        }
        ServerConnectionStore.save(store)
    }

    // MARK: - Errors

    /// A human-readable reason for a failed WebDAV connect. Each case of ``WebDAVConnectError`` is
    /// its own sentence because each asks the user for something different: a password, a path, a
    /// scheme, or another address.
    static func webDAVConnectFailureDetail(_ error: Error) -> String {
        guard let connectError = error as? WebDAVConnectError else {
            return (error as NSError).localizedDescription
        }
        switch connectError {
        case let .transport(failure):
            return transportFailureDetail(failure)
        case .credentialsRequired:
            return String(
                localized: "This server asks for a user name and password.",
                comment: "WebDAV connect failure detail: the server requires an account and none was given."
            )
        case .credentialsRefused:
            return loginFailed
        case let .unsupportedAuthentication(schemes):
            let names = schemes.map(Self.schemeName).formatted(.list(type: .and))
            return String(
                localized: "This server only accepts sign-in methods Dirnex doesn’t support: \(names).",
                comment: """
                WebDAV connect failure detail. %@ lists the HTTP authentication schemes the server \
                offered, such as “NTLM and Negotiate”; Dirnex speaks only Basic and Digest.
                """
            )
        case let .notWebDAV(status):
            return String(
                localized: """
                This address doesn’t answer as a WebDAV folder (HTTP \(status)). Check the path: \
                on Nextcloud it is /remote.php/dav/files/ followed by your user name.
                """,
                comment: """
                WebDAV connect failure detail: the server answered, but not with a WebDAV listing. \
                %lld is the HTTP status. The path example is literal and must not be translated.
                """
            )
        case let .redirected(location):
            guard let location, !location.isEmpty else {
                return String(
                    localized: "The server redirects to another address without saying which.",
                    comment: "WebDAV connect failure detail: an HTTP redirect with no Location header."
                )
            }
            return String(
                localized: "The server redirects to “\(location)”. Connect to that address instead.",
                comment: """
                WebDAV connect failure detail: the server answered with an HTTP redirect, usually \
                from http to https. %@ is the address it names.
                """
            )
        case .rootNotFound:
            return String(
                localized: "There is nothing at that path on the server.",
                comment: "WebDAV connect failure detail: the root path does not exist."
            )
        case .rootIsNotAFolder:
            return String(
                localized: "That path on the server is a file, not a folder.",
                comment: "WebDAV connect failure detail: the root path names a file."
            )
        case let .refused(service):
            if service.status == 403 { return pathRefused }
            return String(
                localized: "The WebDAV server answered with an error (HTTP \(service.status)).",
                comment: "WebDAV connect failure detail; %lld is the HTTP status code."
            )
        }
    }

    /// An authentication scheme as its specification spells it. The challenge reader lowercases
    /// them, which is right for comparing and wrong for a sentence.
    private static func schemeName(_ scheme: String) -> String {
        let known = [
            "ntlm": "NTLM",
            "negotiate": "Negotiate",
            "bearer": "Bearer",
            "kerberos": "Kerberos"
        ]
        return known[scheme] ?? scheme.capitalized
    }

    /// A request that got no answer, by `curl`'s exit code. The two certificate cases reach here
    /// only when the certificate could not be fetched to show.
    private static func transportFailureDetail(_ failure: WebDAVTransportFailure) -> String {
        switch failure {
        case .couldNotResolveHost, .couldNotConnect: serverUnreachable
        case .operationTimedOut: serverStoppedResponding
        case .certificateNotTrusted: certificateUnverified
        case .pinnedKeyMismatch: changedCertificateUnreadable
        case .other:
            String(
                localized: "The connection to the server failed.",
                comment: "WebDAV connect failure detail: the request failed below HTTP for another reason."
            )
        }
    }
}
