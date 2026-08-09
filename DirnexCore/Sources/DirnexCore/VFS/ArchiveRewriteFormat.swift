import Foundation

/// How an archive was built, so rewriting it can put it back the same way (PLAN.md §M4 archive
/// writes, §M19 encryption).
///
/// Every write inside a browsed archive — F8 delete, F5/paste add, and editing a member in place —
/// is the same rewrite: extract the whole thing, change the tree on disk, repack, swap atomically.
/// The repack therefore has to re-state what the original archive already was, and nothing in the
/// rewrite path knows that on its own. Reading it off an inspection keeps the answer in one place
/// and makes it testable, rather than each call site guessing.
///
/// Two properties, because two are all that a repack cannot re-derive from the extracted tree: a
/// tree on disk says nothing about whether it came out of an encrypted archive, and — since the
/// reader unwraps a hidden-names archive transparently — nothing about whether its names were
/// hidden either. Everything else (the container format, the compression) is carried by the new
/// archive's suffix and libarchive's own defaults.
public struct ArchiveRewriteFormat: Sendable, Equatable {
    public let encryption: ArchiveEncryption
    public let namePrivacy: ArchiveNamePrivacy

    public init(encryption: ArchiveEncryption, namePrivacy: ArchiveNamePrivacy) {
        self.encryption = encryption
        self.namePrivacy = namePrivacy
    }

    /// An ordinary archive: no passphrase, names visible. What every rewrite did before encrypted
    /// archives could be written into at all.
    public static let plain = ArchiveRewriteFormat(encryption: .none, namePrivacy: .visible)

    /// Whether rewriting this archive needs the user's passphrase.
    public var needsPassphrase: Bool { encryption.isEncrypted }

    /// Read the format off an inspection — headers only, so it costs no decryption and needs no
    /// passphrase, which is what lets a rewrite decide whether to *ask* for one.
    ///
    /// **Encryption is reported as AES-256 whenever any entry is encrypted, whatever the original
    /// used.** libarchive's reader does not report a zip's cipher strength, and AES-256 is the only
    /// encryption Dirnex writes (§M19 took that decision at open: `zipcrypt` is broken and AES-128
    /// buys nothing on hardware AES). So an AES-128 archive made elsewhere comes back stronger than
    /// it went in, and that is the safe direction for the one thing that cannot be re-derived — the
    /// alternative is guessing a weaker cipher from no evidence.
    ///
    /// Name privacy is recognized by shape, the same way ``ArchiveNamePrivacy/looksWrapped(_:)``
    /// does everywhere else — a single entry with the wrapper's name. An archive somebody else built
    /// that happens to hold exactly one file called `Contents.tar` is indistinguishable from ours,
    /// and reads as hidden-names; that is the pre-existing cost of a marker-free format, and it is
    /// deliberate (a marker would announce in plaintext that the archive is worth attacking).
    public static func inferred(from inspection: EncryptedArchiveReader.Inspection) -> Self {
        ArchiveRewriteFormat(
            encryption: inspection.needsPassphrase ? .aes256 : .none,
            namePrivacy: ArchiveNamePrivacy.looksWrapped(inspection.entries.map(\.archivePath))
                ? .hidden
                : .visible
        )
    }
}
