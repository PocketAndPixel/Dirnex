import Foundation
import Testing

@testable import DirnexCore

/// The certificate under test is the **real** one presented by the FTPS server probed on
/// 2026-07-25, captured with `openssl s_client -starttls ftp`. Both expected digests were computed
/// independently by `openssl`, not by this code — which is the point: a DER walk that drifted would
/// silently pin the *wrong* key, and comparing against our own output would never catch it.
///
///     openssl x509 -in cert.pem -noout -fingerprint -sha256
///     openssl x509 -in cert.pem -pubkey -noout \
///       | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | openssl base64
@Suite("FTP certificate")
struct FTPCertificateTests {
    /// The captured self-signed certificate (`CN=test-server.local`, RSA-2048), base64 DER.
    static let realCertificateBase64 = """
    MIIDCTCCAfGgAwIBAgIRAM+UFPcIvdRCkCHP1reN/rcwDQYJKoZIhvcNAQELBQAwHDEaMBgGA1UEAxMRdGVzdC1zZXJ2\
    ZXIubG9jYWwwHhcNMjYwNzE0MTExMTA2WhcNMjcwNzE0MTExMTA2WjAcMRowGAYDVQQDExF0ZXN0LXNlcnZlci5sb2Nh\
    bDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBANG8IF7LzM31aCWso1dUE2cCqxMPNLxps+O0OTpALUfff6Fr\
    FyI+3pyYAD5eQqMpjSgYMmgVCVBtAHN1TSxUlaTXGdJpu5FaGAaM6H0JXe04kc8yciJzltK6TfW+2nNexVzdPXr30jKx\
    HKaTOgX/QQDbeWESbh5UEZ+gxK1E97TcRIrzO7IeTosWAV2SK/KcFtlAUU5Kc3X4Hxmfnj+1De4vE3y9phBcuallyb5X\
    cBmMiFp3ABKmmD/D45o/FiZxV47M546A8iJqxjzgA3JWjM277xGb6GPHW0Kx3b2qIO/78D0UTy+kuxI1B5Y1apVEHA9T\
    0j917n0r4RhCs/ZE7Q0CAwEAAaNGMEQwDgYDVR0PAQH/BAQDAgeAMB0GA1UdDgQWBBS6fBJuRtjEjhz0y4whDFFRX76h\
    GzATBgNVHSUEDDAKBggrBgEFBQcDATANBgkqhkiG9w0BAQsFAAOCAQEALsEfg/WVECS02mNEu4LMG/kxFSMYzHkM1BKI\
    Ym1q8l273KxxGsBQv5ihurTrXpM/edwZmsVHfJ1ltBG78AJqANAF4WMj1FWbE4vLVd0epBKrItHpyygzjHRL5zlvdpXp\
    Q7UjR7aoyEn7qQF/tWPeuceRf5aqU8OB1IEjBZDhkNHGsGy3kvIHJHP+UL9iOzK5Ak92x6RCmVMk1KkTLAooPRKN7pdn\
    TNN82acdBr6KL5d4jmqbtwLM7vKqKC/35DoAuDOQF/6V1rapdv7fj+Ongjc5381QC1wQwLTSFIx1T3yqAkzGULHWpJJY\
    fncNvq2ju1bPiBti/jLdvh15qbTreg==
    """

    /// `openssl x509 -fingerprint -sha256`, colons and all.
    static let expectedCertificateFingerprint =
        "BF:F1:A6:6D:E6:FA:0E:1E:F8:34:B3:64:2C:E0:53:43:42:DA:ED:55:86:60:31:86:B3:D2:66:F0:D6:C3:B6:99"

    /// The value `--pinnedpubkey sha256//…` accepted live against this server.
    static let expectedPublicKeyPin = "NWrJwng2ZjCZklZSMVK1IsolOd+LavrDTCcNa+oHnJ4="

    static func realCertificate() throws -> FTPCertificate {
        let der = try #require(Data(base64Encoded: realCertificateBase64))
        return FTPCertificate(subject: "", issuer: "", notBefore: "", notAfter: "", der: der)
    }

    @Test("The certificate fingerprint matches openssl's, byte for byte")
    func certificateFingerprintMatchesOpenSSL() throws {
        let certificate = try Self.realCertificate()
        #expect(certificate.certificateFingerprint == Self.expectedCertificateFingerprint)
    }

    /// The load-bearing test in this file: this is the digest `curl` enforces, so a wrong answer
    /// here means pinning a key the server never presented.
    @Test("The public-key pin matches the value curl accepted live")
    func publicKeyPinMatchesLiveAcceptedValue() throws {
        let certificate = try Self.realCertificate()
        #expect(certificate.publicKeyPin == Self.expectedPublicKeyPin)
    }

    @Test("A truncated certificate yields no pin rather than a wrong one")
    func truncatedCertificateHasNoPin() throws {
        let full = try #require(Data(base64Encoded: Self.realCertificateBase64))
        let certificate = FTPCertificate(
            subject: "", issuer: "", notBefore: "", notAfter: "",
            der: full.prefix(120)
        )
        #expect(certificate.publicKeyPin == nil)
    }

    @Test("Random bytes are not walkable and yield no pin")
    func garbageHasNoPin() {
        let certificate = FTPCertificate(
            subject: "", issuer: "", notBefore: "", notAfter: "",
            der: Data([0x30, 0x82, 0xFF, 0xFF, 0x01, 0x02, 0x03])
        )
        #expect(certificate.publicKeyPin == nil)
    }

    // MARK: - Parsing curl's %{certs} block

    /// Trimmed from the real `curl -w '%{certs}'` output captured in the same probe — the labels are
    /// verbatim, including `curl`'s spacing inside `CN = …`.
    static let realCurlBlock = """
    Subject:CN = test-server.local
    Issuer:CN = test-server.local
    Version:2
    Serial Number:cf9414f708bdd4429021cfd6b78dfeb7
    Signature Algorithm:sha256WithRSAEncryption
    Public Key Algorithm:rsaEncryption
    Start date:Jul 14 11:11:06 2026 GMT
    Expire date:Jul 14 11:11:06 2027 GMT
    RSA Public Key:2048
    -----BEGIN CERTIFICATE-----
    \(realCertificateBase64)
    -----END CERTIFICATE-----
    """

    @Test("curl's %{certs} block parses into a certificate with the same pin")
    func parsesCurlCertificateBlock() throws {
        let certificate = try #require(
            FTPCertificate.parse(curlCertificateBlock: Self.realCurlBlock)
        )
        #expect(certificate.subject == "CN = test-server.local")
        #expect(certificate.issuer == "CN = test-server.local")
        #expect(certificate.notBefore == "Jul 14 11:11:06 2026 GMT")
        #expect(certificate.notAfter == "Jul 14 11:11:06 2027 GMT")
        #expect(certificate.publicKeyPin == Self.expectedPublicKeyPin)
        #expect(certificate.certificateFingerprint == Self.expectedCertificateFingerprint)
    }

    @Test("A block with labels but no PEM is not a certificate")
    func labelsWithoutPEMAreRejected() {
        let block = "Subject:CN = nas.local\nIssuer:CN = nas.local\n"
        #expect(FTPCertificate.parse(curlCertificateBlock: block) == nil)
    }

    @Test("The fingerprint is grouped for side-by-side comparison")
    func fingerprintIsGroupedForDisplay() throws {
        let lines = try Self.realCertificate().fingerprintLines(groupsPerLine: 16)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("BF:F1:A6:6D"))
        #expect(lines.joined(separator: ":") == Self.expectedCertificateFingerprint)
    }
}
