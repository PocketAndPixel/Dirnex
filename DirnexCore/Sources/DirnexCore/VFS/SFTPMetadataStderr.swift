import Foundation

/// The metadata-step failures pulled out of one `sftp` run's stderr, and the stderr left over for
/// the transfer's own classification.
///
/// **A metadata step's refusal must never be read as the transfer's failure**, and both of `sftp`'s
/// error vocabularies make that easy to get wrong. `SFTPTransportError.detect(stderr:)` scans the
/// whole stream for `permission denied` and `no such file` before anything else, so — measured
/// 2026-08-28 against a real `sshd` — a `chmod` refused after a `put` whose bytes had already landed
/// turns a perfectly good transfer into `.permissionDenied` or `.notFound`. The bytes are there, the
/// file is right, and the copy is reported as failed.
///
/// Both directions have a family, which is why this is a split rather than one prefix. The strings
/// are OpenSSH's own, read out of `/usr/bin/sftp`:
/// - **remote**, from `put -p`, `chmod`, `chown` and `chgrp`: `remote setstat "…": …`
/// - **local**, from `get -p`: `local chmod "…": …`, `local set times "…": …`,
///   `local set times on "…": …`, `local chmod directory "…": …`
///
/// A step that *succeeds* prints nothing at all — measured, stderr exactly 0 bytes for a successful
/// `put` plus `-chmod` — so on the ordinary transfer this separates an empty string from an empty
/// string and the remainder is byte-identical to what the classifier always saw.
public struct SFTPMetadataStderr: Sendable, Equatable {
    /// The refusal lines, verbatim and in the order `sftp` printed them. The server's own words, so
    /// the app can say *why* rather than authoring a sentence it cannot translate.
    public let lines: [String]
    /// Everything else, rejoined — what the transfer's classification should be shown.
    public let remainder: String

    /// Nothing was refused: the metadata this run was asked to carry arrived.
    public var isEmpty: Bool { lines.isEmpty }

    public init(lines: [String], remainder: String) {
        self.lines = lines
        self.remainder = remainder
    }

    /// The prefixes that mark a line as a metadata step's, lowercased for comparison.
    ///
    /// Anchored at the **start** of the line rather than matched anywhere in the stream, which is
    /// the whole difference between this and the bug it prevents: `detect` looks for a substring and
    /// therefore cannot tell whose failure it found.
    private static let prefixes = [
        "remote setstat \"",
        "local chmod \"",
        "local chmod directory \"",
        "local set times \"",
        "local set times on \""
    ]

    /// Separate one run's stderr into the metadata steps' refusals and everything else.
    ///
    /// Deliberately keeps every other line — a host-key warning, a server banner, `Connected to …`,
    /// and above all the transfer's own error — so the remainder classifies exactly as an
    /// un-split stream would have.
    public static func separate(stderr: String) -> SFTPMetadataStderr {
        var refusals: [String] = []
        var rest: [String] = []
        for raw in stderr.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lowered = line.lowercased()
            if prefixes.contains(where: { lowered.hasPrefix($0) }) {
                refusals.append(line)
            } else {
                rest.append(String(raw))
            }
        }
        return SFTPMetadataStderr(lines: refusals, remainder: rest.joined(separator: "\n"))
    }
}
