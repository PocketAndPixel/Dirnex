import Foundation

/// A Dirnex license key that passed every check (PLAN.md §M29): who it's for, and the last release
/// day it covers.
///
/// The key is `dnx1.<payload>.<signature>`. The payload is base64url JSON
/// `{v, id, to, issued, until}`, and the signature is Ed25519 over the ASCII bytes of
/// `dnx1.<payload>`. The store's server signs keys with the TypeScript module in the private repo,
/// and both sides are pinned by the same vectors (`Fixtures/license-vectors.json`).
///
/// A value of this type exists only after ``LicenseVerifier/check(_:)`` accepted the text, so
/// holding one means the signature matched.
public struct LicenseKey: Sendable, Hashable {
    public static let prefix = "dnx1."
    public static let formatVersion = 1

    /// The longest key accepted after whitespace is removed, in UTF-8 bytes. A real key is about
    /// 250, and the size is checked before anything is decoded.
    public static let maximumBytes = 1024

    /// The key's text with whitespace removed. This is what preferences keep.
    public let text: String
    /// 128 random bits in base32. The only part of a key that ever goes into a URL.
    public let id: String
    /// The name shown as "Licensed to …". The payload calls it `to`.
    public let licensee: String
    public let issued: LicenseDay
    /// The last release day this key covers.
    public let until: LicenseDay
}

/// Why a text was refused as a key. The raw values are the names the shared vectors and the signer
/// use.
public enum LicenseKeyError: String, Error, Sendable, CaseIterable {
    /// Nothing but whitespace.
    case empty
    /// Far longer than any key.
    case tooLong
    /// Not a Dirnex key at all.
    case wrongPrefix
    /// A key from a newer format (`dnx2.` or a payload `v` above 1), which needs a newer Dirnex.
    case unsupportedVersion
    /// Shaped wrong: cut short while copying, or damaged.
    case malformed
    /// Not signed by the key this Dirnex carries, or changed after signing.
    case badSignature
    /// Signed, but the contents aren't a license. Only a bug in the signer produces this.
    case invalidPayload
}

extension LicenseKey {
    /// A key split into its parts but not yet trusted. The signature has to match before the
    /// payload's JSON is read, so a JSON parser never sees bytes the store didn't sign.
    struct Envelope {
        let text: String
        /// The ASCII bytes of `dnx1.<payload>`, which the signature covers.
        let signedMessage: Data
        let payload: Data
        let signature: Data
    }

    /// The invisible characters an email or a copy adds to a key: every Unicode space and line
    /// break, plus the zero-width ones and the soft hyphen that HTML mail inserts when it wraps a
    /// long word. The signer removes exactly the same set. Neither language's own idea of
    /// whitespace would do: `Character.isWhitespace` misses U+200B and U+FEFF, and JavaScript's
    /// `\s` misses U+0085, so the two would disagree.
    private static let invisible: Set<UInt32> = [
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0xAD, 0x1680,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
        0x200B, 0x200C, 0x200D, 0x2028, 0x2029, 0x202F, 0x205F, 0x2060, 0x3000, 0xFEFF
    ]

    /// `pasted` without the characters in ``invisible``. Works on Unicode scalars, not
    /// `Character`s: a CRLF is one `Character`, and a combining mark would glue itself to the
    /// character before it.
    public static func normalized(_ pasted: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: pasted.unicodeScalars.filter { !invisible.contains($0.value) })
        return String(scalars)
    }

    /// Steps one to four of the check: size, prefix, shape and base64url. Every comparison is on
    /// UTF-8 bytes, not `String`, because Swift compares strings by canonical equivalence and a
    /// combining mark after the prefix's dot would change the answer the signer gives.
    static func envelope(of pasted: String) -> Result<Envelope, LicenseKeyError> {
        let text = normalized(pasted)
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return .failure(.empty) }
        guard bytes.count <= maximumBytes else { return .failure(.tooLong) }
        let prefix = Array(prefix.utf8)
        guard bytes.starts(with: prefix) else {
            return .failure(isLaterFormat(bytes) ? .unsupportedVersion : .wrongPrefix)
        }
        let segments = bytes[prefix.count...].split(
            separator: UInt8(ascii: "."),
            omittingEmptySubsequences: false
        )
        guard segments.count == 2,
              let payload = Base64URL.decode(segments[0]), !payload.isEmpty,
              let signature = Base64URL.decode(segments[1]), signature.count == 64
        else {
            return .failure(.malformed)
        }
        return .success(Envelope(
            text: text,
            signedMessage: Data(prefix + segments[0]),
            payload: payload,
            signature: signature
        ))
    }

    /// `dnx`, one or more ASCII digits, and a dot: a key in a format after `dnx1`. PLAN.md's plan
    /// for a leaked private key is a new pair and a `dnx2` prefix, so an older Dirnex handed such a
    /// key says it needs a newer version rather than that it isn't a key.
    private static func isLaterFormat(_ bytes: [UInt8]) -> Bool {
        guard bytes.starts(with: Array("dnx".utf8)) else { return false }
        let rest = bytes.dropFirst(3)
        let digits = rest.prefix { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
        return !digits.isEmpty && rest.dropFirst(digits.count).first == UInt8(ascii: ".")
    }

    /// The last step, run only after the signature matched. Fields this version doesn't know are
    /// ignored, so the format can grow.
    ///
    /// A byte-order mark is refused before `JSONDecoder` sees the bytes, since it would skip one
    /// where the signer's `JSON.parse` doesn't (`payload-with-bom`). Bytes that aren't UTF-8 need no
    /// such step: `JSONDecoder` refuses overlong forms, surrogates, truncated sequences and stray
    /// bytes, as the signer's strict `TextDecoder` does (measured 2026-09-29), and
    /// `payload-not-utf8` fails if that ever changes.
    static func decode(_ envelope: Envelope) -> Result<LicenseKey, LicenseKeyError> {
        let payload = envelope.payload
        guard !payload.starts(with: [0xEF, 0xBB, 0xBF]),
              let version = try? JSONDecoder().decode(PayloadVersion.self, from: payload)
        else {
            return .failure(.invalidPayload)
        }
        guard version.version == formatVersion else { return .failure(.unsupportedVersion) }
        guard let fields = try? JSONDecoder().decode(PayloadFields.self, from: payload),
              !fields.id.isEmpty, !fields.to.isEmpty,
              let issued = LicenseDay(fields.issued), let until = LicenseDay(fields.until)
        else {
            return .failure(.invalidPayload)
        }
        return .success(LicenseKey(
            text: envelope.text,
            id: fields.id,
            licensee: fields.to,
            issued: issued,
            until: until
        ))
    }
}

/// The payload's `v`, read on its own first: a later version may not carry the fields below.
private struct PayloadVersion: Decodable {
    let version: Int

    enum CodingKeys: String, CodingKey {
        case version = "v"
    }
}

/// The fields every version-1 payload carries.
private struct PayloadFields: Decodable {
    let id: String
    let to: String
    let issued: String
    let until: String
}
