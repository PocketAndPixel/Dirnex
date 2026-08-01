import Foundation

/// The four digest algorithms Dirnex computes and verifies (PLAN.md §M14 Slice 1).
///
/// The set is chosen for **interop**, not for a spread of speeds. The probe that opened M14
/// measured all four over 256 MiB on this hardware and inverted the usual intuition: `SHA256` runs
/// at ~2100–2300 MiB/s and `Insecure.SHA1` at ~2335 MiB/s because both are ARMv8 crypto
/// instructions, while `Insecure.MD5` (790 MiB/s) and a table-driven CRC32 (534 MiB/s) are ordinary
/// code — **CRC32 is the slowest of the four, not the cheapest.** So SHA-256 is the honest default
/// (``recommended``): it is simultaneously the strongest and among the fastest, and the other three
/// are carried only to match a checksum someone else already published.
///
/// That is what ``isInteropOnly`` is for. MD5 and SHA-1 are both broken against a deliberate
/// collision, so nothing in the UI may present them as a security property — they answer "did these
/// bytes survive the transfer", never "is this file the one the publisher signed".
///
/// The raw value is the stable token: it names the ``fileExtension`` for MD5/SHA-1/SHA-256 and is
/// what any persisted preference would store, so renaming a case is a migration, not a rename.
public enum ChecksumAlgorithm: String, Sendable, Hashable, CaseIterable {
    case crc32
    case md5
    case sha1
    case sha256

    /// The algorithm Dirnex offers first — the strongest of the four, and among the fastest.
    public static let recommended: ChecksumAlgorithm = .sha256

    /// The name shown in menus and written into a manifest's header row.
    ///
    /// Never localized: `SHA-256` is technical vocabulary in the same class as `SFTP` and `bsdtar`,
    /// and a translated digest name would stop matching what every other tool prints.
    public var displayName: String {
        switch self {
        case .crc32: return "CRC32"
        case .md5: return "MD5"
        case .sha1: return "SHA-1"
        case .sha256: return "SHA-256"
        }
    }

    /// Digest length in hexadecimal digits — 8 · 32 · 40 · 64.
    ///
    /// The four widths are distinct, which is what lets ``init(hexDigitCount:)`` recover the
    /// algorithm from a manifest line that never names it (GNU and SFV lines carry only the hex).
    public var hexDigitCount: Int {
        switch self {
        case .crc32: return 8
        case .md5: return 32
        case .sha1: return 40
        case .sha256: return 64
        }
    }

    /// Digest length in bytes — 4 · 16 · 20 · 32.
    public var byteCount: Int { hexDigitCount / 2 }

    /// The extension a manifest of this algorithm is conventionally saved under: `sfv` for CRC32
    /// (the format's own name), the algorithm's own token for the other three (`file.sha256`).
    public var fileExtension: String {
        self == .crc32 ? "sfv" : rawValue
    }

    /// The manifest layout this algorithm is written in — `.sfv` for CRC32, GNU style for the rest.
    /// Reading is tolerant of every form regardless (``ChecksumManifest/parse(_:implicitName:)``);
    /// this is only what Dirnex *writes*.
    public var manifestFormat: ChecksumManifestFormat {
        self == .crc32 ? .sfv : .gnu
    }

    /// Carried to match a checksum someone else published, never as a security property.
    ///
    /// CRC32 is not a cryptographic hash at all, and MD5 and SHA-1 both have practical collision
    /// attacks: they can confirm that bytes survived a copy, and cannot confirm that a file is the
    /// one a publisher signed. A UI that offers them must not imply otherwise.
    public var isInteropOnly: Bool { self != .recommended }

    /// Recover the algorithm from a bare digest's width — the only signal a GNU or SFV line carries.
    /// Returns `nil` for any other length, which is how a truncated or malformed line is rejected
    /// rather than guessed at.
    public init?(hexDigitCount: Int) {
        guard let match = Self.allCases.first(where: { $0.hexDigitCount == hexDigitCount }) else {
            return nil
        }
        self = match
    }

    /// Recover the algorithm from the label BSD `md5` and `openssl dgst` print ahead of the name —
    /// `MD5 (file) = …`, `SHA256(file)= …`.
    ///
    /// Deliberately tolerant, because the producers disagree: LibreSSL (what macOS ships) writes
    /// `SHA256`, OpenSSL 3 writes `SHA2-256`, and a hand-written file may use `SHA-256`. Case,
    /// hyphens and internal spaces are all ignored, so all three land on the same case.
    public init?(label: String) {
        let normalized = label
            .uppercased()
            .filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
        switch normalized {
        case "CRC32", "CRC": self = .crc32
        case "MD5": self = .md5
        case "SHA1": self = .sha1
        case "SHA256", "SHA2256": self = .sha256
        default: return nil
        }
    }
}
