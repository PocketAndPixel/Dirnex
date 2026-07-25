import CryptoKit
import Foundation

/// A server certificate as `curl` hands it over, reduced to the few facts a trust decision needs:
/// who it claims to be, how long it is valid, and the two digests — one for the user to *compare*,
/// one for `curl` to *enforce*.
///
/// This exists because FTPS trust is a user decision Dirnex has to be able to state precisely.
/// Probed live 2026-07-25 against a self-signed server, three findings shaped the whole design:
///
/// - **`--cacert` cannot be used to trust a self-signed server.** Handing `curl` the server's own
///   certificate as a trust anchor still fails — `certificate subject name 'test-server.local' does
///   not match target host name '192.168.1.50'` — because a NAS's certificate almost never names
///   the address the user types. So "add it to the trust store" is not an available design.
/// - **`--pinnedpubkey sha256//…` is, and it is exact.** Verified on both of this `curl`'s TLS
///   backends (SecureTransport and LibreSSL): the correct pin transfers, and a *wrong* pin aborts
///   with exit 90 before any data moves. That is trust-on-first-use with the same teeth as SSH's
///   host-key pinning — which is what PLAN.md §M13 asks for, and it is why `--insecure` is only
///   ever passed **together with** a stored pin (see `FTPProcessArguments`).
/// - **`curl -w '%{certs}'` prints the whole chain as PEM**, so the app never shells out to
///   `openssl` to see what it is trusting. That output is what ``parse(curlCertificateBlock:)``
///   reads.
///
/// Pure and tested — the ASN.1 walk below is verified against a real captured certificate whose pin
/// was computed independently by `openssl`, so a silent mis-parse (the failure mode that would let a
/// *wrong* key be pinned) cannot pass the suite.
public struct FTPCertificate: Sendable, Hashable {
    /// The certificate's subject, as `curl` prints it (`CN = nas.local`); empty if absent.
    public let subject: String
    /// The issuing authority; equal to ``subject`` for the self-signed certificates this exists for.
    public let issuer: String
    /// The validity window's start, verbatim in `curl`'s wording; empty if absent.
    public let notBefore: String
    /// The validity window's end, verbatim in `curl`'s wording; empty if absent.
    public let notAfter: String
    /// The certificate itself, DER-encoded — the bytes both digests are taken over.
    public let der: Data

    public init(subject: String, issuer: String, notBefore: String, notAfter: String, der: Data) {
        self.subject = subject
        self.issuer = issuer
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.der = der
    }
}

public extension FTPCertificate {
    /// SHA-256 over the whole certificate, colon-separated uppercase hex — the form every other tool
    /// shows (`openssl x509 -fingerprint -sha256`, a browser's certificate viewer, a NAS admin page).
    ///
    /// This is the value a user **compares against the server**, and it is the only reason it is
    /// computed: it is *not* what gets enforced. A certificate reissued from the same key changes
    /// this string while ``publicKeyPin`` stays put, which is the SSH model — key continuity — and
    /// is deliberate: a routine certificate renewal shouldn't read as a security incident.
    var certificateFingerprint: String {
        SHA256.hash(data: der)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }

    /// Base64 SHA-256 over the `SubjectPublicKeyInfo` — exactly the digest `--pinnedpubkey
    /// sha256//<this>` compares against, so it is what Dirnex stores and enforces.
    ///
    /// `nil` when the certificate can't be walked, which callers must treat as "cannot be trusted"
    /// rather than falling back to an unpinned connection.
    var publicKeyPin: String? {
        guard let spki = FTPCertificate.subjectPublicKeyInfo(inCertificate: der) else { return nil }
        return Data(SHA256.hash(data: spki)).base64EncodedString()
    }

    /// Split a colon-hex fingerprint into fixed-width groups for display, so a user comparing it
    /// against a server's admin page reads it in the same chunks rather than as one 95-character run.
    func fingerprintLines(groupsPerLine: Int = 16) -> [String] {
        let groups = certificateFingerprint.split(separator: ":").map(String.init)
        return stride(from: 0, to: groups.count, by: groupsPerLine).map { start in
            groups[start..<min(start + groupsPerLine, groups.count)].joined(separator: ":")
        }
    }
}

// MARK: - Reading curl's output

public extension FTPCertificate {
    /// Parse the block `curl -w '%{certs}'` writes: labelled `Key:value` lines followed by the
    /// PEM-armoured certificate. When a chain is present the **leaf comes first**, which is the one
    /// being pinned, so parsing stops at the first complete certificate.
    ///
    /// Returns `nil` when no PEM block is present — the labels alone are not a certificate, and
    /// pinning without the bytes is not possible.
    static func parse(curlCertificateBlock block: String) -> FTPCertificate? {
        guard let der = firstCertificateDER(in: block) else { return nil }
        return FTPCertificate(
            subject: labelledValue("Subject", in: block),
            issuer: labelledValue("Issuer", in: block),
            notBefore: labelledValue("Start date", in: block),
            notAfter: labelledValue("Expire date", in: block),
            der: der
        )
    }

    /// The value of the first `Label:value` line, trimmed. `curl` prints these unlocalized and one
    /// per line; a missing label yields "" rather than failing the whole parse, since the digests —
    /// the part that matters — come from the PEM.
    private static func labelledValue(_ label: String, in block: String) -> String {
        for line in block.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("\(label):") else { continue }
            return String(text.dropFirst(label.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    /// The DER bytes of the first `-----BEGIN CERTIFICATE-----` block, or `nil` if there is none.
    private static func firstCertificateDER(in text: String) -> Data? {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        guard let start = text.range(of: begin),
              let stop = text.range(of: end, range: start.upperBound..<text.endIndex) else {
            return nil
        }
        let base64 = text[start.upperBound..<stop.lowerBound]
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined()
        return Data(base64Encoded: base64)
    }
}

// MARK: - Minimal DER walking

private extension FTPCertificate {
    /// One DER tag-length-value element: where the whole thing starts, where its contents sit, and
    /// where it ends. ``start`` is carried rather than derived, because the digest is taken over the
    /// *complete* TLV and reconstructing a header's width after the fact is guesswork.
    struct DERElement {
        let tag: UInt8
        let start: Int
        let valueStart: Int
        let end: Int
    }

    /// Read the element beginning at `index`, or `nil` if the bytes are truncated or malformed.
    /// Only single-byte tags and definite lengths are handled — DER requires both, and every
    /// structural element of a certificate uses them.
    static func element(in bytes: [UInt8], at index: Int) -> DERElement? {
        guard index >= 0, index + 1 < bytes.count else { return nil }
        let tag = bytes[index]
        var cursor = index + 1
        let lengthByte = bytes[cursor]
        cursor += 1
        var length = 0
        if lengthByte & 0x80 == 0 {
            length = Int(lengthByte)
        } else {
            // Long form: the low seven bits count the big-endian length bytes that follow. Four is
            // far past any real certificate and keeps the shift from overflowing.
            let count = Int(lengthByte & 0x7F)
            guard count > 0, count <= 4, cursor + count <= bytes.count else { return nil }
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[cursor])
                cursor += 1
            }
        }
        guard length >= 0, cursor + length <= bytes.count else { return nil }
        return DERElement(tag: tag, start: index, valueStart: cursor, end: cursor + length)
    }

    /// The `SubjectPublicKeyInfo` element's complete bytes (tag and length included — the digest is
    /// taken over the whole TLV, which is what `curl` hashes) from a DER certificate.
    ///
    ///     Certificate    ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
    ///     TBSCertificate ::= SEQUENCE { [0] version OPTIONAL, serialNumber, signature,
    ///                                   issuer, validity, subject, subjectPublicKeyInfo, … }
    ///
    /// So: descend into the certificate, descend into its first child, skip the optional `[0]`
    /// version tag, then step over the five fields that precede the key.
    static func subjectPublicKeyInfo(inCertificate der: Data) -> Data? {
        let bytes = [UInt8](der)
        guard let certificate = element(in: bytes, at: 0), certificate.tag == sequenceTag,
              let tbs = element(in: bytes, at: certificate.valueStart), tbs.tag == sequenceTag,
              var current = element(in: bytes, at: tbs.valueStart) else { return nil }

        // `version` is `[0] EXPLICIT` and defaulted, so it is present on v3 certificates and absent
        // on v1 ones. Skipping it only when the tag is actually there keeps both readable.
        if current.tag == versionTag {
            guard let next = element(in: bytes, at: current.end) else { return nil }
            current = next
        }
        // serialNumber, signature, issuer, validity, subject — then the key.
        for _ in 0..<5 {
            guard current.end < tbs.end, let next = element(in: bytes, at: current.end) else {
                return nil
            }
            current = next
        }
        guard current.tag == sequenceTag else { return nil }
        return Data(bytes[current.start..<current.end])
    }

    /// ASN.1 universal SEQUENCE (constructed).
    static var sequenceTag: UInt8 { 0x30 }
    /// Context-specific constructed `[0]` — `TBSCertificate`'s explicit `version` wrapper.
    static var versionTag: UInt8 { 0xA0 }
}
