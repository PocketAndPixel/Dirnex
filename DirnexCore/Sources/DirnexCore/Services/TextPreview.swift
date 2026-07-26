import Foundation

/// A text file's contents, ready for a preview surface to render (PLAN.md §M11).
///
/// It touches bytes, so per §2 it lives here and is tested. The app owns only the decision to
/// *route* a file here — which is a UTType question, and therefore a UI one — and the `NSTextView`
/// that draws the result.
///
/// The point of decoding here rather than letting Quick Look render the file is that a text view
/// Dirnex owns is **in-process**, so the user can select and copy from it. `QLPreviewView` renders
/// out of process and declines the mouse, and a preview that hands it clicks lets them fall through
/// to the file table underneath (see docs/NOTES.md) — so selectable text needs our own view, which
/// needs our own decode.
public struct TextPreview: Sendable, Equatable {
    /// The decoded text, ready to be shown verbatim.
    public let text: String
    /// Whether `text` stops short of the file's end because the file is bigger than `byteLimit`.
    /// The caller says so on screen — a preview that silently ends early is a preview that lies.
    public let isTruncated: Bool

    public init(text: String, isTruncated: Bool) {
        self.text = text
        self.isTruncated = isTruncated
    }

    /// How much of a file is read. Rendering costs nothing beyond this — TextKit 2 lays out lazily,
    /// measured at ~10 ms to show a 64 MiB document and ~5 ms to jump to its end — so the limit is
    /// about the *read*: the preview re-runs on every cursor step, and a folder of 500 MB logs
    /// should not turn ↓ into a disk-thrashing exercise.
    public static let byteLimit = 4 * 1024 * 1024

    /// Read up to `byteLimit` bytes of a local file and decode them.
    ///
    /// `nil` for anything that isn't text after all — an unreadable file, or bytes no encoding
    /// claims (a binary mislabelled `.txt`). The caller falls back to Quick Look, which is exactly
    /// what such a file got before.
    ///
    /// The read is synchronous and blocking; call it off the main thread.
    public static func read(contentsOf url: URL, byteLimit: Int = byteLimit) -> TextPreview? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // One byte past the limit, so a file that lands exactly on it is not reported as truncated.
        guard let data = try? handle.read(upToCount: byteLimit + 1) else { return nil }
        let isTruncated = data.count > byteLimit
        return decode(isTruncated ? data.prefix(byteLimit) : data, isTruncated: isTruncated)
    }

    /// Decode `data` — a whole file, or its first bytes when `isTruncated` — into displayable text.
    ///
    /// The order is what the encodings themselves justify, and every step was measured against real
    /// bytes rather than assumed:
    ///
    /// 1. **A BOM is a statement**, and the only one that settles UTF-16/UTF-32, whose bytes
    ///    otherwise decode "successfully" as UTF-8 (they are full of NULs, which UTF-8 allows) and
    ///    render as text with a gap between every character.
    /// 2. **A NUL byte means binary.** Probed: `Foundation`'s own detector answers *nothing* for
    ///    64 KiB of `/bin/ls`, so without this a binary would fall through to the lossy guesses
    ///    below. BOM-marked UTF-16 is already decoded above, so nothing legitimate is caught here.
    /// 3. **UTF-8**, which is what text on this machine is.
    /// 4. **Foundation's detector** for legacy 8-bit files, i.e. what TextEdit would show. It is
    ///    right about Windows-1251 and Latin-1 and wrong about KOI8-R (it answers "Arabic
    ///    (Windows)"), and there is nothing better available without shipping a charset detector;
    ///    a lossy answer is refused rather than shown as mojibake.
    public static func decode(_ data: Data, isTruncated: Bool) -> TextPreview? {
        if let unicode = decodeByByteOrderMark(data, isTruncated: isTruncated) {
            return TextPreview(text: unicode, isTruncated: isTruncated)
        }
        guard !data.contains(0) else { return nil }
        let body = isTruncated ? trimmingPartialUTF8Sequence(data) : data
        if let utf8 = String(data: body, encoding: .utf8) {
            return TextPreview(text: utf8, isTruncated: isTruncated)
        }
        guard let detected = decodeByDetection(body) else { return nil }
        return TextPreview(text: detected, isTruncated: isTruncated)
    }

    // MARK: - Encodings

    /// One byte-order mark and what it says: which encoding follows, and how wide that encoding's
    /// code unit is (which is what a truncated read has to cut back to).
    private struct ByteOrderMark {
        let bytes: [UInt8]
        let encoding: String.Encoding
        let unit: Int

        /// UTF-32 first: its little-endian mark *starts with* UTF-16 LE's two bytes, so testing
        /// UTF-16 first would claim every UTF-32 LE file and decode it as text separated by NULs.
        static let all = [
            ByteOrderMark(bytes: [0xFF, 0xFE, 0x00, 0x00], encoding: .utf32LittleEndian, unit: 4),
            ByteOrderMark(bytes: [0x00, 0x00, 0xFE, 0xFF], encoding: .utf32BigEndian, unit: 4),
            ByteOrderMark(bytes: [0xFF, 0xFE], encoding: .utf16LittleEndian, unit: 2),
            ByteOrderMark(bytes: [0xFE, 0xFF], encoding: .utf16BigEndian, unit: 2),
            ByteOrderMark(bytes: [0xEF, 0xBB, 0xBF], encoding: .utf8, unit: 1)
        ]
    }

    /// Decode `data` when it opens with a byte-order mark, which names its encoding outright.
    /// `nil` when there is no BOM, or when the bytes it claims don't decode after all.
    private static func decodeByByteOrderMark(_ data: Data, isTruncated: Bool) -> String? {
        guard let mark = ByteOrderMark.all.first(where: { data.starts(with: $0.bytes) }) else {
            return nil
        }
        var body = Data(data.dropFirst(mark.bytes.count))
        // A prefix read can stop mid character, which fails the decode outright — so drop the
        // partial one rather than the file. Fixed-width encodings cut to their unit; UTF-8's
        // variable-width sequences need the walk below.
        if isTruncated {
            body = mark.unit > 1
                ? body.prefix(body.count - body.count % mark.unit)
                : trimmingPartialUTF8Sequence(body)
        }
        return String(data: body, encoding: mark.encoding)
    }

    /// Ask Foundation which encoding these bytes are, and take the answer only if it is confident.
    ///
    /// A *lossy* conversion is refused: probed on MacRoman, the detector answers "Japanese
    /// (Windows, DOS)" and hands back `Caf<?> na夫e` — text on screen that the file does not say,
    /// which is worse than falling back to Quick Look.
    private static func decodeByDetection(_ data: Data) -> String? {
        var converted: NSString?
        var lossy: ObjCBool = false
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: nil,
            convertedString: &converted,
            usedLossyConversion: &lossy
        )
        guard encoding != 0, !lossy.boolValue else { return nil }
        return converted as String?
    }

    /// Drop a multi-byte UTF-8 sequence that a prefix read cut in half.
    ///
    /// Without this the decode of a truncated file fails and falls through to the detector, which
    /// answers UTF-8 *lossily* — i.e. with a `` at the end of the last line. Measured: cutting
    /// Cyrillic UTF-8 mid-character does exactly that.
    private static func trimmingPartialUTF8Sequence(_ data: Data) -> Data {
        // A sequence is at most 4 bytes, so at most 3 trailing continuation bytes can precede the
        // lead byte that started it.
        var trailing = 0
        var index = data.endIndex - 1
        while index >= data.startIndex, trailing < 4 {
            let byte = data[index]
            if byte & 0b1100_0000 == 0b1000_0000 { // 10xxxxxx — a continuation byte
                trailing += 1
                index -= 1
                continue
            }
            let expected = expectedUTF8SequenceLength(leadByte: byte)
            // Complete, or not a lead byte at all (garbage the decoder should judge, not us).
            guard expected > trailing + 1 else { return data }
            return data.prefix(upTo: index)
        }
        return data
    }

    /// How many bytes the sequence starting with `leadByte` occupies; 1 for ASCII and for anything
    /// that is not a lead byte.
    private static func expectedUTF8SequenceLength(leadByte: UInt8) -> Int {
        switch leadByte {
        case 0b1111_0000...0b1111_0111: 4
        case 0b1110_0000...0b1110_1111: 3
        case 0b1100_0000...0b1101_1111: 2
        default: 1
        }
    }
}
