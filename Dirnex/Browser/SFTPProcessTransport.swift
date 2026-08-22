import DirnexCore
import Foundation

/// Drives the system `sftp` tool to satisfy an `SFTPBackend`'s operations — the non-hermetic half of
/// SFTP browse and transfer (PLAN.md §M5), mirroring `ArchiveMounter`/`SpotlightSearchRunner`. All
/// the parsing, escaping, argument assembly, and error classification live in `DirnexCore`
/// (`SFTPListingParser`, `SFTPBatchCommand`, `SFTPProcessArguments`, `SFTPTransportError.classify`);
/// this spawns `sftp -b -` and pipes one command in.
///
/// Key auth uses `-b -` (quiet, fail-fast, parseable) — `sftp`'s native non-interactive path.
/// Password auth can't use `-b` (it disables the prompt), so it runs `sftp` interactively and answers
/// the prompt through an `SSH_ASKPASS` helper (`SFTPProcessArguments` in core assembles the flags):
/// the password rides only in the child's environment (`SFTPAskpassHelper`), never on the command
/// line or on disk. Interactive mode means stdout carries `sftp>` echo lines (the parser skips them)
/// and a failed command exits zero (so this scans stderr with `detect`), and a wall-clock timeout
/// bounds a server that never closes the channel.
struct SFTPProcessTransport: SFTPTransport {
    let location: SFTPLocation
    /// How to authenticate — a key file, or a password fed via `SSH_ASKPASS`.
    let authentication: SFTPAuthentication
    /// The plaintext password for `.password` auth, resolved from the Keychain by the caller; `nil`
    /// for key auth. Held for the connection's lifetime so each spawned `sftp` can re-authenticate.
    var password: String?
    /// Seconds to wait for the connection before giving up — a dead host must not hang the pane.
    var connectTimeout: Int = 15
    /// Overall wall-clock bound (seconds) on a single *password* command, so an unresponsive or
    /// non-standard server can't hang the pane on a read that never ends (some servers hold the
    /// channel open after the reply). Generous enough for browse/metadata and small transfers; large
    /// password-auth transfers are a follow-up (alongside resume). Key auth keeps its unbounded,
    /// verified path.
    var passwordTimeout: Int = 30

    init(
        location: SFTPLocation,
        authentication: SFTPAuthentication,
        password: String? = nil,
        connectTimeout: Int = 15
    ) {
        self.location = location
        self.authentication = authentication
        self.password = password
        self.connectTimeout = connectTimeout
    }

    func listDirectory(_ remotePath: String) throws -> String {
        try run(batch: SFTPBatchCommand.list(remotePath))
    }

    // MARK: - Writes

    func makeDirectory(_ remotePath: String) throws {
        _ = try run(batch: SFTPBatchCommand.makeDirectory(remotePath))
    }

    /// Create an empty file by `put`-ing a zero-byte local one — `sftp` has no `touch`, and no
    /// create-exclusive of any kind (``RemoteWriteTransport/createEmptyFile(_:)`` carries the three
    /// candidates that were measured and rejected). `resume: false`, because `put -a` cannot create
    /// a file that is not already there.
    func createEmptyFile(_ remotePath: String) throws {
        let scratch = try EmptyUploadFile()
        defer { scratch.remove() }
        _ = try run(batch: SFTPBatchCommand.upload(scratch.path, to: remotePath, resume: false))
    }

    func rename(_ source: String, to destination: String) throws {
        _ = try run(batch: SFTPBatchCommand.rename(source, to: destination))
    }

    func removeFile(_ remotePath: String) throws {
        _ = try run(batch: SFTPBatchCommand.removeFile(remotePath))
    }

    func removeDirectory(_ remotePath: String) throws {
        _ = try run(batch: SFTPBatchCommand.removeDirectory(remotePath))
    }

    func createSymbolicLink(_ remotePath: String, target: String) throws {
        _ = try run(batch: SFTPBatchCommand.createSymbolicLink(remotePath, target: target))
    }

    /// Progress is the destination file's own growth, which is exact and costs nothing — and is the
    /// only thing available, since `sftp` prints no meter a spawned process can read
    /// (`SFTPTransport.upload`).
    @discardableResult
    func download(
        _ remotePath: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        _ = try run(
            batch: SFTPBatchCommand.download(remotePath, to: localPath, resume: resume),
            watching: .destinationFile(path: localPath),
            progress: progress,
            isCancelled: isCancelled
        )
        // `sftp get`/`get -a` leaves the whole file on disk, so its final size is the total
        // transferred; the backend derives the resumed remainder from the pre-existing length.
        return localFileSize(localPath)
    }

    /// **`progress` is never called here**, and that is `sftp`'s doing rather than an omission: an
    /// upload changes nothing on this machine to watch, and OpenSSH draws its progress meter only
    /// for a foreground process group on a controlling terminal — probed six ways over a 1 GiB
    /// transfer, including with the `progress` batch command explicitly enabling it, and it printed
    /// nothing every time. The backend reports the whole count when this returns. The alternative,
    /// polling the *remote* size, is a fresh connection and handshake per tick on a transport with
    /// no session (`SFTPTransport.upload` carries the measurement).
    @discardableResult
    func upload(
        _ localPath: String,
        to remotePath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        _ = try run(
            batch: SFTPBatchCommand.upload(localPath, to: remotePath, resume: resume),
            isCancelled: isCancelled
        )
        // The local source's size is the remote file's total size after `put`/`put -a` — cheaper
        // and safer than re-statting the remote (which would cost another round trip).
        return localFileSize(localPath)
    }

    /// Run one command on the server's own shell over an SSH **exec** channel — the search
    /// shortcut's route (PLAN.md §M22 Slice 4), and the one verb here that does not speak SFTP.
    ///
    /// `nil` means *the command could not be asked at all* — `ssh` would not launch, or the server
    /// held the channel past the timeout. It does **not** mean "this account has no exec channel",
    /// and that distinction is the probe's finding rather than a preference: an account confined to
    /// the `sftp` subsystem answers an exec request with an ordinary-looking reply — the sentence
    /// "This service allows sftp connections only." on *stdout*, exit 1, empty stderr — so from here
    /// it is indistinguishable from a shell that ran something. Only the core's
    /// `SSHFindListingParser` can tell, because only it knows what a good answer looks like, and it
    /// falls back to the walk when it does not see one.
    ///
    /// That is also why there is no memo of accounts that refused. It would have to be fed by the
    /// core rather than learned here, and it would save exactly **one** handshake in front of a walk
    /// that is about to spend one per directory — a saving too small to be worth a second place for
    /// this decision to live.
    ///
    /// Cancellation travels rather than degrading to `nil`: it is the caller's own instruction, not
    /// a property of the server.
    func runCommand(_ command: String, isCancelled: () -> Bool) throws -> String? {
        do {
            return try run(exec: command, isCancelled: isCancelled)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func localFileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return 0 }
        return size
    }

    /// The remote working (home) directory reported by `pwd`, to land in on connect. Doubles as a
    /// connection test: it fails fast (classified) when auth, the host, or the key is wrong.
    /// `tolerateChannelHold` lets it accept the reply from a server that holds the channel open
    /// afterwards (some appliances do) rather than timing out — safe here because `pwd`'s reply is a
    /// single line that has fully arrived by then.
    func resolveHomeDirectory() throws -> String {
        let output = try run(
            batch: SFTPBatchCommand.printWorkingDirectory,
            tolerateChannelHold: true
        )
        let marker = "Remote working directory: "
        for line in output.split(whereSeparator: \.isNewline) {
            if let range = line.range(of: marker) {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return "/"
    }
}
