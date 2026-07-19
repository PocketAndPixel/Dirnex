import Foundation

/// The non-hermetic boundary beneath an `SFTPBackend`: it performs remote operations over an
/// SSH/SFTP connection and hands back raw output for the backend to parse. Everything above it —
/// path handling, listing parsing, capability reporting, error mapping — is pure and tested in
/// `DirnexCore`; the transport is where real network I/O lives, so it is injected (PLAN.md §2 "the
/// app is a thin client").
///
/// The app supplies a `Process`-driven implementation over the system `sftp` tool — the same move
/// M4 made with `bsdtar` instead of linking libarchive, sidestepping a heavyweight dependency
/// (swift-nio-ssh/libssh2). Tests supply a fake that returns canned listings, so the whole backend
/// is exercised without a server.
///
/// `sftp`'s batch `ls -la` both lists a directory (many rows) and stats a single item (one row,
/// or — for a directory — a self `.` row whose stat *is* the directory's), so `SFTPBackend`
/// interprets one raw listing for both. The write primitives each map onto one `sftp` batch verb
/// (`mkdir`/`rename`/`rm`/`rmdir`/`ln`/`get`/`put`); the backend composes them (e.g. it empties a
/// directory before `rmdir`, since `sftp` has no recursive remove). Every method is synchronous and
/// may block on the network — the backend is always called off the main thread by the operation
/// engine and the panel's background list, never on it.
public protocol SFTPTransport: Sendable {
    /// The raw `sftp` `ls -la` output for `remotePath` — one entry per line. For a directory this
    /// is its children (each printed as a full path, plus the `.`/`..` self/parent rows); for a
    /// file it is that single file's row. Throws `SFTPTransportError` on a remote failure.
    func listDirectory(_ remotePath: String) throws -> String

    /// Create a single remote directory (`mkdir`). Throws on any failure (the parent is missing,
    /// something already occupies the path, permission denied) — the backend never relies on
    /// intermediate directories being created, mirroring `mkdir(2)`.
    func makeDirectory(_ remotePath: String) throws

    /// Rename or move a remote item within the account (`rename`). Only valid within one
    /// connection; a cross-backend move is copy-then-delete, decided above the transport.
    func rename(_ source: String, to destination: String) throws

    /// Remove a remote regular file or symbolic link (`rm`) — the link itself, never its target.
    /// Directories are emptied and removed with `removeDirectory` by the backend.
    func removeFile(_ remotePath: String) throws

    /// Remove an *empty* remote directory (`rmdir`); the backend deletes the contents first, since
    /// `sftp` has no recursive remove.
    func removeDirectory(_ remotePath: String) throws

    /// Create a remote symbolic link at `remotePath` pointing at the raw (unresolved) `target`
    /// (`ln -s`) — used when a copied/mirrored tree contains a symlink.
    func createSymbolicLink(_ remotePath: String, target: String) throws

    /// Download the remote file at `remotePath` to a local path (`get`, or `get -a` to **resume**),
    /// returning the local file's total size once the transfer finishes. When `resume` is true the
    /// download picks up from the local file's current length instead of restarting, so `sftp`
    /// fetches only the bytes past that offset — the caller computes the transferred delta from the
    /// pre-existing size (see `SFTPBackend.copyFile`).
    @discardableResult
    func download(_ remotePath: String, to localPath: String, resume: Bool) throws -> Int64

    /// Upload the local file at `localPath` to a remote path (`put`, or `put -a` to **resume**),
    /// returning the local source's size (which is the remote file's total size once the transfer
    /// finishes). When `resume` is true the upload picks up from the remote file's current length,
    /// so `sftp` sends only the bytes past that offset.
    @discardableResult
    func upload(_ localPath: String, to remotePath: String, resume: Bool) throws -> Int64
}

/// A remote operation's failure, in the few shapes the backend needs to distinguish so it can map
/// them onto the shared `VFSError` vocabulary (a missing path, a denied path, or everything else).
/// `classify(stderr:)` turns a nonzero `sftp` invocation's stderr into one of these, tested here so
/// the app transport stays a thin spawn-and-classify shell.
public enum SFTPTransportError: Error, Sendable, Equatable {
    /// The remote path does not exist (`sftp`: `Can't ls: "…" not found`).
    case notFound
    /// The remote account may not read the path (`sftp`: `remote readdir("…"): Permission denied`).
    case permissionDenied
    /// The server presented a host key that differs from the one pinned in `known_hosts` — OpenSSH's
    /// "REMOTE HOST IDENTIFICATION HAS CHANGED" refusal. Carries the parsed details so the app can
    /// show the new fingerprint and, on the user's explicit confirmation, drop the stale pin and
    /// reconnect. Usually a reinstalled or replaced server, but it *can* be a man-in-the-middle — so
    /// it's a distinct case that drives a warning, never a silent retry.
    case hostKeyChanged(SFTPHostKeyChange)
    /// Any other failure — a dropped connection, an auth failure, an unexpected error — with a
    /// human-readable reason for logs and the UI.
    case failure(String)

    /// Classify a failed `sftp` batch invocation's stderr. The two recoverable shapes a browse
    /// hits — a vanished path and an unreadable one — get their own semantic cases so the panel
    /// reacts correctly; anything else is surfaced verbatim.
    public static func classify(stderr: String) -> SFTPTransportError {
        // A changed host key is the most specific, security-critical shape — match it before the
        // generic permission/not-found text so the app can offer to re-trust the new key rather than
        // showing a dead-end error.
        if let change = SFTPHostKeyChange.parse(stderr: stderr) {
            return .hostKeyChanged(change)
        }
        let text = stderr.lowercased()
        // Permission denied is checked first: a failed key-auth attempt prints both an
        // "identity file … no such file" warning *and* "Permission denied", and the latter is the
        // actionable diagnosis (check the username/key), not a vanished remote path.
        if text.contains("permission denied") {
            return .permissionDenied
        }
        if text.contains("not found") || text.contains("no such file") {
            return .notFound
        }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(trimmed.isEmpty ? "The SFTP server reported an error." : trimmed)
    }

    /// An error found in the stderr of an interactive (password-auth) session that *exited zero*, or
    /// `nil` if the stderr shows no failure. `sftp` in interactive mode doesn't abort on a bad
    /// command — it prints one error line and carries on — so the transport can't rely on the exit
    /// code there and scans for `sftp`'s error lines instead. Benign lines (`Connected to …`, a
    /// server banner, a `Warning: Permanently added …` host-key note) match none of these and yield
    /// `nil`, so a successful command isn't mistaken for a failure.
    public static func detect(stderr: String) -> SFTPTransportError? {
        // Match the changed-key refusal first, for the same reason `classify` does. (A host-key
        // failure aborts the connection so `sftp` exits non-zero — `classify`'s path — but scanning
        // here too keeps both entry points consistent if a session ever surfaces it exit-zero.)
        if let change = SFTPHostKeyChange.parse(stderr: stderr) {
            return .hostKeyChanged(change)
        }
        let lowered = stderr.lowercased()
        if lowered.contains("permission denied") { return .permissionDenied }
        if lowered.contains("not found") || lowered.contains("no such file") { return .notFound }
        // `sftp` prints one failed-command line per error; these forms cover the write verbs
        // (mkdir/rename/rm/get/put) whose failure text ends in ": Failure" or starts "Couldn't …".
        for line in stderr.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces).lowercased()
            if text.hasPrefix("can't ") || text.hasPrefix("couldn't ") || text.hasPrefix("cannot ")
                || text.hasPrefix("remote ") || text.hasSuffix(": failure") {
                return .failure(line.trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}

/// The parsed details of an OpenSSH "REMOTE HOST IDENTIFICATION HAS CHANGED" refusal: enough to warn
/// the user which key changed and to what fingerprint, and to repair the stale pin afterwards. Pure
/// and tested so this security-sensitive parsing is verified without a server, like the rest of this
/// file. Every field is best-effort — a missing one is left empty/zero rather than failing the whole
/// parse — so the app still reaches the re-trust path even if OpenSSH's wording drifts.
public struct SFTPHostKeyChange: Sendable, Equatable {
    /// The host whose key changed, as OpenSSH names it (usually the address the user connected to).
    public let host: String
    /// The key algorithm, e.g. `ED25519` or `RSA`; empty if the message didn't name it.
    public let keyType: String
    /// The key the server now presents, e.g. `SHA256:HAuu…`; empty if it couldn't be parsed.
    public let fingerprint: String
    /// The `known_hosts` file holding the stale pin, as OpenSSH reported it; empty if not found.
    public let knownHostsFile: String
    /// The 1-based line of the offending entry in `knownHostsFile`, or 0 if not reported.
    public let line: Int

    public init(
        host: String,
        keyType: String,
        fingerprint: String,
        knownHostsFile: String,
        line: Int
    ) {
        self.host = host
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.knownHostsFile = knownHostsFile
        self.line = line
    }

    /// Parse `sftp`/`ssh` stderr into a host-key-change descriptor, or `nil` when it is not a
    /// changed-key refusal. Only the unambiguous "REMOTE HOST IDENTIFICATION HAS CHANGED" banner
    /// triggers a match: the app connects with `StrictHostKeyChecking=accept-new`, so an *unknown*
    /// host is pinned silently and never reaches here — only a *changed* key does.
    public static func parse(stderr: String) -> SFTPHostKeyChange? {
        guard stderr.lowercased().contains("remote host identification has changed") else {
            return nil
        }
        let (file, line) = offendingEntry(in: stderr)
        return SFTPHostKeyChange(
            host: value(in: stderr, between: "Host key for ", and: " has changed"),
            keyType: keyType(in: stderr),
            fingerprint: fingerprint(in: stderr),
            knownHostsFile: file,
            line: line
        )
    }

    /// The substring between the first `prefix` and the next `suffix` after it, or "" if either is
    /// absent. The markers sit on one line in OpenSSH's message, so the result never spans lines.
    private static func value(in text: String, between prefix: String, and suffix: String) -> String {
        guard let start = text.range(of: prefix),
              let end = text.range(of: suffix, range: start.upperBound..<text.endIndex) else {
            return ""
        }
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// The key algorithm, preferring the "Offending <type> key in …" line and falling back to the
    /// "for the <type> key sent by …" line.
    private static func keyType(in text: String) -> String {
        let offending = value(in: text, between: "Offending ", and: " key in ")
        return offending.isEmpty ? value(in: text, between: "for the ", and: " key sent by") : offending
    }

    /// The SHA256 (or MD5) fingerprint token, stripped of the sentence's trailing period.
    private static func fingerprint(in text: String) -> String {
        for prefix in ["SHA256:", "MD5:"] {
            guard let range = text.range(of: prefix) else { continue }
            let token = text[range.lowerBound...].prefix { !$0.isWhitespace }
            return String(token).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        return ""
    }

    /// The stale entry's file and 1-based line from "Offending … key in <file>:<line>".
    private static func offendingEntry(in text: String) -> (file: String, line: Int) {
        for raw in text.split(whereSeparator: \.isNewline) {
            let lineText = raw.trimmingCharacters(in: .whitespaces)
            // Anchor on the "Offending … key in …" line specifically: another line ("Add correct
            // host key in …") also contains " key in " but isn't the stale entry's location.
            guard lineText.lowercased().hasPrefix("offending "),
                  let range = lineText.range(of: " key in ") else { continue }
            let location = String(lineText[range.upperBound...])
            guard let colon = location.lastIndex(of: ":"),
                  let number = Int(location[location.index(after: colon)...]) else {
                return (location, 0)
            }
            return (String(location[..<colon]), number)
        }
        return ("", 0)
    }
}

/// Formats the `ssh-keygen -R` target for a host, matching how OpenSSH keys `known_hosts` entries: a
/// bare host on the default port, or the bracketed `[host]:port` form otherwise. Pure and tested so
/// the app's repair (dropping a stale pin) aims at exactly the entry OpenSSH refused on.
public enum SFTPKnownHosts {
    public static func removalTarget(host: String, port: Int) -> String {
        port == SFTPLocation.defaultPort ? host : "[\(host)]:\(port)"
    }
}

/// Builds the `sftp` batch commands the transport feeds on stdin. Pure and tested so the escaping —
/// the one place a remote path with spaces or quotes could break the command — is verified without
/// a server. `sftp`'s batch parser splits on whitespace but honours double quotes and backslash
/// escapes, so a path is wrapped in quotes with `\` and `"` escaped.
public enum SFTPBatchCommand {
    /// The batch line that lists (or stats) `remotePath`: `ls -la "…"`.
    public static func list(_ remotePath: String) -> String {
        "ls -la \(quote(remotePath))"
    }

    /// The batch line that creates a remote directory: `mkdir "…"`.
    public static func makeDirectory(_ remotePath: String) -> String {
        "mkdir \(quote(remotePath))"
    }

    /// The batch line that renames/moves a remote item: `rename "src" "dst"`.
    public static func rename(_ source: String, to destination: String) -> String {
        "rename \(quote(source)) \(quote(destination))"
    }

    /// The batch line that removes a remote file or symlink: `rm "…"`.
    public static func removeFile(_ remotePath: String) -> String {
        "rm \(quote(remotePath))"
    }

    /// The batch line that removes an empty remote directory: `rmdir "…"`.
    public static func removeDirectory(_ remotePath: String) -> String {
        "rmdir \(quote(remotePath))"
    }

    /// The batch line that creates a remote symbolic link: `ln -s "target" "link"` (`sftp`'s `ln`
    /// takes the existing target first, the new link path second, like `ln(1)`).
    public static func createSymbolicLink(_ remotePath: String, target: String) -> String {
        "ln -s \(quote(target)) \(quote(remotePath))"
    }

    /// The batch line that downloads a remote file to a local path: `get "remote" "local"`, or
    /// `get -a "remote" "local"` to **resume** — `sftp` seeks to the local file's current length and
    /// fetches only the remainder, instead of restarting from zero.
    public static func download(_ remotePath: String, to localPath: String, resume: Bool = false) -> String {
        "get \(resume ? "-a " : "")\(quote(remotePath)) \(quote(localPath))"
    }

    /// The batch line that uploads a local file to a remote path: `put "local" "remote"`, or
    /// `put -a "local" "remote"` to **resume** — `sftp` seeks past the remote file's current length
    /// and sends only the remainder.
    public static func upload(_ localPath: String, to remotePath: String, resume: Bool = false) -> String {
        "put \(resume ? "-a " : "")\(quote(localPath)) \(quote(remotePath))"
    }

    /// The batch line that prints the remote working directory (`pwd`), used to discover the home
    /// directory to land in on connect.
    public static let printWorkingDirectory = "pwd"

    static func quote(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// How the CLI-driven transport authenticates against a server. Carries no secret for `.password`:
/// the password is resolved from the Keychain by the app and fed to `sftp` out-of-band via an
/// `SSH_ASKPASS` helper (never on the command line, never in this value, never on disk), so an auth
/// *method* is safe to describe and thread around like an `SFTPLocation`.
public enum SFTPAuthentication: Sendable, Hashable, Codable {
    /// Public-key auth with the private key at `identityFile` — `sftp`'s native non-interactive path.
    case key(identityFile: String)
    /// Password auth; the password is supplied out-of-band, never held here.
    case password
}

/// Builds the `sftp` process arguments (after the executable path) for a one-command session. Pure
/// and tested so the security-sensitive flag assembly — which auth methods are offered, and crucially
/// whether the interactive password prompt is enabled — is verified without spawning `sftp`, the
/// same reason `SFTPBatchCommand` is pure.
///
/// The two modes differ fundamentally, verified live against OpenSSH 10:
/// - **Key auth uses `-b -`**: quiet, fail-fast batch semantics (no `sftp>` echo, a non-zero exit on
///   a failed command). `-b` also forces `-oBatchMode=yes` onto `ssh`, which is what makes key auth
///   fully non-interactive. This is the shipped, verified browse/transfer path — left untouched.
/// - **Password auth cannot use `-b`**: it forces `BatchMode=yes`, which disables the password prompt
///   entirely (`ssh` would report "no more authentication methods"). So password auth runs `sftp`
///   *interactively* over a piped stdin — the prompt is answered out-of-band by `SSH_ASKPASS` — which
///   means stdout carries `sftp>` echo lines (`SFTPListingParser` skips them) and a failed command
///   exits zero (so the transport must scan stderr with `detect(stderr:)`, not just the exit code).
///   Only the `password` method is offered: `keyboard-interactive` stalls for a minute on a *wrong*
///   password when `SSH_ASKPASS` auto-answers it (macOS PAM), which would hang the pane on a typo;
///   and `PubkeyAuthentication=no` stops a machine's stray authorized key from bypassing the choice.
public enum SFTPProcessArguments {
    public static func batch(
        location: SFTPLocation,
        authentication: SFTPAuthentication,
        connectTimeout: Int
    ) -> [String] {
        let common = [
            "-o", "ConnectTimeout=\(connectTimeout)",
            // Trust-on-first-use: a fresh host is added to known_hosts, a *changed* key still fails.
            "-o", "StrictHostKeyChecking=accept-new",
            "-P", String(location.port)
        ]
        let target = "\(location.username)@\(location.host)"
        switch authentication {
        case let .key(identityFile):
            return ["-i", identityFile, "-o", "BatchMode=yes"] + common + ["-b", "-", target]
        case .password:
            // No `-b`: it would disable the prompt. Interactive over piped stdin; `SSH_ASKPASS`
            // answers the prompt (wired by the transport's environment).
            return [
                "-o", "PreferredAuthentications=password",
                "-o", "PubkeyAuthentication=no",
                // One attempt, so a wrong password fails fast instead of re-prompting three times.
                "-o", "NumberOfPasswordPrompts=1"
            ] + common + [target]
        }
    }
}
