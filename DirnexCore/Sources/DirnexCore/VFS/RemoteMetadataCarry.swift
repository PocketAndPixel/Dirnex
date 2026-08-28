import Foundation

/// One thing a remote transfer can do to carry metadata the bytes themselves do not.
///
/// The cases are primitives of the *protocols*, not of any one backend: `sftp` spells the first two
/// as `get -p`/`put -p` and `chmod`, FTP spells the last two as `SITE CHMOD` and `MFMT`, and neither
/// offers all three. Which of them a given account actually honours is a question only that account
/// can answer, which is why ``RemoteMetadataCapabilities`` is a value handed in rather than a
/// property of a backend type (PLAN.md §6: degrade *per connection at run time*).
public enum RemoteMetadataStep: Sendable, Hashable {
    /// Ask the transfer verb itself to preserve what it can — `sftp`'s `-p` on `get`/`put`.
    ///
    /// Measured 2026-08-28 against a real `sshd` rather than read off the man page, which says only
    /// "full file permissions and access times": it carries the **modification** time as well as the
    /// access time, both exactly, and the low nine permission bits exactly — and it silently drops
    /// set-uid, set-gid and the sticky bit, which the server does put on the wire.
    case preserveDuringTransfer
    /// Apply a mode explicitly, after the bytes have landed.
    ///
    /// This is the only route to the three special bits: `chmod 4755` over the wire really does
    /// produce `-rwsr-xr-x`, so an explicit `chmod` is *strictly more capable* than `-p` and not
    /// merely its fallback.
    case setMode(POSIXPermissions)
    /// Apply a modification time explicitly — FTP's `MFMT`, which has no `-p` to ride on.
    ///
    /// Exact to the second and anchored to UTC (RFC 3659), verified by round-tripping one against
    /// the local truth on a host whose own offset is not zero. The coarse, year-less, zone-less
    /// stamp FTP is known for belongs to `LIST`, not to the protocol.
    case setModificationTime(Date)
}

/// A fact about the source that a transfer could not carry.
///
/// Reported so a caller can *say so* rather than approximate. The failure this whole milestone is
/// designed against is the quiet one — reporting a preserved mode that was silently dropped — and a
/// caller cannot avoid it without being told which half went missing.
public enum RemoteMetadataAspect: Sendable, Hashable, CaseIterable {
    /// The nine `rwx` bits.
    case mode
    /// Set-uid, set-gid and the sticky bit, which `-p` drops on its own.
    case specialModeBits
    /// The modification time.
    case modificationTime
    /// The access time. Never carried by anything but `-p`, and worth its own case because it is the
    /// one aspect a *correct* FTP transfer always loses.
    case accessTime
}

/// What one account can be asked to do. Established per connection by attempting a verb and reading
/// the refusal, never by asking a server in advance — none of these can be queried.
public struct RemoteMetadataCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The transfer verb takes a preserve flag (`sftp`'s `-p`). FTP has no equivalent.
    public static let preserveFlag = RemoteMetadataCapabilities(rawValue: 1 << 0)
    /// The account honours an explicit mode change (`sftp`'s `chmod`, FTP's `SITE CHMOD`).
    public static let changeMode = RemoteMetadataCapabilities(rawValue: 1 << 1)
    /// The account honours an explicit modification time (FTP's `MFMT`).
    public static let setModificationTime = RemoteMetadataCapabilities(rawValue: 1 << 2)

    /// What an OpenSSH account offers before anything has been refused.
    public static let sftp: RemoteMetadataCapabilities = [.preserveFlag, .changeMode]
    /// What an FTP account offers before anything has been refused. No preserve flag exists, and
    /// both of the others are extensions a server need not implement.
    public static let ftp: RemoteMetadataCapabilities = [.changeMode, .setModificationTime]

    /// What a **local** destination can be asked to do — which is everything, with plain syscalls.
    ///
    /// The capabilities describe the *destination*, not the wire, and a transfer has two directions
    /// with two different destinations. An upload lands on the server, so it is bounded by what that
    /// account will honour and by whatever it has since refused; a **download lands on this
    /// machine**, where `chmod(2)` and `utimes(2)` always work and cost nothing. Reading the wire's
    /// limits into the download direction is the mistake this constant exists to prevent — it would
    /// have an FTP download drop a modification time that the local disk was perfectly able to take,
    /// and report the loss as though the protocol were at fault.
    ///
    /// The preserve flag is not here because it belongs to the transfer *verb* rather than to the
    /// destination: a caller unions it in when its own tool offers one (`sftp`'s `get -p` does, and
    /// `curl` has no equivalent).
    public static let localDestination: RemoteMetadataCapabilities = [
        .changeMode,
        .setModificationTime
    ]
}

/// What a transfer must do to carry its source's metadata, and what it will lose.
///
/// Pure, so the rule that decides it is testable without a server — which matters more here than
/// usual, because the two failure directions are invisible from outside: carrying nothing looks
/// exactly like carrying everything until somebody inspects the destination, and *claiming* to have
/// carried something is worse than not carrying it.
public struct RemoteMetadataPlan: Sendable, Hashable {
    /// The steps to take, in order: the transfer flag (if any) belongs to the transfer itself, and
    /// everything else runs after the bytes land.
    public let steps: [RemoteMetadataStep]
    /// What the source had and this connection could not carry. Empty is the good case.
    public let dropped: Set<RemoteMetadataAspect>

    public init(steps: [RemoteMetadataStep], dropped: Set<RemoteMetadataAspect>) {
        self.steps = steps
        self.dropped = dropped
    }

    /// A plan that carries nothing and loses nothing — the transfer of a source whose listing
    /// reported neither a mode nor a date, which is every S3 row and every DOS-dialect FTP one.
    public static let carryingNothing = RemoteMetadataPlan(steps: [], dropped: [])

    /// Whether the transfer verb should carry `sftp`'s `-p`.
    public var usesPreserveFlag: Bool { steps.contains(.preserveDuringTransfer) }

    /// The steps to run *after* the bytes land — everything but the transfer's own flag.
    public var followUp: [RemoteMetadataStep] {
        steps.filter { $0 != .preserveDuringTransfer }
    }

    /// Whether this transfer carries the source's metadata whole.
    public var isComplete: Bool { dropped.isEmpty }

    /// Decide what carrying `permissions` and `modificationTime` requires of an account with
    /// `capabilities`.
    ///
    /// **A `nil` mode is not a loss.** S3 and FTP's DOS/IIS dialect report none at all, so there is
    /// nothing to carry and nothing to report as dropped — which is the same distinction
    /// ``FileEntry/permissions`` became optional for in M24 Slice 7. Absent and dropped are
    /// different facts, and folding them together would make every S3 copy claim a loss it did not
    /// suffer.
    ///
    /// - Parameters:
    ///   - permissions: the source's mode, or `nil` where the source reported none.
    ///   - modificationTime: the source's mtime, or `nil` where the source reported none.
    ///   - accessTime: the source's atime, or `nil` where the source reported none — which is the
    ///     ordinary case, since no listing this app parses carries one. Note that reading a file
    ///     over `sftp` *bumps the source's own* access time to now, so even a carried atime is a
    ///     copy of a value the act of copying has already changed.
    ///   - capabilities: what this connection has not yet refused.
    public static func carrying(
        permissions: UInt16?,
        modificationTime: Date?,
        accessTime: Date? = nil,
        capabilities: RemoteMetadataCapabilities
    ) -> RemoteMetadataPlan {
        var steps: [RemoteMetadataStep] = []
        var dropped: Set<RemoteMetadataAspect> = []

        let preserve = capabilities.contains(.preserveFlag)
        if preserve { steps.append(.preserveDuringTransfer) }

        if let permissions {
            let mode = POSIXPermissions(rawValue: permissions)
            let hasSpecialBits = mode.setUserID || mode.setGroupID || mode.sticky
            if capabilities.contains(.changeMode) {
                // The corrective `chmod` is worth a round trip only where `-p` cannot express the
                // mode. An ordinary mode over SFTP therefore costs exactly what it always did, and
                // an account with no preserve flag at all pays for every mode it carries.
                if !preserve || hasSpecialBits { steps.append(.setMode(mode)) }
            } else if preserve {
                // `-p` alone: the nine bits arrive, the special ones do not.
                if hasSpecialBits { dropped.insert(.specialModeBits) }
            } else {
                dropped.insert(.mode)
                if hasSpecialBits { dropped.insert(.specialModeBits) }
            }
        }

        if let modificationTime {
            if preserve {
                // Carried by the transfer itself — measured, not assumed.
            } else if capabilities.contains(.setModificationTime) {
                steps.append(.setModificationTime(modificationTime))
            } else {
                dropped.insert(.modificationTime)
            }
        }

        // Nothing but `-p` carries an access time: there is no `MFMT` for it, and `SITE UTIME` is
        // not a verb any server here answers (measured — 500, "command not understood"). Reported
        // only when the caller actually had one, for the same reason a `nil` mode is not a loss.
        if accessTime != nil, !preserve { dropped.insert(.accessTime) }

        return RemoteMetadataPlan(steps: steps, dropped: dropped)
    }
}

/// What a transfer's *source* had, handed down from the listing the caller already made.
///
/// The hint exists because the alternative is a round trip. A download's source is remote, so
/// learning its mode costs a whole connection — 71 ms against a loopback `sshd`, and a real
/// TCP + SSH handshake over a network — while every caller that copies a file already holds the
/// `FileEntry` a listing produced. This is exactly the ``VFSBackend/copyFile(at:to:expectedSize:progress:isCancelled:)``
/// precedent: callers holding a fact from a listing pass it, and anything that would have to *ask*
/// passes nothing and gets the old behaviour.
///
/// Both fields are optional and a `nil` is **absent, never dropped** — the distinction the whole
/// carry turns on (S3 and FTP's DOS/IIS dialect report no mode at all), and the reason
/// ``RemoteMetadataPlan/carrying(permissions:modificationTime:accessTime:capabilities:)`` reports
/// no loss for one.
public struct RemoteSourceMetadata: Sendable, Hashable {
    /// The source's mode, or `nil` where its listing reported none.
    public let permissions: UInt16?
    /// The source's modification time, or `nil` where its listing reported none.
    public let modificationTime: Date?

    public init(permissions: UInt16?, modificationTime: Date?) {
        self.permissions = permissions
        self.modificationTime = modificationTime
    }

    /// The hint a listing's entry carries, or `nil` when it carries neither half — which is what
    /// lets a caller pass `entry.metadataHint` unconditionally without inventing an empty one.
    ///
    /// ``FileEntry/modificationDate`` is a non-optional with a sentinel, so it is read through
    /// ``FileEntry/hasModificationDate`` rather than compared here: a backend with no dates reports
    /// `.distantPast`, and carrying *that* would stamp every copy with year 1.
    public init?(_ entry: FileEntry) {
        let date = entry.hasModificationDate ? entry.modificationDate : nil
        guard entry.permissions != nil || date != nil else { return nil }
        self.init(permissions: entry.permissions, modificationTime: date)
    }

    /// What a file **on this machine** carries, read straight from its `lstat`.
    ///
    /// An upload's source is local, so this costs one syscall and needs no hint from anybody — which
    /// is why an upload carries its source's metadata even when the caller passed none. `lstat`
    /// rather than `stat`, so a symlink reports its own mode instead of its target's, the same rule
    /// the M14 attributes work follows throughout.
    ///
    /// Answers a hint with `nil` fields when the file cannot be read at all, which the plan then
    /// treats as *absent* rather than as a loss — correct, because a source nobody can stat is about
    /// to fail the transfer itself.
    public static func ofLocalFile(_ path: String) -> RemoteSourceMetadata {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else {
            return RemoteSourceMetadata(permissions: nil, modificationTime: nil)
        }
        return RemoteSourceMetadata(
            permissions: UInt16(info.st_mode) & 0o7777,
            modificationTime: Date(
                timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                    + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
            )
        )
    }

    /// What this connection must do to carry it — the plan, asked for in the caller's own words.
    public func plan(with capabilities: RemoteMetadataCapabilities) -> RemoteMetadataPlan {
        RemoteMetadataPlan.carrying(
            permissions: permissions,
            modificationTime: modificationTime,
            capabilities: capabilities
        )
    }
}

/// Why a metadata step did not take, in the only two shapes that call for different answers.
///
/// Protocol-neutral on purpose: the transports produce it from very different evidence — FTP from
/// `curl`'s exit 21 and the server's reply code, SFTP from a `remote setstat "…"` line — and the
/// rule that acts on it lives in one place (``RemoteMetadataSupport``) rather than in each backend.
///
/// The split is the narrowness the latch depends on, and getting it wrong is not symmetric: latching
/// on an item's own refusal would cost every later copy on that connection its metadata because one
/// file was unwritable, while failing to latch a genuinely absent verb costs one wasted round trip
/// per file and nothing else.
public enum RemoteMetadataRefusal: Sendable, Equatable {
    /// **The server does not implement the verb** — FTP reply **500**, measured as the answer to a
    /// `SITE UTIME` no server here offers. True of every file on this connection, so it latches.
    /// The payload is the server's own words, kept verbatim because they are the remote's sentence
    /// and not ours to author (PLAN.md §M12 Slice 11).
    case verbUnimplemented(String)
    /// **That item's own problem** — FTP reply **550**, `sftp`'s
    /// `remote setstat "…": Permission denied`. Says nothing about what the server can do, so it is
    /// counted as a loss for this item and never latched.
    case itemRefused(String)
}

/// What one transfer moved, and whether the metadata riding with it arrived.
///
/// The two travel together because over SFTP they are literally one invocation: the follow-up
/// `chmod` is a line in the same batch as the `get`/`put`, so a separate "did the metadata land"
/// call would be a second connection — 71 ms against a loopback server, and a real TCP + SSH
/// handshake over a network.
///
/// `refusals` names *whether* a step was refused, not *which aspect* was lost: the backend built the
/// plan, so it is the only thing that knows what the steps were carrying. Empty is the good case and
/// the common one — a step that succeeds prints nothing at all.
public struct RemoteTransferOutcome: Sendable, Equatable {
    /// Bytes this call moved, with exactly the meaning the transport's own `download`/`upload`
    /// documents — the whole file, or a resumed remainder.
    public let bytes: Int64
    /// The metadata steps that did not take. Empty when everything the plan asked for arrived.
    public let refusals: [RemoteMetadataRefusal]

    public init(bytes: Int64, refusals: [RemoteMetadataRefusal] = []) {
        self.bytes = bytes
        self.refusals = refusals
    }
}

/// How one transfer runs: whether it resumes, and what it carries besides bytes.
///
/// The two travel together because over SFTP they are one command — `put -ap` is both — and because
/// a transfer verb with five separate parameters is at the point where the next one becomes
/// positional noise at every call site.
public struct RemoteTransferOptions: Sendable, Hashable {
    /// Continue from what is already there (`get -a`/`put -a`) rather than restarting.
    public let resume: Bool
    /// What the source's metadata needs for this transfer to carry it.
    public let carry: RemoteMetadataPlan

    public init(
        resume: Bool = false,
        carry: RemoteMetadataPlan = .carryingNothing
    ) {
        self.resume = resume
        self.carry = carry
    }
}

/// What the caller already knows about a copy's source, handed down so the backend never has to ask.
///
/// The two halves arrived a milestone apart and are one value because they are one idea: *the
/// listing has already read this, and asking again costs a round trip*. The size decides whether a
/// download is split (docs/HISTORY.md ▸ After M19); the metadata decides what the copy carries besides bytes
/// (PLAN.md §M25). Both are free at every real call site, because `CopyEngine` is holding the
/// `FileEntry` a listing produced.
///
/// Bundled rather than passed side by side for the ordinary reason a value type earns its keep here:
/// a third hint would otherwise mean a fourth `copyFile` overload on every backend, and each one is
/// a place the forwarding can be forgotten — which this project has already paid for once, since a
/// hint that stops at a routing backend fails with no symptom at all.
public struct CopySourceHint: Sendable, Hashable {
    /// The source's size, or `nil` where the caller would have had to ask.
    public let expectedSize: Int64?
    /// The source's mode and modification time, or `nil` where its listing reported neither.
    public let metadata: RemoteSourceMetadata?

    public init(expectedSize: Int64? = nil, metadata: RemoteSourceMetadata? = nil) {
        self.expectedSize = expectedSize
        self.metadata = metadata
    }

    /// Everything one listed entry knows about itself.
    public init(_ entry: FileEntry) {
        self.init(expectedSize: entry.byteSize, metadata: RemoteSourceMetadata(entry))
    }

    /// The hint that says nothing — behaviour is then exactly what it was before either half existed.
    public static let none = CopySourceHint()
}
