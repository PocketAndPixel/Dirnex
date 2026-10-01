import Foundation

/// The places the Help menu opens (PLAN.md §M30).
public enum HelpLinks {
    public static let website = URL(string: "https://dirnex.app")!
    /// Every release with its notes. The website's changelog will be built from the same releases
    /// (the private repo's C4), so this can move there once it exists.
    public static let releaseNotes = URL(string: "https://github.com/olegasd123/Dirnex/releases")!
}

/// Where a bug report goes (PLAN.md §M30): the address the release workflow writes into
/// `Info.plist` as `DirnexBugReportURL` once the store's server accepts reports. A build without one
/// shows no trace of the feature.
public enum BugReportEndpoint {
    /// The address `value` names, or `nil` when it isn't one a report may go to.
    ///
    /// Only `https`, with a host and no user name or password in it. `allowsLoopbackHTTP` also lets
    /// plain `http` to this Mac through (`127.0.0.1`, `::1`, `localhost`), for a Debug build talking
    /// to `Tooling/fake-bug-report-endpoint.py`. An empty value, which is what every build outside
    /// the release workflow carries, is `nil`.
    public static func url(fromInfoValue value: Any?, allowsLoopbackHTTP: Bool = false) -> URL? {
        guard let text = (value as? String).map(BugReportText.trimmed), !text.isEmpty,
              let components = URLComponents(string: text),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url
        else {
            return nil
        }
        // `URLComponents` keeps the brackets around an IPv6 host (`[::1]`).
        let bareHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        switch components.scheme?.lowercased() {
        case "https":
            return url
        case "http" where allowsLoopbackHTTP && ["127.0.0.1", "::1", "localhost"].contains(bareHost):
            return url
        default:
            return nil
        }
    }
}

/// The request that carries a report.
public enum BugReportRequest {
    /// How long to wait for the server before offering Copy Report and Email Instead.
    public static let timeout: TimeInterval = 30

    /// The `User-Agent`, with no version in it. The system's default names the app's build and the
    /// Darwin version, which would send what an unticked box holds back.
    public static let userAgent = "Dirnex"

    /// A `POST` of `body`, with every header that would otherwise carry a fact about this Mac set to
    /// one that carries none. `Accept-Language` is the other one the system adds by itself: it
    /// names the languages the user prefers, whatever the language box says.
    public static func make(to endpoint: URL, body: Data) -> URLRequest {
        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("*", forHTTPHeaderField: "Accept-Language")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }
}

/// What happened to a report that was sent, read from the server's answer as the contract describes
/// it (the private repo's `web/src/bug-reports/contract.ts`).
public enum BugReportOutcome: Hashable, Sendable {
    /// Kept. `reference` is the server's id for it, when the answer carried one.
    case sent(reference: String?)
    /// Refused, by the name the contract gives the refusal (`tooLong`, `malformed`, …).
    case refused(String)
    /// Too many reports from this address in the last hour.
    case rateLimited
    /// The server answered, but not with an answer the contract has.
    case serverProblem(status: Int)
    /// No answer: offline, the server is down, or the time ran out.
    case unreachable

    /// The outcome an HTTP answer stands for. Any 2xx counts as kept (the contract says 201), and a
    /// 400 or 413 whose body names no refusal is a server problem rather than a guess.
    public init(status: Int, body: Data) {
        switch status {
        case 200..<300:
            let receipt = try? JSONDecoder().decode(Receipt.self, from: body)
            self = .sent(reference: receipt?.id.flatMap(BugReportText.nonBlank))
        case 429:
            self = .rateLimited
        case 400, 413:
            if let refusal = try? JSONDecoder().decode(Refusal.self, from: body) {
                self = .refused(refusal.error)
            } else {
                self = .serverProblem(status: status)
            }
        default:
            self = .serverProblem(status: status)
        }
    }

    /// Whether the server kept the report.
    public var isSent: Bool {
        if case .sent = self { return true }
        return false
    }

    private struct Receipt: Decodable {
        let id: String?
    }

    private struct Refusal: Decodable {
        let error: String
    }
}

/// *Email Instead* (PLAN.md §M30): the report as a `mailto:` link, for when the server can't be
/// reached. The mail carries the same JSON the server would have had.
public enum BugReportMail {
    public static let address = "support@dirnex.app"

    /// The longest link handed to the mail app. A mail client may cut a long `mailto:` short, or
    /// refuse it, so past this length the crash report is left out of the mail and the report is
    /// meant to go on the clipboard as well.
    public static let maximumURLLength = 100_000

    /// The link, and whether the crash report had to be left out to fit.
    ///
    /// `crashReportLeftOut` is the line that takes the crash report's place at the top of the mail,
    /// in the user's language. Line breaks are written as CRLF, as RFC 6068 asks.
    public static func link(
        for report: BugReport,
        subject: String,
        crashReportLeftOut: String
    ) throws -> (url: URL, leavesOutCrashReport: Bool) {
        let full = try mailto(subject: subject, body: text(of: report.body()))
        guard full.absoluteString.count > maximumURLLength, report.crashReport != nil else {
            return (full, false)
        }
        var shorter = report
        shorter.crashReport = nil
        let body = crashReportLeftOut + "\n\n" + (try text(of: shorter.body()))
        return (try mailto(subject: subject, body: body), true)
    }

    /// Only the unreserved ASCII characters stay as they are. `URLComponents` leaves `&`, `=` and
    /// `+` alone inside a query value, which would end the body early or turn a plus into a space.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func mailto(subject: String, body: String) throws -> URL {
        let encode = { (text: String) in
            text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: "\r\n")
                .addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        }
        let text = "mailto:\(address)?subject=\(encode(subject))&body=\(encode(body))"
        guard let url = URL(string: text) else { throw URLError(.badURL) }
        return url
    }

    private static func text(of body: Data) -> String {
        String(bytes: body, encoding: .utf8) ?? ""
    }
}
