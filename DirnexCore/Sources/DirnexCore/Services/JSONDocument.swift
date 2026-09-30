import Foundation

/// A JSON file read into a tree of values, for Quick View's JSON preview (2026-09-15).
///
/// It touches bytes, so per PLAN.md §2 it lives here and is tested; the app owns the outline view.
/// Like `DelimitedTable`, it is handed `TextPreview`'s text, so a JSON file gets the same BOM
/// handling, encoding fallbacks, binary refusal and 4 MB ceiling as every other text file.
///
/// **Not `JSONSerialization`, and the reasons were measured before this was written.** Foundation's
/// parser hands back an `NSDictionary`, which returned `{"zeta", "alpha", "mid"}` as `alpha, mid,
/// zeta`; it keeps one of the two values under a repeated key; it reads `1.10` as `1.1`; and a file
/// cut at the read limit does not parse at all (the 4 MB prefix of a 13 MB file on this Mac). A
/// preview shows the file, so the order, the repeats and the digits as written are the point.
///
/// **Nothing is decoded up front.** Each value keeps where it sits in the UTF-8 bytes (`Node`); a key
/// or a string becomes a `String` when something asks to see it.
///
/// **As lenient as the files on this Mac need.** Of the 1 487 JSON files in the home folder, 29 of
/// the 34 a strict parser refused were `tsconfig.json`-style JSONC, so `//` and `/* */` comments and a
/// comma before a closing bracket are read. `NaN` and `Infinity`, which Python's `json` writes, read
/// as numbers. Several values in a row — JSON Lines, or JSON written one value after another — are
/// several roots. Single quotes, unquoted keys and the rest of JSON5 are not read, and such a file is
/// shown as its text.
public struct JSONDocument: Sendable {
    /// What a value is.
    public enum Kind: UInt8, Sendable {
        case object
        case array
        case string
        /// A number as JSON writes it, or `NaN` or `Infinity`.
        case number
        case boolean
        case null

        /// Whether a value of this kind holds other values.
        public var isContainer: Bool { self == .object || self == .array }
    }

    /// Where one value sits in the bytes, and where its children are listed. 28 bytes a value.
    struct Node: Sendable {
        var kind: Kind
        var flags: UInt8
        /// Offset of the key's opening quote, or `JSONDocument.absent` for an array element or a root.
        var keyStart: UInt32
        /// Offset of the value's first byte: its opening quote or bracket, or its first character.
        var valueStart: UInt32
        /// One past the value's last byte: its closing quote or bracket — or, for a container the read
        /// limit cut before it closed, the end of the bytes.
        var valueEnd: UInt32
        /// Index into `childSlots` of the first child. A container's children are contiguous there.
        var childStart: UInt32
        var childCount: UInt32
        /// The container this value is in, or `JSONDocument.absent` for a root.
        var parent: UInt32

        /// The key has a backslash escape, so its bytes are not its text.
        static let keyHasEscapes: UInt8 = 1
        /// The string value has a backslash escape, so its bytes are not its text.
        static let valueHasEscapes: UInt8 = 2
        /// The read limit cut this container before it closed.
        static let incomplete: UInt8 = 4
    }

    /// The `UInt32` standing for "none": no key, no parent.
    static let absent = UInt32.max

    /// The most values a document is built with. Past it the file is shown as text: each value costs
    /// 32 bytes here, and a file of more than a million is one nobody reads by expanding rows.
    static let valueLimit = 1_000_000

    let bytes: [UInt8]
    let nodes: [Node]
    /// Every container's children, as indices into `nodes`, each container's run in order.
    let childSlots: [UInt32]
    /// The top-level values, in the order the file writes them. One for an ordinary JSON file, one a
    /// line for JSON Lines.
    public let roots: [Int]
    /// Whether the text stops at a read limit rather than at the file's end — so the containers open
    /// at the cut are closed early, and a value cut part-way is left out.
    public let isTruncated: Bool

    // MARK: - Reading

    /// Read `text` as JSON, or `nil` when it is not JSON this reads — or holds no value at all, or more
    /// than `valueLimit` of them.
    ///
    /// - Parameter isTruncated: whether `text` stops at a read limit rather than at the file's end.
    ///   The containers still open there are then closed and marked (`isIncomplete`), and a value cut
    ///   part-way — a string with no closing quote, a number that may have had more digits — is left
    ///   out. In a whole file, either is malformed.
    public static func parse(_ text: String, isTruncated: Bool = false) -> JSONDocument? {
        parse(text, isTruncated: isTruncated, valueLimit: valueLimit)
    }

    static func parse(_ text: String, isTruncated: Bool, valueLimit: Int) -> JSONDocument? {
        let bytes = Array(text.utf8)
        guard bytes.count < Int(absent) else { return nil }
        let scan = bytes.withUnsafeBufferPointer { buffer in
            JSONScanner.scan(buffer, isTruncated: isTruncated, valueLimit: valueLimit)
        }
        guard let scan, !scan.roots.isEmpty else { return nil }
        return JSONDocument(
            bytes: bytes,
            nodes: scan.nodes,
            childSlots: scan.childSlots,
            roots: scan.roots,
            isTruncated: isTruncated
        )
    }

    // MARK: - Values

    /// How many values the document holds, at every depth.
    public var valueCount: Int { nodes.count }

    public func kind(of value: Int) -> Kind {
        nodes[value].kind
    }

    public func childCount(of value: Int) -> Int {
        Int(nodes[value].childCount)
    }

    /// Container `value`'s child at `index`, in the file's order.
    public func child(_ index: Int, of value: Int) -> Int {
        Int(childSlots[Int(nodes[value].childStart) + index])
    }

    public func children(of value: Int) -> [Int] {
        let node = nodes[value]
        let start = Int(node.childStart)
        return childSlots[start..<(start + Int(node.childCount))].map { Int($0) }
    }

    /// The container `value` is in, or `nil` for a root.
    public func parent(of value: Int) -> Int? {
        let parent = nodes[value].parent
        return parent == Self.absent ? nil : Int(parent)
    }

    /// Where `value` sits among its container's values, or among the roots, counting from 0.
    ///
    /// Searched rather than stored: values are numbered in the order they start, so every container's
    /// children, and the roots, are listed in increasing order.
    public func position(of value: Int) -> Int {
        guard let parent = parent(of: value) else {
            return Self.binarySearch(for: value, in: roots[...])
        }
        let node = nodes[parent]
        let start = Int(node.childStart)
        let slots = childSlots[start..<(start + Int(node.childCount))]
        return Self.binarySearch(for: UInt32(value), in: slots) - start
    }

    /// Whether the read limit cut this container before it closed.
    public func isIncomplete(_ value: Int) -> Bool {
        nodes[value].flags & Node.incomplete != 0
    }

    /// The key `value` is stored under, its escapes read — or `nil` for an array element or a root.
    public func key(of value: Int) -> String? {
        let node = nodes[value]
        guard node.keyStart != Self.absent else { return nil }
        let start = Int(node.keyStart)
        return decodeString(
            openingQuote: start,
            closingQuote: closingQuote(after: start),
            hasEscapes: node.flags & Node.keyHasEscapes != 0
        )
    }

    /// `value` as the file writes it: quotes, brackets, whitespace and comments included.
    public func sourceText(of value: Int) -> String {
        let node = nodes[value]
        return Self.decodeUTF8(bytes[Int(node.valueStart)..<Int(node.valueEnd)])
    }

    /// The values a tree of this document lists at its top: the root's own values, when there is one
    /// root and it holds some, and otherwise every root — the lines of a JSON Lines file, or the one
    /// string, number or empty container a file holds.
    public var topLevelValues: [Int] {
        if roots.count == 1, let root = roots.first, kind(of: root).isContainer,
           childCount(of: root) > 0 {
            return children(of: root)
        }
        return roots
    }

    // MARK: - Helpers

    /// The non-failing decode, and exact here rather than lossy for anything but a cut a caller made
    /// on purpose: the bytes are a `String`'s own UTF-8, and every cut the scanner makes is at an ASCII
    /// byte, which is never inside a multi-byte sequence.
    static func decodeUTF8(_ bytes: some Collection<UInt8>) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }

    /// The index of `target` in `sorted`, which holds it.
    private static func binarySearch<Slots: RandomAccessCollection>(
        for target: Slots.Element,
        in sorted: Slots
    ) -> Slots.Index where Slots.Element: Comparable {
        var low = sorted.startIndex
        var high = sorted.endIndex
        while low < high {
            let middle = sorted.index(low, offsetBy: sorted.distance(from: low, to: high) / 2)
            if sorted[middle] < target {
                low = sorted.index(after: middle)
            } else {
                high = middle
            }
        }
        return low
    }
}
