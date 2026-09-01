import Foundation

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
    /// The server does not offer OpenSSH's `copy-data` extension, so it cannot duplicate a file
    /// without the bytes crossing this machine — `sftp`'s own
    /// `Server does not support copy-data extension`, printed by the *client* after reading what the
    /// server advertised.
    ///
    /// Its own case rather than a ``failure(_:)`` because it is the one refusal here that is a fact
    /// about the **account** rather than about the two paths: it is true of every file, so a backend
    /// latches it for the connection (``ServerSideCopySupport``) and stages the rest of that
    /// session's copies instead. Matching a case is also what keeps that decision off a sentence —
    /// the alternative is each caller re-deriving the string, which is how a re-worded message
    /// silently costs every copy its fast path.
    ///
    /// Reproduced on demand with `sftp-server -P copy-data`, which is how an old or restricted
    /// server behaves: exit 1, that line on stderr, and **nothing created**.
    case copyExtensionUnavailable
    /// Any other failure — a dropped connection, an auth failure, an unexpected error — carrying
    /// the server's own text, verbatim.
    ///
    /// **Empty when the server said nothing**, deliberately: this is the remote's words, not ours,
    /// and the core has no business authoring a sentence it cannot translate (PLAN.md §M12
    /// Slice 11). The app supplies a localized stand-in for the empty case, exactly as it already
    /// owns the wording for ``notFound``, ``permissionDenied`` and ``hostKeyChanged``.
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
        if mentionsMissingCopyExtension(stderr) { return .copyExtensionUnavailable }
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
        return .failure(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
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
        // Checked here and not only in `classify` because this is the direction where missing it is
        // silent: an interactive session exits **zero** on a failed command, so a `cp` the client
        // refused would otherwise be read as a copy that happened. None of the prefixes below
        // matches OpenSSH's sentence — it starts "Server does not…" — so without this line the
        // account would report a duplicate it never made.
        if mentionsMissingCopyExtension(stderr) { return .copyExtensionUnavailable }
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

    /// Whether this stderr is the client saying the server has no `copy-data` extension.
    ///
    /// Matched as OpenSSH's **whole sentence**, read out of `/usr/bin/sftp` rather than paraphrased.
    /// The tempting shorter match is the distinctive token `copy-data`, and it is wrong in the
    /// expensive direction: a remote path may contain those characters, so a failed `rm` of a file
    /// somebody called `copy-data.txt` would answer yes and latch a capability the server has.
    private static func mentionsMissingCopyExtension(_ stderr: String) -> Bool {
        stderr.lowercased().contains("server does not support copy-data extension")
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
