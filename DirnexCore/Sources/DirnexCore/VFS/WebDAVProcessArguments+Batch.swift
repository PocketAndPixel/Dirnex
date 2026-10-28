import Foundation

/// One folder a batched listing asks for, and the file `curl` is to write its multistatus into.
///
/// A file per section, for FTP's reason (``FTPListingRequest``): a body is a stranger's bytes, so
/// framing several of them on one stdout would let a name the server sends splice two answers
/// together. With every body in a file, stdout carries nothing but the sections' write-out lines.
public struct WebDAVListingRequest: Sendable, Equatable {
    /// The folder, as the backend holds it — the pane's path, mapped under the root by the builder.
    public let backendPath: String
    /// Where `curl` writes that folder's answer. Unique within one invocation.
    public let outputPath: String

    public init(backendPath: String, outputPath: String) {
        self.backendPath = backendPath
        self.outputPath = outputPath
    }
}

/// A batched invocation: the arguments, which carry no secret, and the multi-section config that
/// goes to stdin, which carries the credential once per section.
public struct WebDAVBatchInvocation: Sendable, Equatable {
    public let arguments: [String]
    public let configuration: String
}

/// What one section of a batched run came to.
public enum WebDAVBatchAnswer: Sendable, Equatable {
    /// The server answered, with any status. The body is the section's output file.
    case response(WebDAVHTTPResponse)
    /// The section ran and got no answer, or one cut short, named by its own exit code.
    case noAnswer(WebDAVTransportFailure)
    /// The run stopped before this section (`--fail-early`).
    case notSent
}

public extension WebDAVProcessArguments {
    /// The most folders one invocation may carry.
    ///
    /// FTP's number and its reasoning (``FTPProcessArguments/listingBatchLimit``): it bounds the
    /// config, the scratch files held at once and the process backstop, which is a sum here. It is
    /// not the connection's limit. Apache closes a kept-alive connection after 100 requests by
    /// default, and `curl` opens the next one by itself: measured 2026-10-23, 250 sections in one
    /// run made three connections, at sections 1, 102 and 203, and all 250 answered 207.
    static let listingBatchLimit = 200

    /// List several folders with `Depth: 1` in **one** `curl`, and so over one connection — the
    /// shape FTP's level walk has (``FTPProcessArguments/listDirectories(session:requests:credentials:)``),
    /// for the same reason: a request is cheap and a `curl` is not.
    ///
    /// Measured 2026-10-23 against macOS's Apache on loopback, through `curl` 8.7.1: four sections
    /// went over one connection (one client port, Apache's keep-alive count 0 to 3), and 250 took
    /// **0.04 s** against **1.48 s** as 250 separate runs. Loopback is the number to distrust: it
    /// leaves out the TCP and TLS handshakes this saves.
    ///
    /// ## One failed login, not one per folder
    ///
    /// Without a guard, a wrong password costs a refused login **per section**: four sections gave
    /// four 401s in Apache's log, and the NAS's Account Protection locks the account after a few.
    /// So the **first** section carries `fail`, and the run carries `--fail-early`: a 401 there ends
    /// the run before anything else is sent (measured: one request in the log, exit 22). Only the
    /// first, because `fail` would end the run on a folder's own 404 as well, and the later
    /// sections go out on a login the first has just proved. `next` resets per-section options, so
    /// `fail` given anywhere but the first section reaches nothing else.
    ///
    /// `--fail-early` stops the run on a section that got no answer too: a refused connection was
    /// one attempt with it and four without. What the first section's refusal leaves unsent is the
    /// caller's to send again (``WebDAVBackend``), since a 404 there is about that folder alone.
    ///
    /// Digest still costs its 401 per section, since `curl` keeps no nonce between transfers, but
    /// all of them go over the one connection (measured: eight requests, one port).
    ///
    /// ## Reading it
    ///
    /// Each section prints its own line on stdout, `dav-batch=<section> <status> <exit>` (with
    /// `%{exitcode}`, the section's own code rather than the run's), and writes its body to its
    /// file (``WebDAVBatchWriteOut``). A 404 is that section's answer and the next one runs.
    ///
    /// `credentials` is the config line, or `nil` when the session sends none. Built by the caller
    /// (``WebDAVConfigFile/credentials(username:password:)``), so this never sees a password.
    static func listings(
        session: WebDAVSession,
        requests: [WebDAVListingRequest],
        credentials: String?
    ) -> WebDAVBatchInvocation {
        let sections = requests.enumerated().map { index, request in
            listingSection(
                session: session,
                credentials: session.sendsCredentials ? credentials : nil,
                request: request,
                section: index,
                stopsOnRefusal: index == 0
            )
        }
        return WebDAVBatchInvocation(
            // `-q` first, for the reason ``common(session:showingProgress:)`` gives. No write-out
            // here: each section carries its own.
            arguments: ["-q", "-sS", "--fail-early"] + configFromStandardInput,
            configuration: sections.joined(separator: "next\n")
        )
    }

    /// One `Depth: 1` PROPFIND in config spelling. Every option is repeated per section, since
    /// `curl` reads one option set per transfer: the budget, the address family, the scheme and the
    /// credential, the pin, the request, then the write-out, the output file and the URL.
    private static func listingSection(
        session: WebDAVSession,
        credentials: String?,
        request: WebDAVListingRequest,
        section: Int,
        stopsOnRefusal: Bool
    ) -> String {
        var lines = [
            "connect-timeout = \(session.connectTimeout)\n",
            "max-time = \(session.maxTime)\n"
        ]
        if stopsOnRefusal { lines.append("fail\n") }
        lines += connectionLines(session: session, credentials: credentials)
        lines += [
            "request = \"PROPFIND\"\n",
            "header = \(FTPConfigFile.quote("Depth: \(WebDAVDepth.one.rawValue)"))\n",
            "header = \(FTPConfigFile.quote(#"Content-Type: application/xml; charset="utf-8""#))\n",
            "data-binary = \(FTPConfigFile.quote(propfindBody))\n",
            "write-out = \(FTPConfigFile.quote(WebDAVBatchWriteOut.format(section: section)))\n",
            "output = \(FTPConfigFile.quote(request.outputPath))\n",
            "url = \(FTPConfigFile.quote(url(session, request.backendPath, isCollection: true)))\n"
        ]
        return lines.joined()
    }

    /// How one section reaches the server, in config spelling: the address family, the scheme and
    /// the credential when the session sends one, and the pin over HTTPS. Every section of a run
    /// repeats them, since `curl` reads one option set per transfer.
    internal static func connectionLines(session: WebDAVSession, credentials: String?) -> [String] {
        var lines: [String] = []
        if session.dial.restrictsToIPv4 { lines.append("ipv4\n") }
        if session.sendsCredentials, let credentials, let scheme = session.authentication {
            lines.append(scheme == .digest ? "digest\n" : "basic\n")
            lines.append(credentials.hasSuffix("\n") ? credentials : credentials + "\n")
        }
        if session.location.usesTLS, case let .pinned(publicKey) = session.trust {
            lines.append("insecure\n")
            lines.append("pinnedpubkey = \(FTPConfigFile.quote("sha256//\(publicKey)"))\n")
        }
        return lines
    }
}

/// The per-section write-out of a batched listing, and the reader that turns a run's stdout into
/// one ``WebDAVBatchAnswer`` per section.
public enum WebDAVBatchWriteOut {
    static let label = "dav-batch="

    /// The section's line: its index, the status and its own exit code.
    static func format(section: Int) -> String {
        "\(label)\(section) %{http_code} %{exitcode}\n"
    }

    /// One answer per section, in order, from the run's stdout and each section's body.
    ///
    /// A section is answered by the rule ``WebDAVWriteOut/response(exitCode:standardOutput:standardError:)``
    /// applies to a whole run, read off the section's own exit code: 0 is a response, 22 with a 4xx
    /// or 5xx is `fail`'s refusal and a response too, and anything else got no answer, whatever
    /// status it had seen. A section with no line was never sent.
    ///
    /// The **last** line for a section wins. Every body goes to a file, so nothing but these lines
    /// should reach stdout; if a body ever did, it would come before its own section's line, and a
    /// line it forged for a later section would come before that section's real one.
    public static func answers(
        sections: Int,
        standardOutput: String,
        body: (Int) -> Data
    ) -> [WebDAVBatchAnswer] {
        var reported: [Int: (status: Int, exit: Int32)] = [:]
        for line in standardOutput.split(whereSeparator: \.isNewline) where line.hasPrefix(label) {
            let fields = line.dropFirst(label.count).split(separator: " ")
            guard fields.count == 3,
                  let section = Int(fields[0]), (0..<sections).contains(section),
                  let status = Int(fields[1]),
                  let exit = Int32(fields[2])
            else { continue }
            reported[section] = (status, exit)
        }
        return (0..<sections).map { section in
            guard let (status, exit) = reported[section] else { return .notSent }
            guard WebDAVWriteOut.isAnswer(status: status, exitCode: exit) else {
                return .noAnswer(.classify(curlExit: exit))
            }
            return .response(WebDAVHTTPResponse(status: status, body: body(section)))
        }
    }
}
