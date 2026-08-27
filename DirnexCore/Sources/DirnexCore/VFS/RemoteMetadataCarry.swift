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
