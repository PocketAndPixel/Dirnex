import Foundation

/// CRC-32/ISO-HDLC — the checksum `.sfv` files carry, and the one `zip`, `gzip` and Total
/// Commander's `.crc` companions all speak.
///
/// Table-driven and incremental, so it feeds ``ChecksumAccumulator`` chunk by chunk beside the
/// CryptoKit hashes and never needs a whole file in memory. Written out rather than taken from
/// zlib: linking a compression library for one 30-line function is a dependency Dirnex would carry
/// forever, and the byte-at-a-time table measured 534 MiB/s in the M14 probe — slower than SHA-256
/// but far faster than any disk this runs against. If that ever becomes the bottleneck, slice-by-8
/// or the ARMv8 `CRC32*` instructions are the escalation; simple wins until it is measured.
///
/// Parameters, spelled out because a CRC is nothing without them: width 32, polynomial `0x04C11DB7`
/// reflected to `0xEDB88320`, input and output reflected, initial value `0xFFFFFFFF`, final XOR
/// `0xFFFFFFFF`. The published check vector — `"123456789"` → `0xCBF43926` — is the first test.
public struct CRC32: Sendable, Equatable {
    /// The running remainder, pre-final-XOR. Starts at all-ones so leading zero bytes still change
    /// the result.
    private var state: UInt32 = 0xFFFF_FFFF

    public init() {}

    /// Fold a chunk of bytes into the running checksum. Chunk boundaries do not affect the result.
    public mutating func update(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            var crc = state
            for byte in raw {
                crc = (crc >> 8) ^ Self.table[Int((crc ^ UInt32(byte)) & 0xFF)]
            }
            state = crc
        }
    }

    /// The checksum of everything fed in so far. Non-mutating: unlike a cryptographic sponge there
    /// is no state to absorb, so reading it mid-stream and continuing to ``update(_:)`` is legal.
    public var checksum: UInt32 { state ^ 0xFFFF_FFFF }

    /// The checksum as 8 lowercase hex digits, zero-padded — the form every `.sfv` file uses.
    public var hexDigest: String { String(format: "%08x", checksum) }

    /// One-shot convenience for a value already in memory.
    public static func checksum(of data: Data) -> UInt32 {
        var crc = CRC32()
        crc.update(data)
        return crc.checksum
    }

    /// The 256-entry remainder table for the reflected polynomial, built once on first use.
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var remainder = UInt32(index)
            for _ in 0..<8 {
                remainder = (remainder & 1) == 1
                    ? (remainder >> 1) ^ 0xEDB8_8320
                    : remainder >> 1
            }
            return remainder
        }
    }()
}
