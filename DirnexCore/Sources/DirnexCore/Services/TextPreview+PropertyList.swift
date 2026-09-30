import Foundation

/// A binary property list, shown as the XML property list it converts to (docs/HISTORY.md,
/// 2026-09-16).
///
/// `read(contentsOf:)` refuses one, rightly: its bytes are full of NULs. But a binary plist is the
/// common kind — every `.plist` in `~/Library/Preferences`, and a compiled `.strings` table in an app
/// bundle — and its content is text-shaped. Measured over the 4 559 binary plists in
/// `~/Library/Preferences`, `~/Library/Application Support`, `~/Library/Containers` and `~/Dev`: every
/// one converted, the median came out 1.5× its size and the 99th percentile 4.4×, the largest XML was
/// 3.5 MB, and the slowest conversion took 26 ms.
///
/// **What is shown is not the file as written.** `PropertyListSerialization` sorts a dictionary's keys
/// when it writes XML, as `plutil -convert xml1` does and as Quick Look's own preview of the same file
/// does. There is no other converter on a Mac, and the alternative is Quick Look showing that same
/// sorted XML in one color.
public extension TextPreview {
    /// Read a binary property list of up to `byteLimit` bytes and convert it to XML.
    ///
    /// `nil` for anything else — a file that does not open with the binary format's magic, one that
    /// does and fails to parse, or one whose file or whose XML is over `byteLimit` — and the caller
    /// falls back to Quick Look. A binary plist cannot be read in part (its offset table is at the
    /// end), so the limit refuses rather than truncates.
    ///
    /// The read is synchronous and blocking; call it off the main thread.
    static func readBinaryPropertyList(contentsOf url: URL, byteLimit: Int = byteLimit) -> TextPreview? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return readBinaryPropertyList(from: handle, byteLimit: byteLimit)
    }
}

extension TextPreview {
    /// What every binary property list opens with. `bplist00` in practice; only the name is checked,
    /// and `PropertyListSerialization` decides whether it can read the version after it.
    static let binaryPropertyListMagic = Data("bplist".utf8)

    /// The read itself, from an open handle, so a test can see that a file which is not a binary
    /// plist costs its first six bytes and no more.
    static func readBinaryPropertyList(from handle: FileHandle, byteLimit: Int) -> TextPreview? {
        let magic = binaryPropertyListMagic
        do {
            guard let head = try handle.read(upToCount: magic.count), head == magic else { return nil }
            // One byte past the limit, so a file that lands exactly on it is not refused.
            let remaining = byteLimit + 1 - head.count
            let rest = remaining > 0 ? try handle.read(upToCount: remaining) ?? Data() : Data()
            let data = head + rest
            guard data.count <= byteLimit else { return nil }
            var format = PropertyListSerialization.PropertyListFormat.binary
            let object = try PropertyListSerialization.propertyList(from: data, format: &format)
            // The magic alone does not settle it: `bplist00 = x;` is an old-style plist, a dictionary.
            guard format == .binary else { return nil }
            let xml = try PropertyListSerialization.data(
                fromPropertyList: object,
                format: .xml,
                options: 0
            )
            guard xml.count <= byteLimit, let text = String(data: xml, encoding: .utf8) else { return nil }
            return TextPreview(text: text, isTruncated: false)
        } catch {
            return nil
        }
    }
}
