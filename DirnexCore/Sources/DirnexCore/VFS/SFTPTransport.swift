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
/// The four write verbs come from ``RemoteWriteTransport``, shared with `FTPTransport`; over SFTP
/// they are `mkdir`, `rename`, `rm` (the link itself, never its target) and `rmdir`. `sftp` has no
/// recursive remove, so `RemoteTransportBackend` empties a directory depth-first before `rmdir`.
public protocol SFTPTransport: RemoteWriteTransport {
    /// The raw `sftp` `ls -la` output for `remotePath` — one entry per line. For a directory this
    /// is its children (each printed as a full path, plus the `.`/`..` self/parent rows); for a
    /// file it is that single file's row. Throws `SFTPTransportError` on a remote failure.
    func listDirectory(_ remotePath: String) throws -> String

    /// Create a remote symbolic link at `remotePath` pointing at the raw (unresolved) `target`
    /// (`ln -s`) — used when a copied/mirrored tree contains a symlink.
    func createSymbolicLink(_ remotePath: String, target: String) throws

    /// Download the remote file at `remotePath` to a local path (`get`, or `get -a` to **resume**),
    /// returning the local file's total size once the transfer finishes. When `resume` is true the
    /// download picks up from the local file's current length instead of restarting, so `sftp`
    /// fetches only the bytes past that offset — the caller computes the transferred delta from the
    /// pre-existing size (see `SFTPBackend.copyFile`).
    ///
    /// `isCancelled` is polled **while the bytes move**, and only the two byte-moving verbs take it
    /// — see ``upload(_:to:resume:progress:isCancelled:)``. `progress` rides the same poll and
    /// reports **deltas** as they land, read from the destination file on this machine growing:
    /// exact, free, and available whatever `sftp` chooses to print.
    @discardableResult
    func download(
        _ remotePath: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64

    /// Download several byte ranges of one remote file **at once**, each into its own file, for the
    /// caller to join (``SegmentAssembly``).
    ///
    /// **Not SFTP at all, and it cannot be**: the system `curl` is built without libssh2 — its
    /// protocol list carries no `sftp` and no `scp` — and `sftp(1)` has no range verb (`get -a`
    /// resumes to EOF, with no way to stop). So the one-`curl -Z`-with-N-sections shape that serves
    /// S3 and FTP does not exist here, and each segment is an SSH **exec** channel running
    /// ``SSHSegmentCommand``: the second thing this project asks an SSH account to do, after §M22's
    /// subtree search. That brings §M22's caveat with it — an account confined to the `sftp`
    /// subsystem has no exec channel and answers with prose, on *stdout*, where a piece's bytes
    /// would go — so this can be refused by a perfectly healthy server and the caller has to be
    /// ready to fall back.
    ///
    /// It **throws on any failure of the run** rather than reporting per segment, for a reason of
    /// its own: a pipeline's exit status is its last stage's, so a `tail` that could not open the
    /// file is masked by a `head` that exits 0 — measured, a missing remote path gives `ssh` exit 0
    /// and a zero-byte piece. The pieces' lengths are the evidence, and ``SegmentAssembly`` weighs
    /// them.
    ///
    /// Additive, with a default that **forwards** to the plain download: a single stream produces
    /// the identical file, so a transport that has not implemented this is slow and never wrong.
    @discardableResult
    func downloadSegments(
        _ segments: [DownloadSegment],
        of remotePath: String,
        to localPath: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> SegmentedDownloadOutcome

    /// Upload the local file at `localPath` to a remote path (`put`, or `put -a` to **resume**),
    /// returning the local source's size (which is the remote file's total size once the transfer
    /// finishes). When `resume` is true the upload picks up from the remote file's current length,
    /// so `sftp` sends only the bytes past that offset.
    ///
    /// **`isCancelled` is polled while the transfer runs, and a metadata verb deliberately has no
    /// such parameter.** A transfer is one `sftp` that may run for an hour, so a caller's Stop has
    /// to reach inside it; a listing is over before anyone could press anything. Measured
    /// 2026-08-14 on the S3 transport, whose shape this one shares exactly: without it, Stop on a
    /// 16-second download returned after the full 16 seconds having downloaded the whole file and
    /// then discarded it (docs/NOTES.md ▸ curl for S3).
    ///
    /// **`progress` is here for symmetry with ``download(_:to:resume:progress:isCancelled:)`` and
    /// the shipped transport does not call it, because `sftp` gives an upload no observable at
    /// all.** Nothing local changes while bytes go out, and — unlike `curl` — `sftp` prints no
    /// meter a spawned process can read. Probed 2026-08-16 against a real `sshd` over a 1 GiB
    /// transfer, six ways: `-b -` and interactive, stdout on a pipe and on a PTY, and with the
    /// `progress` batch command explicitly enabling it (`Progress meter enabled`, then silence).
    /// Every one of them printed the echoed command and nothing else for the whole three seconds.
    /// OpenSSH draws the meter only for a foreground process group on a controlling terminal, which
    /// a spawned child is not. The remaining route — polling the *remote* size — is a fresh
    /// connection and handshake per tick on a transport with no session, so an upload reports once,
    /// at the end, and says so rather than inventing a number.
    @discardableResult
    func upload(
        _ localPath: String,
        to remotePath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64

    /// Run `command` on the server through an SSH **exec** channel and hand back its standard
    /// output — or `nil` when this connection has no exec channel to run it on (PLAN.md §M22
    /// Slice 4).
    ///
    /// This is the one verb that is not SFTP at all: it is the *other* thing an SSH connection can
    /// do, and it exists so a search can have the server walk its own tree with `find` rather than
    /// paying a connection per directory. It is therefore allowed to be unavailable in a way no
    /// other verb is — an account confined to the `sftp` subsystem (`ForceCommand internal-sftp`)
    /// refuses exec requests while browsing and transferring perfectly.
    ///
    /// **Neither `nil` nor the exit status detects that**, and the difference matters because the
    /// natural design gets it backwards. Probed 2026-08-16 against a real `sshd`: an `sftp`-only
    /// account answers an exec request with prose on **stdout**, exit 1 and an empty stderr, which
    /// from a transport's side is indistinguishable from a shell that ran something — while `find`
    /// answers exit 1 *with correct rows* whenever one subdirectory was unreadable. So the status
    /// is not returned at all, `nil` means only "could not ask" (nothing launched, or the server
    /// never replied), and deciding whether an answer is an answer is ``SSHFindListingParser``'s
    /// job, since it is the only thing here that knows what one looks like.
    ///
    /// `isCancelled` is polled while the command runs, for the same reason the two byte-moving verbs
    /// take it: a `find` over a large tree is a single long-running child, and a Stop that could
    /// only be noticed once it finished would not be a Stop.
    ///
    /// The default answers `nil`, so a transport that has no use for this — and every existing test
    /// double — inherits "there is no shortcut here" and the caller walks.
    func runCommand(_ command: String, isCancelled: () -> Bool) throws -> String?
}

public extension SFTPTransport {
    func runCommand(_ command: String, isCancelled: () -> Bool) throws -> String? { nil }

    /// The additive half of ``downloadSegments(_:of:to:progress:isCancelled:)``: a transport that
    /// predates segmented downloads keeps compiling and keeps working.
    ///
    /// It forwards rather than throwing — the test this project applies before letting a default
    /// stand in is whether the caller can tell it was not honoured, and here the two paths produce
    /// the identical file.
    @discardableResult
    func downloadSegments(
        _ segments: [DownloadSegment],
        of remotePath: String,
        to localPath: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> SegmentedDownloadOutcome {
        .whole(bytes: try download(
            remotePath,
            to: localPath,
            resume: false,
            progress: progress,
            isCancelled: isCancelled
        ))
    }
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
