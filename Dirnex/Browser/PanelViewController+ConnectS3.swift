import AppKit
import DirnexCore

/// The S3 half of Connect-to-Server (PLAN.md §M21), in its own file so
/// `PanelViewController+Connect` stays under the length ceiling. It follows the same shape as the
/// other two — probe on a throwaway transport, register the connection on the pane's
/// `CompositeBackend`, file the secret only once it has authenticated, navigate — with one addition
/// the protocol allows and neither of the others can:
///
/// **Two things correct themselves**, and — unlike FTPS's certificate prompt — neither asks the user
/// anything, for the same reason in both cases: there is no weaker outcome to accept. What each
/// works out is what gets *saved*, so a correction happens once rather than on every connect.
///
/// *A wrong region.* Addressing a bucket through the wrong region answers 301 naming the region that
/// would have worked, in a header AWS sends on every response (probed 2026-08-12). From outside, a
/// wrong region is otherwise indistinguishable from a missing bucket, so without this the user gets
/// "no such bucket" for a bucket that is right there. Re-signing for the region the *service itself*
/// named is not a trust decision.
///
/// *A bucket that cannot be spelled into the host.* Under virtual-host addressing the name TLS
/// verifies is `<bucket>.<host>`, which is one label deeper than a wildcard certificate covers, so a
/// valid publicly-issued certificate fails and path-style is the answer — see
/// ``handleS3TransportFailure(_:request:)``. Path-style still verifies, against the host the user
/// typed, so nothing is traded away here either.
extension PanelViewController {
    /// Everything one S3 connect attempt needs, bundled so the connect and its region retry pass it
    /// around as a single value — the shape `SFTPConnectRequest` and `FTPConnectRequest` established.
    struct S3ConnectRequest {
        var location: S3Location
        let secretAccessKey: String
        let saveName: String?
        /// The sidebar Servers row's name when the connect was launched from that row (so its busy
        /// spinner can be started and stopped), `nil` for a one-off Connect to Server… sheet.
        let activityName: String?
        /// The saved server a correction has to be written back into, when there is one. Distinct
        /// from `saveName`, which means "save under this name on success" and is `nil` for a sidebar
        /// connect precisely because the server is *already* saved; without this the corrected mode
        /// would have nowhere to go and the next click on the same row would re-discover it.
        ///
        /// It may name an **account** rather than this bucket — that is the case entering a bucket
        /// from an account pane — because what gets corrected is a fact about the endpoint, not about
        /// one bucket.
        let savedServerName: String?
        /// Whether this attempt has already been re-aimed at a region the server named. One
        /// correction per connect: a server that keeps redirecting — an endpoint behind something
        /// that answers the probe and the retry differently — would otherwise redirect forever.
        var hasCorrectedRegion = false
        /// Whether this attempt has already been re-addressed path-style. One correction per connect
        /// for the same reason `hasCorrectedRegion` is: the retry goes back through `connectS3`.
        var hasCorrectedAddressing = false
    }

    /// What establishing an S3 connection settled on, before anything is done with it.
    ///
    /// Three cases rather than two, because "the pane moved on while we probed" is neither a success
    /// the caller should act on nor a failure worth a sentence: the answer arrived for a question
    /// nobody is still asking.
    enum S3ConnectOutcome {
        /// Connected and registered on the pane's `CompositeBackend`, carrying the location it
        /// **settled on** — which is not always the one asked for, since a region redirect or a
        /// path-style retry re-aims the connection, and the corrected location is the one the caller
        /// has to address it by.
        case connected(S3Location)
        case failed(String)
        case abandoned
    }

    func connectS3(_ request: S3ConnectRequest) async -> ConnectServerPrompt.Attempt {
        switch await establishS3Connection(request) {
        case let .connected(location):
            navigate(to: VFSPath(backend: .s3(location), path: "/"))
            return .succeeded
        case .abandoned:
            return .succeeded
        case let .failed(detail):
            return .failed(detail)
        }
    }

    /// Probe, self-correct, register — everything a connect does **except decide what to do with
    /// it**.
    ///
    /// Split out of `connectS3` so that entering a bucket and *expanding* one in a tree share one
    /// definition of what connecting to a bucket means. The two corrections documented at the top of
    /// this file are exactly the shape that ends up with a second spelling (docs/NOTES.md ▸ Design
    /// lessons), and a tree expansion needs every one of them for the same reasons Enter does: the
    /// row it opens may be in another region, and its name may be one label too deep for the
    /// endpoint's certificate.
    func establishS3Connection(_ request: S3ConnectRequest) async -> S3ConnectOutcome {
        guard let composite = backend as? CompositeBackend else {
            return .failed(Self.genericS3ConnectError)
        }
        let location = request.location
        let transport = S3CurlTransport(
            location: location,
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
            do { return .success(try transport.probeConnection()) } catch { return .failure(error) }
        }.value
        guard token == loadToken else { return .abandoned } // the pane moved on while we probed

        switch result {
        case let .success(response):
            // The server answered. That is not the same as saying yes — `curl` exits 0 for a denied
            // bucket and a bad signature alike, which is why the refusal is read out of the response
            // rather than out of a thrown error (docs/NOTES.md ▸ curl for S3).
            if let service = S3Backend.serviceError(from: response) {
                return await handleS3Refusal(service, request: request)
            }
            // Only persist the secret once it has actually signed something the service accepted,
            // so a typo isn't cached.
            SecretKeychain.store(password: request.secretAccessKey, for: location)
            composite.connectS3(location: location, secretAccessKey: request.secretAccessKey)
            if let saveName = request.saveName {
                saveS3Server(name: saveName, location: location)
            } else if let savedName = request.savedServerName {
                readdressSavedS3Server(name: savedName, to: location.addressing)
            }
            return .connected(location)
        case let .failure(error):
            return await handleS3TransportFailure(error, request: request)
        }
    }

    /// A refusal the server explained. Only one of them is recoverable without asking the user
    /// anything, and it is the one the bucket itself can answer: the region.
    private func handleS3Refusal(
        _ service: S3ServiceError,
        request: S3ConnectRequest
    ) async -> S3ConnectOutcome {
        guard service.isRegionRedirect,
              !request.hasCorrectedRegion,
              let region = service.correctedRegion,
              region != request.location.region else {
            return .failed(Self.s3RefusalDetail(service, location: request.location))
        }
        var retry = request
        retry.location = Self.movingRegion(of: request.location, to: region)
        retry.hasCorrectedRegion = true
        return await establishS3Connection(retry)
    }

    /// A failure that happened below HTTP. One of them is recoverable without asking the user
    /// anything, and it is the one the *addressing mode* answers rather than the server: TLS
    /// verification.
    ///
    /// **Under virtual-host addressing the bucket is part of the host name**, so the name being
    /// verified is `<bucket>.<host>` — and a wildcard certificate is only one label deep (RFC 6125).
    /// Measured 2026-08-13 against a real endpoint whose certificate is `*.lax.sharktech.net`:
    /// `s3.lax.sharktech.net` verifies and `dirnex-test.s3.lax.sharktech.net` is `curl` exit 60,
    /// while the path-style URL for that same bucket verifies and reaches the service. So a perfectly
    /// valid, publicly-issued certificate fails, and the remedy is an addressing mode rather than
    /// anything to do with trust. Keyed on the mode and not on the service picker, because AWS
    /// reaches the same state for a bucket whose own name contains dots.
    ///
    /// Retrying rather than reporting, because **nothing is traded away**: path-style still verifies
    /// the certificate, against the host the user actually typed — no `--insecure`, no pin, no
    /// plaintext — so there is no weaker outcome for them to weigh, which is exactly the argument the
    /// region correction above makes. And the retry *measures* what a sentence could only guess: if it
    /// connects it was the addressing, and if it fails at TLS again the endpoint really is untrusted.
    /// That second case is the one the old advice got backwards, since it told a self-signed endpoint
    /// to tick a checkbox that cannot help it — and it now falls out for free, because reporting the
    /// retry's own failure runs `s3CertificateDetail` over a path-style location, which reads as being
    /// about the endpoint.
    private func handleS3TransportFailure(
        _ error: Error,
        request: S3ConnectRequest
    ) async -> S3ConnectOutcome {
        guard let retry = Self.addressingCorrection(for: error, request: request) else {
            return .failed(Self.s3ConnectFailureDetail(error, location: request.location))
        }
        return await establishS3Connection(retry)
    }

    /// The attempt to retry path-style, or `nil` when this failure is not one re-addressing can fix.
    ///
    /// Pure and `static` so its three conditions can be pinned by a test — the retry itself runs
    /// `curl`, and these are exactly the conditions that drift unnoticed: a mode other than
    /// virtual-host has nothing to correct, a failure other than exit 60 is not about the host name,
    /// and a second correction inside one connect would be a loop.
    static func addressingCorrection(
        for error: Error,
        request: S3ConnectRequest
    ) -> S3ConnectRequest? {
        guard let responseError = error as? S3ResponseError,
              case .transport(.certificateNotTrusted) = responseError,
              request.location.addressing == .virtualHost,
              !request.hasCorrectedAddressing
        else { return nil }
        var retry = request
        retry.location = request.location.addressed(.path)
        retry.hasCorrectedAddressing = true
        return retry
    }

    /// The same connection signed for `region` — and, for an AWS endpoint, addressed at that
    /// region's host too.
    ///
    /// Both halves are needed and only one is obvious. AWS's 301 is a complaint about the *host*:
    /// re-signing for the right region while still addressing `s3.<wrong>.amazonaws.com` earns the
    /// same redirect again. An S3-compatible endpoint is left exactly where the user put it, since
    /// its host has no region in it to correct — rebuilding one from a region would point the
    /// request at an Amazon host the user never named.
    private static func movingRegion(of location: S3Location, to region: String) -> S3Location {
        let wasDerived = location.host == awsHost(region: location.region)
        return S3Location(
            host: wasDerived ? awsHost(region: region) : location.host,
            port: wasDerived ? nil : location.port,
            bucket: location.bucket,
            region: region,
            accessKeyID: location.accessKeyID,
            addressing: location.addressing,
            usesTLS: wasDerived ? true : location.usesTLS
        )
    }

    private static func awsHost(region: String) -> String { S3Location.awsHost(region: region) }

    // MARK: - Errors

    static var genericS3ConnectError: String {
        String(
            localized: "The connection couldn’t be set up.",
            comment: "Generic server-connect failure with no more specific reason."
        )
    }

    /// What the service said, in words the user can act on.
    ///
    /// The `<Code>` element does the separating, not the status: a bad key and a bucket policy both
    /// arrive as 403 and send the user to completely different places — one is something they
    /// retype, the other is a permission they have to go and change somewhere else.
    static func s3RefusalDetail(_ service: S3ServiceError, location: S3Location) -> String {
        if service.isCredentialFailure {
            return String(
                localized: "The access key or secret key wasn’t accepted.",
                comment: "S3 connect failure detail: the credentials themselves were rejected."
            )
        }
        switch service.code {
        case "AccessDenied":
            return String(
                localized: """
                That key signed in, but it isn’t allowed to list “\(location.bucket)”. Check the \
                bucket policy or the permissions on the key.
                """,
                comment: "S3 connect failure detail; %@ is the bucket name. The key is valid, the policy is not."
            )
        case "NoSuchBucket":
            return String(
                localized: "There’s no bucket named “\(location.bucket)” on \(location.host).",
                comment: "S3 connect failure detail; %1$@ is the bucket name and %2$@ the endpoint."
            )
        case "PermanentRedirect":
            // Reached only when the redirect named no region we could use — an S3-compatible server
            // that redirects without saying where, or a second redirect after a correction.
            return String(
                localized: """
                That bucket is served from a different region, and the server didn’t say which one. \
                Check the region in the provider’s console.
                """,
                comment: "S3 connect failure detail: a redirect that carried no usable region."
            )
        default:
            return Self.s3StatusDetail(service)
        }
    }

    /// The fallback for a refusal with no code worth naming — a proxy's HTML, a captive portal, an
    /// S3-compatible server answering in its own shape. The status is all there is, so it is what
    /// the sentence is built from rather than the server's own English (which is the *remote's*
    /// words, in a language nobody chose — docs/NOTES.md ▸ Localization).
    static func s3StatusDetail(_ service: S3ServiceError) -> String {
        switch service.status {
        case 401, 403:
            return String(
                localized: "The server refused the request.",
                comment: "S3 connect failure detail: a 401/403 with no S3 error code to explain it."
            )
        case 404:
            return String(
                localized: "The endpoint answered, but there’s nothing there to browse.",
                comment: "S3 connect failure detail: a 404 with no S3 error code to explain it."
            )
        default:
            return String(
                localized: "The server answered with an error (HTTP \(service.status)).",
                comment: "S3 connect failure detail; %lld is the HTTP status code."
            )
        }
    }

    /// A human-readable reason for a connect that never reached the service at all. Only
    /// `S3ResponseError.transport` can arrive here — a refusal is a returned response, handled above
    /// — but the service case is mapped rather than left to a `default`, so it is handled instead of
    /// silently reading as "something went wrong".
    static func s3ConnectFailureDetail(_ error: Error, location: S3Location) -> String {
        s3ConnectFailureDetail(error, certificateDetail: s3CertificateDetail(location: location))
    }

    /// The same mapping with the TLS sentence handed in, because that is the one branch where a
    /// *bucket* connection and an *account* connection genuinely differ: a bucket may carry its name
    /// in the host, and an account never does — a service request is `GET https://<endpoint>/`, so a
    /// verification failure there really is about the endpoint's own certificate and the path-style
    /// advice would be beside the point.
    static func s3ConnectFailureDetail(_ error: Error, certificateDetail: String) -> String {
        guard let responseError = error as? S3ResponseError else {
            return (error as NSError).localizedDescription
        }
        switch responseError {
        case let .service(service):
            return Self.s3StatusDetail(service)
        case let .transport(failure):
            switch failure {
            case .couldNotResolveHost, .couldNotConnect:
                return String(
                    localized: "The endpoint couldn’t be reached. Check the address and the port.",
                    comment: "S3 connect failure detail: the host could not be resolved or connected."
                )
            case .operationTimedOut:
                return String(
                    localized: "The endpoint stopped responding.",
                    comment: "S3 connect failure detail: the request exceeded its time budget."
                )
            case .certificateNotTrusted:
                return certificateDetail
            case .other:
                return String(
                    localized: "The request couldn’t be sent.",
                    comment: "S3 connect failure detail: curl failed for a reason with no mapping."
                )
            }
        }
    }

    /// Why TLS verification failed, which is two different failures wearing one `curl` exit code.
    ///
    /// **Under virtual-host addressing the bucket is part of the host name**, so the name being
    /// verified is `<bucket>.<host>` rather than the endpoint the user typed — and a wildcard
    /// certificate is only **one label deep** (RFC 6125). `*.lax.sharktech.net` therefore covers
    /// `s3.lax.sharktech.net` and not `my-bucket.s3.lax.sharktech.net`, so a perfectly valid,
    /// publicly-issued certificate fails, and the remedy is the path-style checkbox rather than
    /// anything to do with trust. Measured live 2026-08-13 against a real S3-compatible endpoint,
    /// where this is what a user meets on their *first* connect, since the form offers virtual-host
    /// first.
    ///
    /// The old wording — "a server with a self-signed certificate has to be reached over http://" —
    /// was wrong in every clause for that case, and wrong in the expensive direction: it diagnosed an
    /// addressing problem as a trust problem and pointed the user at **plaintext** as the cure.
    ///
    /// It is deliberately keyed on the *addressing mode* rather than on the service picker, because
    /// AWS reaches the same state: `*.s3.<region>.amazonaws.com` is also one label deep, so a bucket
    /// whose own name contains dots cannot be addressed virtual-host over TLS either. Path-style is
    /// the same answer there.
    ///
    /// The checkbox is named by interpolating its own title rather than by spelling it out, so the
    /// sentence names the control the user is looking at in all fourteen languages — the duplicate-
    /// display-string trap from docs/NOTES.md ▸ Localization, avoided by not making a second copy.
    static func s3CertificateDetail(location: S3Location) -> String {
        // Path-style: the name being verified *is* the endpoint, so this really is about trust.
        guard location.addressing == .virtualHost else { return s3EndpointCertificateDetail }
        let authority = "\(location.bucket).\(location.host)"
        return String(
            localized: """
            The endpoint’s TLS certificate couldn’t be verified for “\(authority)”. \
            The bucket is part of the host name until “\(ConnectText.pathStyle)” is turned on, \
            and most certificates don’t cover that.
            """,
            comment: """
            S3 connect failure detail: TLS failed while the bucket was in the host name. \
            %1$@ is <bucket>.<host>; %2$@ is the title of the path-style checkbox in the same sheet.
            """
        )
    }

    /// TLS verification failed for a name the user actually typed — the endpoint itself. Reached
    /// under path-style addressing, where the bucket is in the path, and for every *account*
    /// request, which never names a bucket at all.
    static var s3EndpointCertificateDetail: String {
        String(
            localized: """
            The endpoint’s TLS certificate couldn’t be verified. A server with a \
            self-signed certificate has to be reached over http:// for now.
            """,
            comment: "S3 connect failure detail: TLS verification failed for the endpoint itself."
        )
    }

    /// Write a corrected addressing mode back into the saved server this connect came from — which
    /// may be the *account* a bucket was entered from, since what was learned is a fact about the
    /// endpoint.
    ///
    /// Called after every successful connect that came from a saved record rather than only after a
    /// corrected one: `readdressS3` answers `false` when the mode already matches, so the ordinary
    /// path writes nothing and posts no change notification (the shape `repinFTP` established).
    private func readdressSavedS3Server(name: String, to addressing: S3Addressing) {
        var store = ServerConnectionStore.load()
        guard store.readdressS3(name: name, to: addressing) else { return }
        ServerConnectionStore.save(store)
    }

    private func saveS3Server(name: String, location: S3Location) {
        var store = ServerConnectionStore.load()
        store.save(ServerConnection(name: name, endpoint: .s3(location)))
        ServerConnectionStore.save(store)
    }
}
