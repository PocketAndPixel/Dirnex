import DirnexCore
import Foundation

@testable import Dirnex

/// Somebody else's WebDAV client, for the states a live test needs the server put in behind the
/// backend's back: a lock held elsewhere, a file rewritten by a colleague.
///
/// Its requests are spelled here by hand rather than built by `WebDAVProcessArguments`, so what it
/// does to the server does not depend on the code under test — the reason `LIVE-VERIFICATION.md`
/// gives for minting a probe's payload by hand. It shares only the process runner, which has no
/// protocol in it, and the paths it is given are plain ASCII, so no encoding rule is exercised by
/// both sides.
struct WebDAVOutsideClient {
    let endpoint: WebDAVLiveEndpoint

    /// What the server answered: the status, and the response headers as `curl` dumped them.
    struct Answer {
        let status: Int
        let headers: String

        /// The value of the first header named `name`, case-insensitively.
        func header(_ name: String) -> String? {
            for line in headers.split(whereSeparator: \.isNewline) {
                guard let colon = line.firstIndex(of: ":"),
                      line[..<colon].lowercased() == name.lowercased() else { continue }
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
    }

    /// Take an exclusive write lock on `backendPath` for five minutes, and return its token as the
    /// `Lock-Token` header spells it, angle brackets included, ready for ``unlock(_:token:)``.
    func lock(_ backendPath: String) throws -> String? {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:lockinfo xmlns:D="DAV:"><D:lockscope><D:exclusive/></D:lockscope>\
        <D:locktype><D:write/></D:locktype><D:owner>Dirnex live suite</D:owner></D:lockinfo>
        """
        let answer = try send("LOCK", backendPath, extra: [
            "-H", "Depth: 0",
            "-H", "Timeout: Second-300",
            "-H", "Content-Type: application/xml; charset=utf-8",
            "--data-binary", body
        ])
        return answer.status == 200 ? answer.header("Lock-Token") : nil
    }

    /// Release the lock `token` holds. RFC 4918 answers 204.
    func unlock(_ backendPath: String, token: String) throws -> Int {
        try send("UNLOCK", backendPath, extra: ["-H", "Lock-Token: \(token)"]).status
    }

    /// Replace `backendPath` with `data`, unconditionally — the colleague's save.
    func put(_ data: Data, at backendPath: String) throws -> Int {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-outside-\(UUID().uuidString)")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try send(nil, backendPath, extra: ["-T", file.path]).status
    }

    /// One request. The credentials go on stdin, as the app sends them, so even a throwaway
    /// password stays out of `argv`.
    private func send(_ method: String?, _ backendPath: String, extra: [String]) throws -> Answer {
        let location = endpoint.location
        let dialed = HostDialer(host: location.host).dialed
        var arguments = ["-q", "-s", "-S", "-o", "/dev/null", "-D", "-", "-w", "\n%{http_code}"]
        arguments += ["--connect-timeout", "15", "--max-time", "60"]
        if dialed.restrictsToIPv4 { arguments.append("-4") }
        if let pin = endpoint.trustedPublicKey {
            arguments += ["--insecure", "--pinnedpubkey", "sha256//\(pin)"]
        }
        var configuration: String?
        if !location.username.isEmpty {
            arguments.append(endpoint.expectedScheme == .digest ? "--digest" : "--basic")
            arguments += ["-K", "-"]
            configuration = WebDAVConfigFile.credentials(
                username: location.username,
                password: endpoint.password
            )
        }
        if let method { arguments += ["-X", method] }
        arguments += extra
        let path = location.rootPath + backendPath
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let scheme = location.usesTLS ? "https" : "http"
        arguments.append("\(scheme)://\(dialed.host):\(location.port)\(encoded)")

        let result = try CurlProcess.run(arguments, configuration: configuration, backstop: 90)
        let output = SubprocessText.lossyUTF8(result.standardOutput)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        let status = lines.last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        return Answer(status: status, headers: lines.dropLast().joined(separator: "\n"))
    }
}
