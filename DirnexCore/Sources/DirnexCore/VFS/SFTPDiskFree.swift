import Foundation

/// What `sftp`'s `df` says about the space an SFTP server has left, read for the tooltip on a saved
/// SFTP row (PLAN.md §M38, the SFTP follow-up to Slice 7). `df` is OpenSSH's `statvfs@openssh.com`
/// extension: the server runs `statvfs(2)` on the path and sends the fields back raw.
///
/// Measured 2026-11-11 against the throwaway macOS `sshd` (OpenSSH 10.3, APFS) and an Alpine
/// container (OpenSSH 10.3p1, an ext4-backed overlay and a 64 MiB `tmpfs`), docs/NOTES.md ▸ sftp /
/// ssh ▸ Space left:
///
/// - **This Mac's `sftp` draws the table, so its shape never depends on the server.** A header and
///   one line of four integers in **KiB** and a percentage. `Size` is the filesystem's own total and
///   `Avail` is `f_bavail`, what an ordinary account may still write: on ext4 it was 5 % below
///   `(root)`, the reserve only root may use, and it matched GNU `df`'s Available to the KiB. The
///   64 MiB `tmpfs` read exactly 65536.
/// - **It is the filesystem's space, not the account's.** A per-user quota is not in `statvfs` on
///   Linux, so an account under one is shown the volume's space. That is why the total is shown with
///   it: "of 7.3 TB" reads as a disk, which is what it is.
/// - `%Capacity` counts the reserve as used (72 % where `df` said 77 %), and a pseudo-filesystem
///   answers zeros and `ERR`, so the column is never read.
public enum SFTPDiskFree {
    /// What `sftp` prints, on standard error, when the server does not offer the extension: the
    /// whole sentence, as a server started with `sftp-server -P statvfs` produced it.
    static let unsupportedSentence = "Server does not support statvfs@openssh.com extension"

    /// The header plain `df` prints over its numbers. `df -i`'s starts `Inodes` and is never asked.
    static let header = ["Size", "Used", "Avail", "(root)", "%Capacity"]

    /// The space reported in the transcript of ``SFTPBatchCommand/diskFree``, with standard error
    /// folded into standard output as `sftp` printed them.
    ///
    /// - **The table** is an answer: `Avail` of `Size`, in bytes. It is `nil` when `Size` is zero,
    ///   since that is a pseudo-filesystem with nothing to say rather than a full disk (`df /proc`).
    /// - **The extension's absence** throws ``ServerSpaceUnsupported``: a fact about the server, so
    ///   the caller stops asking it.
    /// - **Neither** throws the transcript as a transport failure, since no answer came: a connection
    ///   refused, a login refused, a run the deadline cut off. A `df` whose path is gone prints
    ///   nothing at all on either stream (measured), so the table missing is the only sign of it.
    public static func space(in transcript: String) throws -> ServerSpace? {
        let lines = transcript.split(whereSeparator: \.isNewline)
        let rows = lines.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        if let index = rows.firstIndex(of: header), index + 1 < rows.count,
           let numbers = kibibytes(rows[index + 1]) {
            guard numbers.size > 0 else { return nil }
            return ServerSpace(availableBytes: numbers.available, totalBytes: numbers.size)
        }
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == unsupportedSentence }) {
            throw ServerSpaceUnsupported()
        }
        throw SFTPTransportError.classify(stderr: transcript)
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

public extension SFTPBackend {
    /// The space left on the filesystem holding this account's login directory, which is where a
    /// saved SFTP row opens. One `sftp` session; ``SFTPDiskFree/space(in:)`` says what each answer
    /// means and what it throws.
    func space() throws -> ServerSpace? {
        try SFTPDiskFree.space(in: transport.diskFree())
    }
}
