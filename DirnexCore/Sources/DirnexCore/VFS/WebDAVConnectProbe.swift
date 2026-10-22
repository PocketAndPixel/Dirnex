import Foundation

/// What a successful connect learned: the scheme every later request on this connection uses.
public struct WebDAVConnection: Sendable, Equatable {
    /// The scheme credentials go out with, or `nil` when the account has none to send.
    public let authentication: WebDAVAuthScheme?

    public init(authentication: WebDAVAuthScheme?) {
        self.authentication = authentication
    }
}

/// Why a connect did not get as far as a folder to show. Each case is a different sentence in the
/// connect sheet, and several are a different *action*: a certificate goes to the trust sheet, a
/// credential back to the password field, a redirect names where the server points.
public enum WebDAVConnectError: Error, Sendable, Equatable {
    /// Nothing answered, or the TLS handshake failed — `curl`'s exit code, which the app reads for
    /// the certificate cases (60 and 90) exactly as FTPS does.
    case transport(WebDAVTransportFailure)
    /// The server asked for credentials and the location has no user name.
    case credentialsRequired
    /// The server refused the credentials it was sent.
    case credentialsRefused
    /// The server asked for credentials in schemes Dirnex does not speak — NTLM, Negotiate or a
    /// bearer token (PLAN.md §M32). The schemes are named, lowercased, so the sentence can say
    /// which.
    case unsupportedAuthentication(schemes: [String])
    /// Something answered, and it is not a WebDAV folder: a web page, or a server that does not
    /// know PROPFIND (macOS's Apache answers a folder without WebDAV with 405 and an `Allow` header
    /// that lacks it). The usual cause is the root path — Nextcloud's account lives at
    /// `/remote.php/dav/files/<user>/`, and its `/` is the web interface.
    case notWebDAV(status: Int)
    /// The server pointed somewhere else — most often from `http` to `https`. Not followed, since a
    /// redirect would carry the credentials to a place nobody chose; the location is reported so
    /// the user can.
    case redirected(location: String?)
    /// Nothing is at the root path.
    case rootNotFound
    /// The root path names a file.
    case rootIsNotAFolder
    /// Any other refusal, with what the server said.
    case refused(WebDAVServiceError)
}

/// Reading a `WWW-Authenticate` challenge (RFC 7235) for the schemes it offers.
///
/// A server may offer several, as several headers or as one header holding a comma-separated list,
/// and a parameter's quoted value may contain commas and `=` of its own (a Digest nonce is base64,
/// a `qop` can be `"auth,auth-int"`). So the value is split at commas **outside** quotes, and an
/// element starts a new challenge only when it begins with a token that is not followed by `=`.
public enum WebDAVChallenge {
    /// The schemes the challenges offer, lowercased, in order, without repeats.
    public static func schemes(in headerValues: [String]) -> [String] {
        var schemes: [String] = []
        for value in headerValues {
            for element in elements(of: value) {
                if let scheme = leadingScheme(element), !schemes.contains(scheme) {
                    schemes.append(scheme)
                }
            }
        }
        return schemes
    }

    /// The scheme to answer with, or `nil` when none is one Dirnex speaks.
    ///
    /// When both are offered, the transport decides: over HTTPS, Basic, which costs one round trip
    /// where Digest costs two and sends nothing TLS is not already protecting; over plain HTTP,
    /// Digest, which keeps the password off a wire anyone can read.
    public static func preferred(among schemes: [String], overTLS: Bool) -> WebDAVAuthScheme? {
        switch (schemes.contains("basic"), schemes.contains("digest")) {
        case (true, true): overTLS ? .basic : .digest
        case (true, false): .basic
        case (false, true): .digest
        case (false, false): nil
        }
    }

    /// The comma-separated elements of one header value, commas inside a quoted string (with its
    /// backslash escapes) left alone.
    private static func elements(of value: String) -> [String] {
        var elements: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in value {
            if escaped {
                escaped = false
            } else if inQuotes, character == "\\" {
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
            } else if character == ",", !inQuotes {
                elements.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        elements.append(current)
        return elements.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The scheme an element opens with, or `nil` when the element is a parameter of the challenge
    /// before it. A scheme is a token followed by whitespace or by nothing (`Negotiate`,
    /// `Basic realm="x"`, `Negotiate YII=`); a parameter is a token followed by `=`, with optional
    /// whitespace before it.
    private static func leadingScheme(_ element: String) -> String? {
        let tokenEnd = element.firstIndex { !isTokenCharacter($0) } ?? element.endIndex
        guard tokenEnd > element.startIndex else { return nil }
        let rest = element[tokenEnd...]
        guard rest.first.map({ $0 == " " || $0 == "\t" }) ?? true else { return nil }
        guard rest.drop(while: { $0 == " " || $0 == "\t" }).first != "=" else { return nil }
        return element[..<tokenEnd].lowercased()
    }

    /// RFC 9110's `tchar`.
    private static func isTokenCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character.isNumber || "!#$%&'*+-.^_`|~".contains(character)
    }
}

/// The connect probe: the questions asked of a server before a pane is pointed at it.
///
/// Two requests, both a `Depth: 0` PROPFIND of the root. The first goes **without credentials**, so
/// the server names the scheme it wants before any password is sent in one it did not ask for; the
/// second goes with the account's credentials in that scheme, and its 207 proves three things at
/// once — the credentials work, the root exists and it is a folder.
///
/// PLAN.md had the first request as an OPTIONS, for the `DAV` header. Measured on the NAS
/// 2026-10-23, that header is not there to be read: OPTIONS without credentials answers 401 with
/// no `DAV`, and with them it answers **200 with `DAV: 1,2` for a path that does not exist**, so it
/// could prove neither the root nor the credentials on a server that exempts OPTIONS from
/// authentication — as Nextcloud does, for its anonymous-OPTIONS plugin. A PROPFIND proves WebDAV
/// by being answered with a multistatus, and its refusal by a server without WebDAV is a 405.
public enum WebDAVConnectProbe {
    /// Probe `location`, asking `transport` for a transport that authenticates with a given
    /// scheme — `nil` for none.
    ///
    /// A server that answers the first request without asking is either public or exempts reads,
    /// and an account the user typed still logs in: a server that serves reads anonymously may
    /// want the account for writes. Basic goes out then, since nothing named another scheme — and
    /// if the authenticated request is answered with a challenge for Digest alone, it is asked once
    /// more in Digest rather than reported as a wrong password.
    public static func connect(
        to location: WebDAVLocation,
        over transport: (WebDAVAuthScheme?) -> any WebDAVTransport
    ) throws -> WebDAVConnection {
        switch try rootAnswer(at: location, over: transport(nil)) {
        case .folder:
            guard location.hasCredentials else { return WebDAVConnection(authentication: nil) }
            return try authenticate(location, with: .basic, over: transport, mayChangeScheme: true)
        case let .challenge(schemes):
            guard location.hasCredentials else { throw WebDAVConnectError.credentialsRequired }
            guard let scheme = WebDAVChallenge.preferred(among: schemes, overTLS: location.usesTLS)
            else { throw WebDAVConnectError.unsupportedAuthentication(schemes: schemes) }
            return try authenticate(location, with: scheme, over: transport, mayChangeScheme: false)
        }
    }

    private static func authenticate(
        _ location: WebDAVLocation,
        with scheme: WebDAVAuthScheme,
        over transport: (WebDAVAuthScheme?) -> any WebDAVTransport,
        mayChangeScheme: Bool
    ) throws -> WebDAVConnection {
        switch try rootAnswer(at: location, over: transport(scheme)) {
        case .folder:
            return WebDAVConnection(authentication: scheme)
        case let .challenge(schemes):
            if mayChangeScheme,
               let named = WebDAVChallenge.preferred(among: schemes, overTLS: location.usesTLS),
               named != scheme {
                return try authenticate(
                    location,
                    with: named,
                    over: transport,
                    mayChangeScheme: false
                )
            }
            throw WebDAVConnectError.credentialsRefused
        }
    }

    /// What the root answered that lets the probe go on.
    private enum RootAnswer {
        case folder
        case challenge([String])
    }

    /// Ask for the root and read the answer, throwing everything that ends the connect.
    ///
    /// The root is asked for as a collection, the way every listing of it will be — so a root path
    /// naming a **file** meets what a listing of a file meets on Apache: a bare 400. Measured
    /// against macOS's Apache 2026-10-23, with a root of `/basic/hello.txt` the probe reported a
    /// refusal with status 400 rather than the root being a file. The listing's rule answers it here
    /// too (``WebDAVBackend/mayNameAFile(_:)``): after a 400, 404 or 409, one more request without
    /// the slash says whether a file is there.
    private static func rootAnswer(
        at location: WebDAVLocation,
        over transport: any WebDAVTransport
    ) throws -> RootAnswer {
        let response = try askForRoot(over: transport, asCollection: true)
        if WebDAVBackend.mayNameAFile(response.status),
           isFile(try askForRoot(over: transport, asCollection: false), at: location) {
            throw WebDAVConnectError.rootIsNotAFolder
        }
        switch response.status {
        case 207:
            let rootPath = location.serverPath(forBackendPath: "/")
            guard let listing = try? WebDAVMultistatusParser.parse(response.body).listing(
                of: rootPath
            )
            else { throw WebDAVConnectError.notWebDAV(status: response.status) }
            guard listing.folder.isCollection else { throw WebDAVConnectError.rootIsNotAFolder }
            return .folder
        case 401:
            return .challenge(WebDAVChallenge.schemes(in: response.values("www-authenticate")))
        case 300..<400:
            throw WebDAVConnectError.redirected(location: response.value("location"))
        case 404:
            throw WebDAVConnectError.rootNotFound
        // A 2xx that is not a multistatus is a web page, and 405 or 501 a server that does not
        // know the method at all.
        case 200..<300, 405, 501:
            throw WebDAVConnectError.notWebDAV(status: response.status)
        default:
            throw WebDAVConnectError.refused(
                WebDAVServiceError.parse(response.body, status: response.status, method: .propfind)
            )
        }
    }

    /// One `Depth: 0` PROPFIND of the root, a request that got no answer thrown as the connect's
    /// own transport failure.
    private static func askForRoot(
        over transport: any WebDAVTransport,
        asCollection: Bool
    ) throws -> WebDAVHTTPResponse {
        do {
            return try transport.propfind("/", depth: .zero, isCollection: asCollection)
        } catch let WebDAVResponseError.transport(failure) {
            throw WebDAVConnectError.transport(failure)
        }
    }

    /// Whether `response` says the root is a file.
    private static func isFile(_ response: WebDAVHTTPResponse, at location: WebDAVLocation) -> Bool {
        guard response.status == 207,
              let listing = try? WebDAVMultistatusParser.parse(response.body)
              .listing(of: location.serverPath(forBackendPath: "/"))
        else { return false }
        return !listing.folder.isCollection
    }
}
