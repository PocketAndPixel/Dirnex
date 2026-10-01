import Foundation

/// Strict base64url (RFC 4648 §5) for license keys (PLAN.md §M29): the 64-character URL alphabet
/// only, no padding, and the unused bits of the last character must be zero, so every byte string
/// has exactly one spelling.
///
/// Strictness is the point. The store's server checks keys too, and the two must agree about which
/// text is a key. Node's own decoder skips characters outside the alphabet and accepts padding, so
/// the signer carries a hand-written decoder with these same rules, and the shared vectors pin both
/// (`padded-base64url`, `standard-base64-alphabet`, `non-canonical-trailing-bits`).
enum Base64URL {
    private static let alphabet = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8
    )

    /// The 6-bit value of each ASCII byte, or `nil` outside the alphabet.
    private static let values: [UInt8?] = {
        var table = [UInt8?](repeating: nil, count: 256)
        for (value, byte) in alphabet.enumerated() {
            table[Int(byte)] = UInt8(value)
        }
        return table
    }()

    static func encode(_ data: some Sequence<UInt8>) -> String {
        var text = String.UnicodeScalarView()
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = buffer << 8 | UInt32(byte)
            bits += 8
            while bits >= 6 {
                bits -= 6
                text.append(Unicode.Scalar(alphabet[Int(buffer >> UInt32(bits) & 63)]))
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        if bits > 0 {
            text.append(Unicode.Scalar(alphabet[Int(buffer << UInt32(6 - bits) & 63)]))
        }
        return String(text)
    }

    /// The bytes `text` spells, or `nil` if it isn't strict base64url.
    static func decode(_ text: some Collection<UInt8>) -> Data? {
        guard text.count % 4 != 1 else { return nil }
        var data = Data(capacity: text.count * 6 / 8)
        var buffer: UInt32 = 0
        var bits = 0
        for byte in text {
            guard let value = values[Int(byte)] else { return nil }
            buffer = buffer << 6 | UInt32(value)
            bits += 6
            if bits >= 8 {
                bits -= 8
                data.append(UInt8(buffer >> UInt32(bits) & 0xFF))
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        return buffer == 0 ? data : nil
    }

    static func decode(_ text: String) -> Data? {
        decode(Array(text.utf8))
    }
}
