import Foundation

/// One `curl` invocation and the config it reads on stdin — the pair a segmented download needs,
/// since a parallel run puts every per-transfer option in the **config** and only the run's own
/// flags in `argv`.
///
/// The FTP twin of ``S3ParallelInvocation``, and a separate type rather than a shared one because
/// the two carry different things: an S3 section signs itself and reports a status, an FTP section
/// logs in and reports nothing (see ``FTPProcessArguments/downloadSegments(session:remotePath:segments:credentials:)``).
public struct FTPParallelInvocation: Sendable, Equatable {
    /// The `curl` arguments. Carries no credential, and nothing that varies per segment.
    public let arguments: [String]
    /// The multi-section config, written to the child's stdin. This is where the password rides, as
    /// it does for every other invocation — never `argv`, where any `ps` would read it.
    public let configuration: String
}

public extension FTPProcessArguments {
    /// Download several ranges of one remote file **at once**, in a single `curl`
    /// (docs/HISTORY.md ▸ After M19).
    ///
    /// One process rather than several is what keeps this a change of shape and not of
    /// architecture: `FTPCurlTransport` already spawns one child, drains both pipes, bounds the wait
    /// and terminates on cancel, so a Stop still stops every segment and nothing here needs a
    /// thread. It is the shape the S3 half took first, and everything about *how the answers are
    /// read* had to change, because FTP tells you far less per section.
    ///
    /// Probed 2026-08-24 against a real server, and four of the five findings are about what is
    /// **absent** here:
    ///
    /// - **It works, exactly.** Eight sections of a 40 MiB file came back as eight exact pieces that
    ///   reassembled SHA-256 identical to the whole. On the wire each section is its own control
    ///   connection, its own login, and a `REST <first>` + `RETR` — eight of each, opened within
    ///   about a millisecond. That is what makes a segment a *login* rather than a request, and it
    ///   is why ``SegmentedDownloadLimits/ftp`` allows four of them and not eight.
    /// - **No `--fail`.** Over HTTP that flag stops a refusal's `<Error>` document being saved under
    ///   the file's name; FTP has no error document, and a refused `RETR` writes nothing at all
    ///   (measured — the failing sections' files were simply absent). Carrying it would be cargo.
    /// - **No write-out.** There is nothing per-section worth reading: the reply code is a *race* —
    ///   one run reported `225` and `226` mixed across successful sections, because a range download
    ///   closes the data connection early and whichever reply `curl` saw last is what it reports —
    ///   and a failed section reports `221`, the goodbye. The exit code is the run's, not the
    ///   section's. So the only per-section fact is **the file that landed**, which the assembly
    ///   checks against its range anyway.
    /// - **No `--continue-at`.** A segment is a range request into a file this code created for it,
    ///   so there is never a partial to resume from; resume belongs to the single-stream path, which
    ///   is what a download with bytes already on disk still takes.
    /// - **`--parallel-immediate` is not optional**, the same as on the S3 side: without it `curl`
    ///   runs the first transfer alone before starting the rest, so a run costs two rounds instead
    ///   of one and nothing says so.
    ///
    /// `credentials` is the already-built config line (``FTPConfigFile/credentials(for:password:)``),
    /// passed in rather than assembled here so this stays a builder that never sees a password —
    /// the same division the transport has always had, one layer along.
    static func downloadSegments(
        session: FTPSession,
        remotePath: String,
        segments: [DownloadSegment],
        credentials: String
    ) -> FTPParallelInvocation {
        let address = url(session, remotePath)
        let security = securityConfiguration(session: session)
        let sections = segments.map { segment in
            [
                credentials.hasSuffix("\n") ? credentials : credentials + "\n",
                "connect-timeout = \(session.connectTimeout)\n",
                "max-time = \(session.maxTime)\n",
                addressFamilyConfiguration(session: session),
                security,
                "range = \(FTPConfigFile.quote(segment.headerValue))\n",
                "output = \(FTPConfigFile.quote(segment.localPath))\n",
                "url = \(FTPConfigFile.quote(address))\n"
            ].joined()
        }
        return FTPParallelInvocation(
            arguments: [
                "-Z",
                "--parallel-immediate",
                "--parallel-max", String(max(1, segments.count)),
                "-sS",
                "-K", "-"
            ],
            configuration: sections.joined(separator: "next\n")
        )
    }

    /// The address-family half of a section, in config spelling.
    ///
    /// Per **section** rather than in `argv` for the same reason the TLS half is: `curl` reads one
    /// option set per transfer, so a batch that put this in `argv` would be relying on an option
    /// leaking across `next` boundaries. Empty unless an IPv4 address was actually observed for the
    /// dialed name (``HostNameFallback``), so nothing outside the mDNS family emits a byte of it.
    static func addressFamilyConfiguration(session: FTPSession) -> String {
        session.dial.restrictsToIPv4 ? "ipv4\n" : ""
    }

    /// The TLS half of a section, in config spelling.
    ///
    /// It has to be **per section** for the reason every other option does — `curl` reads one option
    /// set per transfer — and it is the half that must not be dropped: `--ssl-reqd` is what stops a
    /// server declining the upgrade and continuing in cleartext, and a pin is what a self-signed
    /// certificate was trusted by. A segmented download that quietly lost either would be a
    /// downgrade nobody asked for, on the one path where the user is not watching.
    static func securityConfiguration(session: FTPSession) -> String {
        var lines: [String] = []
        if session.location.security == .explicit { lines.append("ssl-reqd\n") }
        if session.location.security.usesTLS {
            if case let .pinned(publicKey) = session.trust {
                // The invariant these two share is `FTPTrust`'s: they always travel together.
                lines.append("insecure\n")
                lines.append("pinnedpubkey = \(FTPConfigFile.quote("sha256//\(publicKey)"))\n")
            }
            if session.tls == .forceTLS12 {
                lines.append("tlsv1.2\n")
                lines.append("tls-max = 1.2\n")
            }
        }
        return lines.joined()
    }
}
