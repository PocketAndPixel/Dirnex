import Foundation

/// The BSD file-flags word (`st_flags` / `chflags(2)`), modelled as the named bits the attributes
/// panel shows and edits (PLAN.md §M14 Slice 3).
///
/// The one distinction that drives the whole privilege design is encoded here rather than in a table
/// of magic numbers: **the low 16 bits are owner-settable (`UF_*`); the high 16 bits are super-user
/// only (`SF_*`).** That split is a BSD convention, and the M14 probe confirmed it on this Mac — an
/// owner can set `UF_IMMUTABLE` ("Locked") and `UF_HIDDEN` but gets `EPERM` on every `SF_*` flag,
/// even for a file they own. ``AttributePrivilege`` reads that off ``superUserMask`` instead of
/// enumerating cases, so a flag added to macOS later lands on the right side of the line for free.
///
/// `SF_DATALESS` lives here too, but it is never offered as a checkbox: it is set by the cloud file
/// provider, not the user (`chflags` silently drops it — docs/NOTES.md), and it is surfaced through
/// ``FileEntry/isDataless`` for the placeholder guards, not through this editor.
public struct BSDFileFlags: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    // MARK: Owner-settable (low 16 bits, `UF_*`)

    /// `UF_NODUMP` — do not include in a dump.
    public static let noDump = BSDFileFlags(rawValue: UInt32(UF_NODUMP))
    /// `UF_IMMUTABLE` — the file may not be changed. This is Finder's **"Locked"**, and the one flag
    /// with a gotcha: `chmod`/`utimes`/writes fail with `EPERM` while it is set, so a change to any
    /// *other* attribute must clear it first (``AttributeChangePlan``).
    public static let userImmutable = BSDFileFlags(rawValue: UInt32(UF_IMMUTABLE))
    /// `UF_APPEND` — writes may only append.
    public static let userAppend = BSDFileFlags(rawValue: UInt32(UF_APPEND))
    /// `UF_OPAQUE` — the directory is opaque with respect to a union mount.
    public static let opaque = BSDFileFlags(rawValue: UInt32(UF_OPAQUE))
    /// `UF_HIDDEN` — a hint that the item should not be displayed. Dirnex already folds this into
    /// ``FileEntry/isHidden`` alongside a leading-dot name.
    public static let hidden = BSDFileFlags(rawValue: UInt32(UF_HIDDEN))

    // MARK: Super-user only (high 16 bits, `SF_*`)

    /// `SF_ARCHIVED` — the file has been archived.
    public static let archived = BSDFileFlags(rawValue: UInt32(SF_ARCHIVED))
    /// `SF_IMMUTABLE` — immutable, and clearable only by root (unlike ``userImmutable``).
    public static let systemImmutable = BSDFileFlags(rawValue: UInt32(SF_IMMUTABLE))
    /// `SF_APPEND` — append-only, root-gated.
    public static let systemAppend = BSDFileFlags(rawValue: UInt32(SF_APPEND))
    /// `SF_DATALESS` — the bytes are not on this disk; a cloud provider will materialize them. Set by
    /// the provider, never by the user; shown nowhere as a checkbox (see the type doc).
    public static let dataless = BSDFileFlags(rawValue: UInt32(SF_DATALESS))

    /// The high 16 bits — every flag only the super-user may change. Any edit that flips a bit inside
    /// this mask needs root, whoever owns the file (M14 probe, 2026-07-29).
    public static let superUserMask = BSDFileFlags(rawValue: 0xFFFF_0000)

    // MARK: Convenience

    /// Finder's "Locked": the owner-settable immutable bit.
    public var isLocked: Bool { contains(.userImmutable) }

    /// Either immutable bit is set, so a write, `chmod`, `chown` or `utimes` on the file would fail
    /// until it is cleared — the condition ``AttributeChangePlan`` unlocks around.
    public var blocksModification: Bool {
        !intersection([.userImmutable, .systemImmutable]).isEmpty
    }

    /// The bits only root may change (the intersection with ``superUserMask``).
    public var superUserBits: BSDFileFlags { intersection(.superUserMask) }
}
