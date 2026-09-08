import Foundation

/// Builds the `curl` config file fed on **stdin** (`-K -`) — the one place a password appears, and
/// the reason it never appears in `argv` or on disk.
///
/// The escaping is not cosmetic. Probed 2026-07-25: a value containing an unescaped newline makes
/// `curl` read the remainder as further *config directives* and abort with
/// `'"' is unknown` — so an unescaped newline in a password is a config-injection surface, not a
/// formatting bug. `curl`'s config parser honors `\\`, `\"`, `\t`, `\r` and `\n` inside a
/// double-quoted value; all five are emitted.
public enum FTPConfigFile {
    /// The config text authenticating `location`, with `password` for a named account. Returns the
    /// anonymous form when the location is anonymous, in which case `password` is ignored — the
    /// conventional e-mail-shaped string is used and nothing is read from the Keychain.
    public static func credentials(for location: FTPLocation, password: String) -> String {
        let secret = location.isAnonymous ? anonymousPassword : password
        return "user = \(quote("\(location.username):\(secret)"))\n"
    }

    /// What the public login sends as its password. Any e-mail-shaped string is conventional; this
    /// one names the client without leaking anything about the user.
    public static let anonymousPassword = "dirnex@example.com"

    /// Quote a value for `curl`'s config parser, escaping every character that would otherwise end
    /// the value or start a new directive.
    static func quote(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }
}

/// Builds the raw FTP commands sent with `curl -Q`. Pure and tested because this is the one place a
/// file name reaches the control connection **unquoted**.
///
/// FTP has no quoting: a command is a verb, a space, and the rest of the line as the argument, so a
/// name containing CR or LF would end the command and start another one the user never asked for —
/// `DELE a\r\nDELE important.txt` is two commands. There is nothing to escape it *with*, so such a
/// path is refused outright rather than sanitized. POSIX and Windows both forbid these characters
/// in names, so nothing legitimate is lost.
public enum FTPQuoteCommand {
    /// A path that cannot be expressed as an FTP command argument.
    public struct UnsafePath: Error, Equatable {
        public let path: String
    }

    public static func makeDirectory(_ remotePath: String) throws -> String {
        try command("MKD", remotePath)
    }

    public static func removeDirectory(_ remotePath: String) throws -> String {
        try command("RMD", remotePath)
    }

    public static func removeFile(_ remotePath: String) throws -> String {
        try command("DELE", remotePath)
    }

    /// The rename pair, in the order they must be sent: `RNFR` names the source, `RNTO` the
    /// destination, and the server keeps the pending rename between them — so they only work sent
    /// together on one connection.
    public static func rename(_ source: String, to destination: String) throws -> [String] {
        [try command("RNFR", source), try command("RNTO", destination)]
    }

    /// The command that sets a remote item's mode: `SITE CHMOD 754 path`.
    ///
    /// `SITE` commands are by definition per-server, so this is an extension a server need not
    /// implement and the refusal has to be handled rather than prevented — an unimplemented verb
    /// answers **500** where a file problem answers **550**, which is the distinction that keeps
    /// "this server cannot keep modes" and "that file is not there" from becoming one sentence.
    public static func changeMode(_ remotePath: String, to permissions: POSIXPermissions) throws -> String {
        try command("SITE CHMOD \(String(permissions.rawValue, radix: 8))", remotePath)
    }

    /// The command that sets a remote item's modification time: `MFMT 20180607080910 path`.
    ///
    /// **Exact to the second and anchored to UTC**, which is RFC 3659 and was verified against a
    /// real server rather than assumed — the coarse, year-less, zone-less stamp FTP is known for
    /// belongs to `LIST` alone. So an FTP transfer can carry a modification time exactly even though
    /// a listing cannot report one, which is the asymmetry that makes this worth sending.
    ///
    /// There is no counterpart for an access time: `SITE UTIME` is answered `500` here.
    public static func setModificationTime(_ remotePath: String, to date: Date) throws -> String {
        try command("MFMT \(timestamp(date))", remotePath)
    }

    /// The commands that carry a transfer's metadata, in the order they must be sent.
    ///
    /// **These ride their own `curl`, after the transfer, and that is a measurement rather than a
    /// preference.** A quote command sent alongside the transfer is refused as `curl` **exit 21**,
    /// which fails the whole invocation *after* the bytes have landed — a successful upload reported
    /// as a failed copy (2026-08-28, against a real FTP server: 16 bytes up, exit 21). `curl`'s
    /// continue-on-failure prefix avoids that and costs the attribution: `%{http_code}` reports only
    /// the **last** reply, so a refused `SITE CHMOD` behind a good `MFMT` is invisible, and a
    /// connection can never learn which verb it lacks. Sent on their own the answer is exact — exit
    /// 21 with reply **500** is *this server has no such verb* and worth latching, **550** is *that
    /// file's problem* and is not, which is the split ``FTPTransportError/classify(exitCode:stderr:)``
    /// already reads.
    ///
    /// One invocation carries both, so a file pays at most one extra login rather than one per step;
    /// `curl` stops at the first refusal, which is what attributes it.
    ///
    /// A step this protocol cannot spell is skipped rather than approximated — FTP has no verb for an
    /// access time (`SITE UTIME` is answered 500 here), and the plan has already counted it dropped.
    public static func metadataSteps(_ steps: [RemoteMetadataStep], on remotePath: String) throws -> [
        String
    ] {
        try steps.compactMap { step in
            switch step {
            case let .setMode(mode): return try changeMode(remotePath, to: mode)
            case let .setModificationTime(date): return try setModificationTime(remotePath, to: date)
            case .preserveDuringTransfer: return nil // no such flag on this wire
            }
        }
    }

    /// `MFMT`'s `YYYYMMDDHHMMSS`, always in UTC. Built with an explicit POSIX locale and zone rather
    /// than a default-configured formatter, so the wire format cannot follow whoever is running the
    /// app (docs/NOTES.md ▸ Localization).
    static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return String(
            format: "%04d%02d%02d%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    /// A verb and its raw path argument, rejecting anything that could inject a second command.
    static func command(_ verb: String, _ remotePath: String) throws -> String {
        guard isSafe(remotePath) else { throw UnsafePath(path: remotePath) }
        return "\(verb) \(remotePath)"
    }

    /// Whether a path can be sent as a command argument: no line breaks, and not empty. NUL is
    /// refused too — it cannot appear in a POSIX name and would truncate the C string.
    static func isSafe(_ remotePath: String) -> Bool {
        !remotePath.isEmpty && !remotePath.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\0" }
    }
}
