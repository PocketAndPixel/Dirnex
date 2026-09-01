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

    /// Whether ``uploadParts(_:progress:isCancelled:)`` really does send them at once.
    ///
    /// **A declaration, not an inference, and the reason is that this route is worth nothing
    /// without it.** A segmented upload buys concurrency and a progress bar that moves; it *costs* a
    /// slice on this disk, one connection per part, the destination's size again in scratch on the
    /// server, and two more round trips for the join and the rename. Sent one part at a time that is
    /// a worse deal than the single `put` it replaced — so a transport that has not implemented the
    /// concurrent send must not be handed the route at all, and only it can say whether it has.
    ///
    /// The same shape ``RemoteWriteTransport/metadataCapabilities`` already has, for the same
    /// reason: declaring it is an obligation to implement the verb below, and the `false` default is
    /// what keeps a transport that has not done so honest. It is read *before* the exec probe, being
    /// free and a fact about this build rather than about the server.
    var sendsPartsConcurrently: Bool { get }

    /// Send several parts of one local file **at once**, each to its own remote name, for the
    /// server to join afterwards (``SSHAssembleCommand``).
    ///
    /// The upload twin of ``downloadSegments(_:of:to:progress:isCancelled:)``, and unlike that one
    /// it *is* SFTP: each part is an ordinary `put` of a slice this machine cut, so a part that
    /// cannot be written reports the server's own reason rather than arriving as a short file. What
    /// needs the exec channel is only the join, which is why the caller asks for one **before**
    /// sending anything — the parts cross the network first, so a refusal discovered afterwards
    /// would have cost the whole upload.
    ///
    /// `progress` reports a part's length **as that part lands**, which is the finest granularity
    /// this protocol allows: `sftp` prints no meter a spawned process can read, so a single-stream
    /// upload can only report once at the end, and a split one reports once per part. That is the
    /// second thing splitting buys, after the parallelism, and it is the one a user sees.
    ///
    /// It **throws on any failure of the run**, since a part that did not land makes the join
    /// meaningless and the caller is about to fall back to one stream, whose error is the one worth
    /// reporting.
    ///
    /// Additive, with a default that sends the parts **one at a time**: the file the server joins is
    /// identical either way, so a transport that has not implemented this is slow and never wrong.
    @discardableResult
    func uploadParts(
        _ parts: [UploadSegment],
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

    /// The same download, carrying the source's metadata as `plan` describes it.
    ///
    /// **One invocation, not two.** `sftp` reads one command per line, so `-p` rides the `get`
    /// itself and any follow-up `chmod` is another line in the same batch — where a second call
    /// would be a fresh TCP connect, key exchange and authentication, measured at **71 ms** against
    /// a loopback server and a real round trip over a network.
    ///
    /// The follow-up lines are sent **allowed to fail** (`sftp`'s `-` prefix), which is what keeps a
    /// refused `chmod` from failing a transfer whose bytes already landed: measured 2026-08-28, a
    /// plain batch aborts on the first failed command and exits 1, so without the prefix a
    /// successful copy is reported as a failure. With it the run exits 0 and the refusal still
    /// reaches stderr, which is what makes the loss reportable rather than merely swallowed.
    ///
    /// Additive, and its default **forwards while carrying nothing** — honest only because a
    /// transport that has not implemented it also reports no ``RemoteWriteTransport/metadataCapabilities``,
    /// so the plan it is handed is empty and the two paths produce the identical file.
    @discardableResult
    func download(
        _ remotePath: String,
        to localPath: String,
        options: RemoteTransferOptions,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> RemoteTransferOutcome

    /// The same upload, carrying the source's metadata as `plan` describes it — with exactly the
    /// batch shape and the allowed-to-fail rule ``download(_:to:resume:carrying:progress:isCancelled:)``
    /// documents, measured in this direction too.
    @discardableResult
    func upload(
        _ localPath: String,
        to remotePath: String,
        options: RemoteTransferOptions,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> RemoteTransferOutcome

    /// Duplicate one remote file to another path **on the same account, server-side** — the bytes
    /// never cross this machine (PLAN.md §M25 Slice 3).
    ///
    /// `sftp`'s `cp`, over OpenSSH's `copy-data` extension. It is the one verb here whose absence is
    /// ordinary rather than exceptional: the client refuses on its own after reading what the server
    /// advertised, so it must be **attempted** and the refusal read — nothing can ask in advance.
    /// That refusal arrives as ``SFTPTransportError/copyExtensionUnavailable`` and the backend
    /// latches it for the connection, then stages the copy through this disk as it always did.
    ///
    /// `plan.followUp` rides the **same batch**, allowed to fail, for both of the reasons the
    /// transfer verbs already document: a second invocation would be a fresh connect, key exchange
    /// and authentication, and a refused `chmod` must not fail a copy whose bytes have landed. It is
    /// wanted even for an ordinary mode here, unlike on a transfer — measured 2026-08-28, `cp` onto
    /// an **occupied** destination overwrites the bytes and leaves that file's *own* mode standing.
    ///
    /// Answers the metadata steps that did not take, exactly as the transfer verbs do; the copy
    /// itself either happened or threw. Note what it can never carry: `cp` stamps the copy with
    /// *now*, and this language has no verb that sets a time, so a plan built for this route counts
    /// the modification time as dropped and the caller reports it.
    ///
    /// The default **throws** rather than forwarding, which is the test this project applies before
    /// letting a default stand in: staging is not something a transport can do, and answering
    /// success would report a duplicate that does not exist. Throwing the same refusal a server
    /// without the extension gives sends the caller down the route it already has.
    func copyRemoteFile(
        _ source: String,
        to destination: String,
        carrying plan: RemoteMetadataPlan,
        isCancelled: () -> Bool
    ) throws -> [RemoteMetadataRefusal]
}

public extension SFTPTransport {
    func runCommand(_ command: String, isCancelled: () -> Bool) throws -> String? { nil }

    func copyRemoteFile(
        _: String,
        to _: String,
        carrying _: RemoteMetadataPlan,
        isCancelled _: () -> Bool
    ) throws -> [RemoteMetadataRefusal] {
        throw SFTPTransportError.copyExtensionUnavailable
    }

    @discardableResult
    func download(
        _ remotePath: String,
        to localPath: String,
        options: RemoteTransferOptions,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> RemoteTransferOutcome {
        RemoteTransferOutcome(bytes: try download(
            remotePath,
            to: localPath,
            resume: options.resume,
            progress: progress,
            isCancelled: isCancelled
        ))
    }

    @discardableResult
    func upload(
        _ localPath: String,
        to remotePath: String,
        options: RemoteTransferOptions,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> RemoteTransferOutcome {
        RemoteTransferOutcome(bytes: try upload(
            localPath,
            to: remotePath,
            resume: options.resume,
            progress: progress,
            isCancelled: isCancelled
        ))
    }

    /// A transport says nothing about concurrency until it implements the verb below.
    ///
    /// `false` is what keeps the route off a transport that cannot serve it — see
    /// ``sendsPartsConcurrently``.
    var sendsPartsConcurrently: Bool { false }

    /// The additive half of ``uploadParts(_:progress:isCancelled:)``: a transport that predates
    /// segmented uploads keeps compiling and keeps working.
    ///
    /// It forwards rather than throwing, by the test this project applies before letting a default
    /// stand in — the caller cannot tell it was not honoured, because the parts land under the same
    /// names holding the same bytes and the server joins the identical file. It is nonetheless
    /// **unreachable in the shipped app**, and deliberately so: `sendsPartsConcurrently` is `false`
    /// alongside it, so the backend never offers the route to a transport running on this. What it
    /// loses is the concurrency, which is not merely the point of the route — without it the route
    /// is *worse* than the single `put` it replaces, since the costs are all still paid.
    @discardableResult
    func uploadParts(
        _ parts: [UploadSegment],
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        var moved: Int64 = 0
        for part in parts.sorted(by: { $0.number < $1.number }) {
            moved += try upload(
                part.localPath,
                to: part.remotePath,
                resume: false,
                progress: { _ in },
                isCancelled: isCancelled
            )
            progress(part.length)
        }
        return moved
    }

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
