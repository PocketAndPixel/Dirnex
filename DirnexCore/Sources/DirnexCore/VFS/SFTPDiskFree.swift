import Foundation

/// What `sftp`'s `df` says about the space an SFTP server has left, read for the tooltip on a saved
/// SFTP row (PLAN.md §M38, the SFTP follow-up to Slice 7). `df` is OpenSSH's `statvfs@openssh.com`
/// extension: the server runs `statvfs(2)` on the path and sends the fields back raw.
///
/// Measured 2026-11-11 against the throwaway macOS `sshd` (OpenSSH 10.3, APFS), an Alpine container
/// (OpenSSH 10.3p1, an ext4-backed overlay and `tmpfs` volumes) and the NAS (DSM), docs/NOTES.md ▸
/// sftp / ssh ▸ Space left:
///
/// - **This Mac's `sftp` draws the table, so its shape never depends on the server.** A header and
///   one line of four integers in **KiB** and a percentage. `Size` is the filesystem's own total and
///   `Avail` is `f_bavail`, what an ordinary account may still write: on ext4 it was 5 % below
///   `(root)`, the reserve only root may use, and it matched GNU `df`'s Available to the KiB.
/// - **It is the filesystem's space, not the account's.** A per-user quota is not in `statvfs`: a
///   1 GB DSM quota left the NAS answering its whole 15 TB volume. That is why the total is shown
///   with it: "of 15 TB" reads as a disk, which is what it is.
/// - **The login directory is not always where files go.** DSM's SFTP root `/` is a chroot that
///   holds only the shares, on an 8 GB filesystem of its own, while every share is on the data
///   volume. So when the login directory holds nothing but folders, they are asked too
///   (``choose(login:folders:)``), in a second session.
/// - `%Capacity` counts the reserve as used (72 % where `df` said 77 %), and a pseudo-filesystem
///   answers zeros and `ERR`, so the column is never read.
public enum SFTPDiskFree {
    /// What `sftp` prints, on standard error, when the server does not offer the extension: the
    /// whole sentence, as a server started with `sftp-server -P statvfs` produced it.
    static let unsupportedSentence = "Server does not support statvfs@openssh.com extension"

    /// The header plain `df` prints over its numbers. `df -i`'s starts `Inodes` and is never asked.
    static let header = ["Size", "Used", "Avail", "(root)", "%Capacity"]

    /// The most folders the second session asks. DSM shows an account the shares it may use, a
    /// handful; a login directory with more than this many folders and nothing else is asked about
    /// the first ones by name.
    static let folderLimit = 8

    // MARK: - The two sessions

    /// The first session, asked every time: the login directory's own space, its entries, and `pwd`,
    /// which frames the end of the listing (``SFTPBatchListing``'s rule: a block is trusted only once
    /// `sftp` has moved on to the next line).
    public static let loginBatch = SFTPBatchCommand.batch(
        [SFTPBatchCommand.diskFree, listLine, endMarker]
    )

    /// The second session, asked only when the login directory holds nothing but folders: each
    /// folder's space, by its name relative to the login directory, where a session starts.
    public static func folderBatch(_ folders: [String]) -> String {
        SFTPBatchCommand.batch(folders.map(SFTPBatchCommand.diskFree(of:)))
    }

    static let listLine = SFTPBatchCommand.allowedToFail("ls -la")
    static let endMarker = SFTPBatchCommand.printWorkingDirectory

    /// What the first session said.
    public struct LoginAnswer: Sendable, Equatable {
        /// The login directory's filesystem, or `nil` for one of size zero.
        public let space: ServerSpace?
        /// The folders to ask next: the login directory's own, sorted, at most ``folderLimit``, when
        /// it holds nothing but folders. Empty otherwise, and then ``space`` is the answer.
        public let folders: [String]
    }

    /// Read the first session's transcript, standard error folded into standard output.
    ///
    /// - **The table** under `df`'s echo is the login directory's space, `nil` when its `Size` is
    ///   zero, a pseudo-filesystem with nothing to say rather than a full disk (`df /proc`).
    /// - **The extension's absence** throws ``ServerSpaceUnsupported``: a fact about the server, so
    ///   the caller stops asking it.
    /// - **Neither** throws the transcript as a transport failure, since no answer came: a connection
    ///   refused, a login refused, a run the deadline cut off. A `df` whose path is gone prints
    ///   nothing at all on either stream (measured), so the table missing is the only sign of it.
    ///
    /// Each is read only between `df`'s echo and the listing's, so a name in the listing, which
    /// `sftp` prints raw, newline included, cannot forge a table or the sentence.
    public static func login(in transcript: String) throws -> LoginAnswer {
        let lines = lines(of: transcript)
        guard let dfEcho = lines.firstIndex(of: echo(SFTPBatchCommand.diskFree)) else {
            throw SFTPTransportError.classify(stderr: transcript)
        }
        let listEcho = lines[(dfEcho + 1)...].firstIndex(of: echo(listLine))
        let dfBlock = lines[(dfEcho + 1)..<(listEcho ?? lines.count)]
        guard let table = table(in: dfBlock) else {
            if dfBlock.contains(
                where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == unsupportedSentence }
            ) {
                throw ServerSpaceUnsupported()
            }
            throw SFTPTransportError.classify(stderr: transcript)
        }
        return LoginAnswer(space: table.space, folders: folders(listed: lines, after: listEcho))
    }

    /// One answer per asked folder, from the second session's transcript: its filesystem, or `nil`
    /// for one of size zero, one whose `df` printed nothing (gone, or refused) and one the session
    /// never reached.
    ///
    /// Throws the transcript as a transport failure when no folder was reached at all, a session
    /// that never connected: answering for the login directory then would replace a good answer
    /// with what may be a chroot's own small filesystem.
    public static func folders(in transcript: String, asked folders: [String]) throws -> [
        ServerSpace?
    ] {
        let lines = lines(of: transcript)
        var echoes: [Int?] = []
        var cursor = 0
        for folder in folders {
            let found = lines[cursor...].firstIndex(of: echo(SFTPBatchCommand.diskFree(of: folder)))
            echoes.append(found)
            if let found { cursor = found + 1 }
        }
        guard folders.isEmpty || echoes.contains(where: { $0 != nil }) else {
            throw SFTPTransportError.classify(stderr: transcript)
        }
        return echoes.indices.map { index in
            guard let start = echoes[index] else { return nil }
            let next = echoes[(index + 1)...].lazy.compactMap { $0 }.first ?? lines.count
            return table(in: lines[(start + 1)..<next])?.space
        }
    }

    /// The space to show, from the login directory's filesystem and its folders'.
    ///
    /// - A folder on the login directory's own filesystem makes it an ordinary directory, and its
    ///   filesystem is the answer. So is it when no folder answered.
    /// - Otherwise the login directory holds only mount points, as DSM's SFTP root does, and the
    ///   answer is the filesystem its folders share, or **none** when they are spread over several:
    ///   no one number is the server's then.
    ///
    /// Filesystems are told apart by their numbers, since `sftp` does not print the `f_fsid` the
    /// extension sends (``ServerSpace/isSameFilesystem(as:)``).
    public static func choose(login: ServerSpace?, folders: [ServerSpace?]) -> ServerSpace? {
        let answered = folders.compactMap { $0 }
        guard let first = answered.first else { return login }
        if let login, answered.contains(where: { $0.isSameFilesystem(as: login) }) { return login }
        return answered.allSatisfy { $0.isSameFilesystem(as: first) } ? first : nil
    }

    // MARK: - Reading a transcript

    /// The transcript's lines, split on the scalar `\n`: Swift reads `\r\n` as one `Character`, and
    /// the refusal sentence ends in one (``SFTPBatchListing`` gives the same reason).
    private static func lines(of transcript: String) -> [String] {
        transcript.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
    }

    /// The line `sftp` prints for each line of the batch it runs.
    private static func echo(_ command: String) -> String { "sftp> " + command }

    /// The login directory's folders to ask, from the listing between its echo and the last `pwd`
    /// echo: empty when the listing did not finish, or holds anything that is not a folder.
    private static func folders(listed lines: [String], after listEcho: Int?) -> [String] {
        guard let listEcho,
              let end = lines.lastIndex(of: echo(endMarker)), end > listEcho
        else { return [] }
        let entries = SFTPListingParser.parse(lines[(listEcho + 1)..<end].joined(separator: "\n"))
            .filter { $0.name != "." && $0.name != ".." }
        guard !entries.isEmpty, entries.allSatisfy({ $0.kind == .directory }) else { return [] }
        return Array(entries.map(\.name).sorted().prefix(folderLimit))
    }

    /// The table in `block`: the first header and the numbers line under it.
    private static func table(in block: ArraySlice<String>) -> Table? {
        let rows = block.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        guard let index = rows.firstIndex(of: header), index + 1 < rows.endIndex,
              let numbers = kibibytes(rows[index + 1])
        else { return nil }
        guard numbers.size > 0 else { return Table(space: nil) }
        return Table(space: ServerSpace(availableBytes: numbers.available, totalBytes: numbers.size))
    }

    /// A table that was printed, with its space, `nil` for a filesystem of size zero.
    private struct Table {
        let space: ServerSpace?
    }

    /// `Size` and `Avail` from the line under the header, in bytes, or `nil` when it is not four
    /// whole numbers and a percentage. The columns are separated by at least one space at any width
    /// (`%12llu %12llu …`), so a filesystem too big for its column still splits.
    private static func kibibytes(_ row: [String]) -> (size: Int64, available: Int64)? {
        guard row.count == header.count else { return nil }
        let counts = row.prefix(4).compactMap { UInt64($0).flatMap { Int64(exactly: $0) } }
        guard counts.count == 4 else { return nil }
        let size = counts[0].multipliedReportingOverflow(by: 1024)
        let available = counts[2].multipliedReportingOverflow(by: 1024)
        guard !size.overflow, !available.overflow else { return nil }
        return (size.partialValue, available.partialValue)
    }
}

extension ServerSpace {
    /// Whether two answers are one filesystem: the same total, and space left within 1 % of it,
    /// which the same filesystem asked a moment apart always is. Two filesystems of exactly one size
    /// with almost the same space left read as one, which costs nothing here: either is a real
    /// filesystem's answer.
    func isSameFilesystem(as other: ServerSpace) -> Bool {
        guard let total = totalBytes, total == other.totalBytes else { return false }
        return abs(availableBytes - other.availableBytes) <= total / 100
    }
}

public extension SFTPBackend {
    /// The space left where this account's files go: the filesystem of its login directory, which
    /// is where a saved SFTP row opens, or of the folders in it when it holds nothing else
    /// (``SFTPDiskFree/choose(login:folders:)``). One `sftp` session, or two when the folders are
    /// asked; ``SFTPDiskFree/login(in:)`` says what each answer means and what it throws.
    func space() throws -> ServerSpace? {
        let login = try SFTPDiskFree.login(in: transport.diskFree(SFTPDiskFree.loginBatch))
        guard !login.folders.isEmpty else { return login.space }
        let transcript = try transport.diskFree(SFTPDiskFree.folderBatch(login.folders))
        return SFTPDiskFree.choose(
            login: login.space,
            folders: try SFTPDiskFree.folders(in: transcript, asked: login.folders)
        )
    }
}
