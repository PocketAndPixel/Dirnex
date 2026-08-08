import Foundation

/// Whether a packed archive is encrypted, and with what.
///
/// This is the pack dialog's state and the `--options` string libarchive's zip writer takes, in one
/// value. Only zip appears here because only zip can do this at all: libarchive's 7-Zip writer
/// rejects `7zip:encryption` outright (`Undefined option`, measured against libarchive 3.7.4), and
/// tar has no notion of encryption whatsoever — so `ArchivePacking.Format.zip` is the only format
/// the pack sheet may offer the checkbox for.
///
/// **Only one cipher is offered, on purpose.** libarchive also accepts `zipcrypt`, the original
/// PKWARE stream cipher, and it is the *only* choice macOS's own `unzip` can read — which makes it
/// permanently tempting and permanently wrong. It has a published known-plaintext break; offering it
/// under a checkbox labelled "Encrypt" would tell the user something untrue about their own files.
/// AES-128 is left out for a smaller reason: it is exactly as compatible as AES-256 (both are the
/// same WinZip AE-2 extension) and AES is hardware-accelerated on every Mac Dirnex runs on, so the
/// weaker option would buy nothing measurable and would still be a way to choose wrong. This
/// follows `ArchivePacking.CompressionLevel`'s precedent of not offering level 0 rather than
/// offering it with a caveat.
///
/// ## What this does and does not hide
///
/// Zip encrypts entry *data* only. The central directory is never encrypted by any zip tool, so an
/// encrypted archive still hands over every file name, size and modification date to anyone holding
/// it — verified directly: `bsdtar -tvf` on an AES-256 archive, with no passphrase, prints the full
/// listing. `ArchivePacking.NamePrivacy` is the answer to that, and this type deliberately does not
/// pretend to be.
public enum ArchiveEncryption: String, CaseIterable, Sendable, Hashable {
    /// No encryption — an ordinary archive anything can open.
    case none

    /// WinZip AES-256 (AE-2). Verified from the bytes libarchive writes: local-header compression
    /// method **99**, extra field `0x9901` carrying AE version 2, vendor `AE`, strength 3 = AES-256,
    /// with deflate as the inner method. That is the interchange format 7-Zip, WinRAR and WinZip all
    /// read on Windows.
    ///
    /// It is *not* what Windows Explorer's built-in zip support reads, nor macOS's own `unzip`
    /// (`unsupported compression method 99`) or Archive Utility (`ditto: Unknown compression type`)
    /// — all three measured. A recipient on either platform needs a real archiver, and the pack
    /// sheet says so rather than letting them find out.
    case aes256

    /// Whether this archive is encrypted at all — the one question most callers have.
    public var isEncrypted: Bool { self != .none }

    /// The `archive_write_set_options` string, or `nil` when there is nothing to set.
    ///
    /// Written **unprefixed** for the same reason `ArchivePacking` writes `compression-level`
    /// unprefixed: a module prefix has to name the writer actually running, so a hardcoded `zip:`
    /// breaks the moment the format changes. Unprefixed, libarchive offers the option to whichever
    /// module is running — and a format whose writer does not know the option refuses the whole
    /// write, which is why the pack sheet gates the checkbox on zip rather than passing this and
    /// hoping.
    var writeOption: String? {
        switch self {
        case .none: return nil
        case .aes256: return "encryption=aes256"
        }
    }

    /// The label the pack dialog shows. Names the cipher rather than saying "Encrypted", because
    /// the recipient needs to know what to open it with, and "AES-256" is the term their archiver
    /// uses too.
    public var displayName: String {
        switch self {
        case .none: return "None"
        case .aes256: return "AES-256"
        }
    }
}
