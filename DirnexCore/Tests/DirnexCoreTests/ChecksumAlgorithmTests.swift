import Foundation
import Testing

@testable import DirnexCore

@Suite("ChecksumAlgorithm")
struct ChecksumAlgorithmTests {
    /// The whole unlabelled-line parse rests on this: a GNU or `.sfv` line carries only hex, so
    /// the width has to name the algorithm on its own.
    @Test("the four digest widths are distinct")
    func widthsAreDistinct() {
        let widths = ChecksumAlgorithm.allCases.map(\.hexDigitCount)
        #expect(Set(widths).count == widths.count)
        #expect(widths == [8, 32, 40, 64])
    }

    @Test("an algorithm is recovered from its digest width")
    func recoverFromWidth() {
        for algorithm in ChecksumAlgorithm.allCases {
            #expect(ChecksumAlgorithm(hexDigitCount: algorithm.hexDigitCount) == algorithm)
        }
        #expect(ChecksumAlgorithm(hexDigitCount: 0) == nil)
        #expect(ChecksumAlgorithm(hexDigitCount: 63) == nil)
        #expect(ChecksumAlgorithm(hexDigitCount: 128) == nil)
    }

    /// The producers disagree — LibreSSL (what macOS ships) writes `SHA256`, OpenSSL 3 writes
    /// `SHA2-256`, BSD `md5` writes `MD5` — so the label match ignores case, hyphens and spaces.
    @Test("the BSD and openssl labels all resolve")
    func recoverFromLabel() {
        #expect(ChecksumAlgorithm(label: "MD5") == .md5)
        #expect(ChecksumAlgorithm(label: "md5") == .md5)
        #expect(ChecksumAlgorithm(label: "SHA1") == .sha1)
        #expect(ChecksumAlgorithm(label: "SHA-1") == .sha1)
        #expect(ChecksumAlgorithm(label: "SHA256") == .sha256)
        #expect(ChecksumAlgorithm(label: "SHA-256") == .sha256)
        #expect(ChecksumAlgorithm(label: "SHA2-256") == .sha256)
        #expect(ChecksumAlgorithm(label: "CRC32") == .crc32)
        #expect(ChecksumAlgorithm(label: "SHA512") == nil)
        #expect(ChecksumAlgorithm(label: "") == nil)
    }

    @Test("SHA-256 is the recommendation and the only non-interop algorithm")
    func recommendation() {
        #expect(ChecksumAlgorithm.recommended == .sha256)
        #expect(!ChecksumAlgorithm.sha256.isInteropOnly)
        #expect(ChecksumAlgorithm.crc32.isInteropOnly)
        #expect(ChecksumAlgorithm.md5.isInteropOnly)
        #expect(ChecksumAlgorithm.sha1.isInteropOnly)
    }

    @Test("file extensions and manifest formats follow the conventions")
    func extensionsAndFormats() {
        #expect(ChecksumAlgorithm.crc32.fileExtension == "sfv")
        #expect(ChecksumAlgorithm.md5.fileExtension == "md5")
        #expect(ChecksumAlgorithm.sha1.fileExtension == "sha1")
        #expect(ChecksumAlgorithm.sha256.fileExtension == "sha256")

        #expect(ChecksumAlgorithm.crc32.manifestFormat == .sfv)
        for algorithm in ChecksumAlgorithm.allCases where algorithm != .crc32 {
            #expect(algorithm.manifestFormat == .gnu)
        }
    }

    /// The raw value is what a persisted preference stores and what three of the four extensions
    /// are derived from, so a rename is a migration. Pinned here so it is a deliberate one.
    @Test("raw values are the stable tokens")
    func rawValues() {
        #expect(ChecksumAlgorithm.allCases.map(\.rawValue) == ["crc32", "md5", "sha1", "sha256"])
    }

    @Test("display names are the technical spellings every other tool prints")
    func displayNames() {
        #expect(ChecksumAlgorithm.allCases.map(\.displayName)
            == ["CRC32", "MD5", "SHA-1", "SHA-256"])
    }

    @Test("byteCount is half the hex width")
    func byteCounts() {
        #expect(ChecksumAlgorithm.allCases.map(\.byteCount) == [4, 16, 20, 32])
    }
}
