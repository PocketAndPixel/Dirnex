import Foundation
import Testing

@testable import DirnexCore

@Suite("CRC32")
struct CRC32Tests {
    /// The published check value for CRC-32/ISO-HDLC. If this passes, the polynomial, the
    /// reflection, the initial value and the final XOR are all right at once; if it fails, one of
    /// them is wrong and no other test will say which.
    @Test("the published check vector: \"123456789\" → 0xCBF43926")
    func publishedVector() {
        #expect(CRC32.checksum(of: Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test("the empty input hashes to zero")
    func empty() {
        #expect(CRC32.checksum(of: Data()) == 0)
    }

    /// Cross-checked against `/usr/bin/crc32` on the same bytes, not against this implementation.
    @Test("agrees with the system crc32 tool")
    func agreesWithSystemTool() {
        #expect(CRC32().hexDigest == "00000000")
        var hello = CRC32()
        hello.update(Data("hello checksum world\n".utf8))
        #expect(hello.hexDigest == "4dbf2cc1")
    }

    @Test("chunk boundaries do not change the result")
    func chunkingIsTransparent() {
        let payload = Data("the quick brown fox jumps over the lazy dog".utf8)
        let whole = CRC32.checksum(of: payload)

        var split = CRC32()
        for start in stride(from: 0, to: payload.count, by: 7) {
            split.update(payload[start..<min(start + 7, payload.count)])
        }
        #expect(split.checksum == whole)
    }

    /// The initial value is all-ones precisely so that leading zero bytes are not invisible.
    @Test("leading zero bytes change the checksum")
    func leadingZerosMatter() {
        let one = CRC32.checksum(of: Data([0x00, 0x41]))
        let two = CRC32.checksum(of: Data([0x00, 0x00, 0x41]))
        #expect(one != two)
    }

    @Test("hexDigest is zero-padded to eight digits")
    func hexPadding() {
        var crc = CRC32()
        crc.update(Data([0x00, 0x00, 0x00, 0x00]))
        #expect(crc.hexDigest.count == 8)
        #expect(crc.hexDigest == String(format: "%08x", crc.checksum))
    }

    /// Reading the checksum is not a close: it is a plain XOR of the running state, so a caller
    /// may take an intermediate answer and keep feeding.
    @Test("reading the checksum mid-stream leaves the state intact")
    func checksumIsNonDestructive() {
        var crc = CRC32()
        crc.update(Data("1234".utf8))
        _ = crc.checksum
        crc.update(Data("56789".utf8))
        #expect(crc.checksum == 0xCBF4_3926)
    }
}
