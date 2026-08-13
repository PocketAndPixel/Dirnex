import Foundation

/// Why a bucket name cannot be used.
///
/// The vocabulary exists because **the server will not tell the user which rule they broke.**
/// Measured 2026-08-13 against a real S3-compatible endpoint: an uppercase name, a two-character
/// name, an underscore, an IP-shaped name and a 64-character name all came back as the *same*
/// answer — `400 InvalidBucketName`, "The specified bucket is not valid." Five different mistakes,
/// one indistinguishable sentence, and nothing in it a user can act on.
///
/// So this is not a round-trip optimisation. Refusing locally is the only way the person typing
/// finds out that the problem is the capital letter. Like every other core vocabulary that reaches
/// the screen (`VFSUnsupportedReason`, `UndoActionLabel`), it is **data**: the case is the fact and
/// the app supplies the sentence, since a layer that authors words is a layer whose words nobody
/// can translate.
public enum S3BucketNameProblem: Sendable, Equatable, CaseIterable {
    /// Shorter than ``S3BucketName/minimumLength``.
    case tooShort
    /// Longer than ``S3BucketName/maximumLength``.
    case tooLong
    /// Something outside `a-z`, `0-9`, `-` and `.` — most often an uppercase letter or an
    /// underscore, which are the two mistakes a person carrying a habit from file names makes.
    case invalidCharacter
    /// Starts or ends with something other than a letter or a digit.
    case badEdge
    /// Two dots in a row, which S3 rejects even though a single dot is legal.
    case consecutiveDots
    /// Formatted as an IPv4 address, which S3 reserves so a bucket cannot shadow an address.
    case addressFormatted
    /// One of the prefixes S3 reserves (`xn--`, `sthree-`).
    case reservedPrefix
    /// One of the suffixes S3 reserves (`-s3alias`, `--ol-s3`).
    case reservedSuffix
}

/// The bucket-naming rules, applied before a request is sent.
///
/// Pure and tested, and deliberately **stricter than any one server**: an S3-compatible endpoint is
/// free to accept a name AWS would not, and a name that works on one provider and not the next is a
/// bucket the user cannot move. The rules are AWS's published general-purpose set, which every
/// server in this family is a superset of.
///
/// One rule is deliberately *not* here, because it is not a naming rule at all — see
/// ``breaksVirtualHostTLS(_:)``.
public enum S3BucketName {
    public static let minimumLength = 3
    public static let maximumLength = 63

    /// The first rule `name` breaks, or `nil` when it breaks none.
    ///
    /// First rather than all of them: the user fixes one thing and asks again, and a list of eight
    /// complaints about a three-character typo is noise. The order runs cheapest and most likely
    /// first, so the answer for an ordinary mistake is the ordinary explanation.
    public static func problem(with name: String) -> S3BucketNameProblem? {
        if name.count < minimumLength { return .tooShort }
        if name.count > maximumLength { return .tooLong }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard name.unicodeScalars.allSatisfy(allowed.contains) else { return .invalidCharacter }

        let isAlphanumeric: (Character) -> Bool = { $0.isLowercase || $0.isNumber }
        // Checked on the *first* and *last* character rather than with a trim, because a name that
        // is entirely hyphens has no alphanumeric edge to find and must not read as empty.
        guard let first = name.first, let last = name.last,
              isAlphanumeric(first), isAlphanumeric(last) else { return .badEdge }

        if name.contains("..") { return .consecutiveDots }
        if isAddressFormatted(name) { return .addressFormatted }
        if ["xn--", "sthree-"].contains(where: name.hasPrefix) { return .reservedPrefix }
        if ["-s3alias", "--ol-s3"].contains(where: name.hasSuffix) { return .reservedSuffix }
        return nil
    }

    /// Whether `name` is usable at all.
    public static func isValid(_ name: String) -> Bool { problem(with: name) == nil }

    /// Whether a **valid** name will nonetheless be unreachable over TLS under virtual-host
    /// addressing.
    ///
    /// Separate from ``problem(with:)`` because it is not a rule about the name — the name is
    /// perfectly legal, and was accepted by a real endpoint in the same probe run (2026-08-13). It
    /// is a rule about the *host* the name then becomes: a wildcard certificate is one label deep
    /// (RFC 6125), so `my.dotted.bucket.s3.example.com` is not covered by `*.s3.example.com` and the
    /// connection fails at curl exit 60 before any S3 conversation happens (docs/NOTES.md ▸ curl
    /// ▸ S3, where this cost a user their first connect).
    ///
    /// It applies to AWS exactly as it does to a third-party endpoint, so the caller must key the
    /// warning on the *addressing mode* and never on the provider. A warning rather than a refusal:
    /// path-style reaches such a bucket perfectly, and a name the user has good reason to want is
    /// not ours to forbid.
    public static func breaksVirtualHostTLS(_ name: String) -> Bool { name.contains(".") }

    /// Whether the name reads as an IPv4 address.
    ///
    /// Written out rather than reached for as a regular expression so the rule is exactly four
    /// decimal octets and nothing else: `192.168.1.50` is reserved, while `192.168.1.50.backup` is
    /// an ordinary name and must stay usable.
    private static func isAddressFormatted(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && Int(part).map { $0 <= 255 } == true
        }
    }
}
