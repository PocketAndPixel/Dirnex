import Foundation

/// An XML file read into a tree of its elements, attributes and text, for Quick View's XML preview
/// (2026-09-16).
///
/// It touches bytes, so per PLAN.md §2 it lives here and is tested; the app owns the outline view. Like
/// `JSONDocument`, it is handed `TextPreview`'s text, so an XML file gets the same BOM handling,
/// encoding fallbacks, binary refusal and 4 MB ceiling as every other text file.
///
/// **Not Foundation's parsers, and the reasons were measured before this was written.** `XMLParser`
/// hands a start tag's attributes over as a dictionary, and the same five attributes came back in three
/// different orders on three runs; `XMLDocument` keeps the order, but refuses a file cut at the read
/// limit outright, where `XMLParser` reports what it read before the cut and then an error. A preview
/// shows the file, so the order as written and a file cut at 4 MB are both the point.
///
/// **Nothing is decoded up front.** Each node keeps where it sits in the UTF-8 bytes; a name, a value
/// or a text becomes a `String` when something asks to see it.
///
/// **What a tree lists.** An element lists its attributes first, as `@name` rows, and then its child
/// elements and the text between them. An element holding text and no child element — the common leaf,
/// `<Version>1.2</Version>` — has no text row: its text is its value. Whitespace between elements is
/// the file's indentation and is not a row; comments, processing instructions and the document type
/// declaration are skipped, as the JSON tree skips comments. CDATA is text. The five predefined
/// entities and character references are read; any other entity is shown as written, since reading
/// one would mean reading the DTD. Line breaks are normalized as the specification says every reader
/// must — a carriage return and line feed read as one line feed, and a tab or line break in an
/// attribute's value as a space — which is what the element and attribute values of 3,765 files on
/// this Mac needed to agree with Python's `expat`, value for value.
///
/// **As lenient as the files on this Mac need, and no more.** Several elements at the top are several
/// roots. Anything that is not well formed where it matters for the tree — an end tag that does not
/// match, text outside the root, a tag that does not close — is not XML this reads, and the file is
/// shown as its text: that is also how a `.config` that is an INI file, or an HTML page with an unclosed
/// `<br>`, falls back.
public struct XMLTree: Sendable {
    /// What a node is.
    public enum Kind: UInt8, Sendable {
        case element
        case attribute
        /// Text between elements, CDATA included, in an element that also holds elements.
        case text
    }

    /// Where one node sits in the bytes. 48 bytes a node.
    struct Node: Sendable {
        var kind: Kind
        var flags: UInt8
        /// An element's or attribute's name, as written, prefix included.
        var nameStart: UInt32
        var nameEnd: UInt32
        /// An element's `<`; an attribute value's first byte, after its quote; a text's first byte.
        var start: UInt32
        /// One past an element's last `>` — or, for an element the read limit cut, where the cut is; an
        /// attribute value's closing quote; one past a text's last byte.
        var end: UInt32
        /// One past an element's start tag, and its end tag's `<` (the same offset for `<a/>`).
        var contentStart: UInt32
        var contentEnd: UInt32
        /// Index into `childSlots` of the first row, and how many rows. An element's attributes come
        /// first, then — only when it holds an element — its elements and text.
        var childStart: UInt32
        var childCount: UInt32
        var attributeCount: UInt32
        /// The element this node is in, or `XMLTree.absent` for a root.
        var parent: UInt32

        /// The read limit cut this element before it closed.
        static let incomplete: UInt8 = 1
        /// This element holds an element, so its text is rows rather than its value.
        static let hasElementChildren: UInt8 = 2
        /// An element's content holds a reference, a carriage return, CDATA, a comment or a processing
        /// instruction, so its bytes are not its text.
        static let contentHasMarkup: UInt8 = 4
        /// An attribute's value or a text holds a reference or a character XML normalizes — a carriage
        /// return, or in an attribute a tab or a line break — so its bytes are not its text.
        static let needsDecoding: UInt8 = 8
        /// A text is a CDATA section, whose bytes are its text but for its line breaks.
        static let isCDATA: UInt8 = 16
    }

    /// The `UInt32` standing for "none": no parent.
    static let absent = UInt32.max

    /// The most nodes a tree is built with. Past it the file is shown as text, as a JSON file of more
    /// than a million values is.
    static let nodeLimit = 1_000_000

    let bytes: [UInt8]
    let nodes: [Node]
    /// Every element's rows, as indices into `nodes`, each element's run in order.
    let childSlots: [UInt32]
    /// The elements at the top, in the order the file writes them. One for a well-formed document.
    public let roots: [Int]
    /// Whether the text stops at a read limit rather than at the file's end — so the elements open at
    /// the cut are closed early, and a tag cut part-way is left out.
    public let isTruncated: Bool

    // MARK: - Reading

    /// Read `text` as XML, or `nil` when it is not XML this reads, holds no element, or holds more than
    /// `nodeLimit` nodes.
    ///
    /// - Parameter isTruncated: whether `text` stops at a read limit rather than at the file's end. The
    ///   elements still open there are then closed and marked (`isIncomplete`), and a tag cut part-way
    ///   is left out. In a whole file, either is malformed.
    public static func parse(_ text: String, isTruncated: Bool = false) -> XMLTree? {
        parse(text, isTruncated: isTruncated, nodeLimit: nodeLimit)
    }

    static func parse(_ text: String, isTruncated: Bool, nodeLimit: Int) -> XMLTree? {
        let bytes = Array(text.utf8)
        guard bytes.count < Int(absent) else { return nil }
        let scan = bytes.withUnsafeBufferPointer { buffer in
            XMLScanner.scan(buffer, isTruncated: isTruncated, nodeLimit: nodeLimit)
        }
        guard let scan, !scan.roots.isEmpty else { return nil }
        return XMLTree(
            bytes: bytes,
            nodes: scan.nodes,
            childSlots: scan.childSlots,
            roots: scan.roots,
            isTruncated: isTruncated
        )
    }

    // MARK: - Nodes

    /// How many nodes the tree holds, at every depth.
    public var nodeCount: Int { nodes.count }

    public func kind(of node: Int) -> Kind {
        nodes[node].kind
    }

    /// How many rows a tree lists under `node`: an element's attributes, and its elements and text when
    /// it holds an element. 0 for an attribute or a text.
    public func childCount(of node: Int) -> Int {
        Int(nodes[node].childCount)
    }

    /// The `index`th row under element `node`, in the file's order.
    public func child(_ index: Int, of node: Int) -> Int {
        Int(childSlots[Int(nodes[node].childStart) + index])
    }

    public func children(of node: Int) -> [Int] {
        let entry = nodes[node]
        let start = Int(entry.childStart)
        return childSlots[start..<(start + Int(entry.childCount))].map { Int($0) }
    }

    /// An element's attributes, in the order the file writes them.
    public func attributes(of node: Int) -> [Int] {
        Array(children(of: node).prefix(Int(nodes[node].attributeCount)))
    }

    /// An element's child elements and the text between them — empty for an element holding only text.
    public func content(of node: Int) -> [Int] {
        Array(children(of: node).dropFirst(Int(nodes[node].attributeCount)))
    }

    /// The element `node` is in, or `nil` for a root.
    public func parent(of node: Int) -> Int? {
        let parent = nodes[node].parent
        return parent == Self.absent ? nil : Int(parent)
    }

    /// Whether element `node` holds an element, so that its text is rows rather than its value.
    public func hasElementChildren(_ node: Int) -> Bool {
        nodes[node].flags & Node.hasElementChildren != 0
    }

    /// Whether the read limit cut this element before it closed.
    public func isIncomplete(_ node: Int) -> Bool {
        nodes[node].flags & Node.incomplete != 0
    }

    /// An element's or attribute's name as written, its prefix included. Empty for a text.
    public func name(of node: Int) -> String {
        let entry = nodes[node]
        return JSONDocument.decodeUTF8(bytes[Int(entry.nameStart)..<Int(entry.nameEnd)])
    }

    /// Whether `node`'s name is `name`, compared as bytes.
    func hasName(_ node: Int, _ name: [UInt8]) -> Bool {
        let entry = nodes[node]
        return Int(entry.nameEnd - entry.nameStart) == name.count
            && bytes[Int(entry.nameStart)..<Int(entry.nameEnd)].elementsEqual(name)
    }

    /// `node` as the file writes it: an element's tags and everything between them, an attribute's
    /// value between its quotes, a text's characters.
    public func sourceText(of node: Int) -> String {
        let entry = nodes[node]
        return JSONDocument.decodeUTF8(bytes[Int(entry.start)..<Int(entry.end)])
    }
}
