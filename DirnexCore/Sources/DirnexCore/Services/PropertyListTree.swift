import Foundation

/// A property list read as its keys and values rather than as the XML it is written in, for Quick
/// View's tree (2026-09-16).
///
/// The user's choice of three, after a survey found property lists the most common XML on this Mac
/// (1,393 XML and 938 binary). As generic XML a `<key>` and its value are two sibling rows; read as a
/// property list they are one row, the way the JSON tree reads an object: a dictionary's key and its
/// value, an array's elements by index, and each scalar typed. A binary property list arrives here as
/// the XML `TextPreview.readBinaryPropertyList` converts it to.
///
/// Built over an `XMLTree`, whose nodes it points into, so reading a key or a string is the XML tree's
/// own decode and a container's source is the XML tree's own. Its values are numbered in the order they
/// start, as every tree's are. The order the file writes keys in is kept, which is the point of reading
/// it here rather than through `PropertyListSerialization`, whose dictionaries do not keep it.
public struct PropertyListTree: Sendable {
    /// What a value is: the property-list types.
    public enum Kind: UInt8, Sendable {
        case dictionary
        case array
        case string
        case integer
        case real
        case boolean
        case date
        case data

        public var isContainer: Bool { self == .dictionary || self == .array }
    }

    struct Node: Sendable {
        let kind: Kind
        /// The XML element the value is written as.
        let element: UInt32
        /// The `<key>` element a dictionary's value is stored under, or `XMLTree.absent`.
        let key: UInt32
        let parent: UInt32
        var childStart: UInt32
        var childCount: UInt32
    }

    let xml: XMLTree
    let nodes: [Node]
    let childSlots: [UInt32]
    /// The one value the `<plist>` element holds.
    let root: Int

    /// `xml` read as a property list: a `<plist>` root holding one value, dictionaries of `<key>` and
    /// value pairs, and the six scalar types. `nil` for anything else, which the caller shows as generic
    /// XML — including an element these types do not name, a dictionary whose keys and values do not
    /// pair, and a scalar holding an element. A dictionary the read limit cut part-way through a pair
    /// drops the key its value did not reach.
    public init?(_ xml: XMLTree) {
        guard xml.roots.count == 1, let plist = xml.roots.first, xml.hasName(plist, Self.plistName),
              xml.hasElementChildren(plist)
        else { return nil }
        let values = xml.content(of: plist)
        guard values.count == 1, let first = values.first, xml.kind(of: first) == .element else {
            return nil
        }
        var builder = PropertyListBuilder(xml: xml)
        guard builder.build(root: first) else { return nil }
        self.xml = xml
        nodes = builder.nodes
        childSlots = builder.childSlots
        root = 0
    }

    // MARK: - Values

    public var isTruncated: Bool { xml.isTruncated }

    public func kind(of value: Int) -> Kind {
        nodes[value].kind
    }

    public func parent(of value: Int) -> Int? {
        let parent = nodes[value].parent
        return parent == XMLTree.absent ? nil : Int(parent)
    }

    public func childCount(of value: Int) -> Int {
        Int(nodes[value].childCount)
    }

    public func child(_ index: Int, of value: Int) -> Int {
        Int(childSlots[Int(nodes[value].childStart) + index])
    }

    /// The key a dictionary's value is stored under, or `nil` for an array element or the root.
    public func key(of value: Int) -> String? {
        let key = nodes[value].key
        return key == XMLTree.absent ? nil : xml.text(of: Int(key))
    }

    /// Where `value` sits among its container's values, counting from 0.
    public func position(of value: Int) -> Int {
        guard let parent = parent(of: value) else { return 0 }
        let start = Int(nodes[parent].childStart)
        var low = start
        var high = start + Int(nodes[parent].childCount)
        while low < high {
            let middle = (low + high) / 2
            if Int(childSlots[middle]) < value { low = middle + 1 } else { high = middle }
        }
        return low - start
    }

    /// What a scalar says: a string's text, a number or date as written, `true` or `false`, and data as
    /// hexadecimal bytes in groups of four, `<48656c6c 6f>`, as `NSData` describes itself. Empty for a
    /// container.
    public func scalarText(of value: Int, byteLimit: Int = .max) -> String {
        let element = Int(nodes[value].element)
        switch kind(of: value) {
        case .dictionary, .array:
            return ""
        case .string:
            return xml.text(of: element, byteLimit: byteLimit)
        case .integer, .real, .date:
            return xml.trimmedText(of: element, byteLimit: byteLimit)
        case .boolean:
            return xml.hasName(element, Self.trueName) ? "true" : "false"
        case .data:
            return hexText(of: element, byteLimit: byteLimit)
        }
    }

    private func hexText(of element: Int, byteLimit: Int) -> String {
        let base64 = xml.text(of: element)
        let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data()
        var text = "<"
        for (index, byte) in data.enumerated() {
            // Two hex digits a byte and a space every fourth, so this many bytes fill the limit.
            guard text.utf8.count < byteLimit else {
                return text + "…"
            }
            if index > 0, index % 4 == 0 { text += " " }
            text += String(format: "%02x", byte)
        }
        return text + ">"
    }

    static let plistName = Array("plist".utf8)
    static let trueName = Array("true".utf8)
}

/// The walk that numbers the values in document order, with a stack of its own.
private struct PropertyListBuilder {
    let xml: XMLTree
    var nodes: [PropertyListTree.Node] = []
    var childSlots: [UInt32] = []

    init(xml: XMLTree) {
        self.xml = xml
    }

    private struct Frame {
        let node: Int
        let elements: [Int]
        let isDictionary: Bool
        var next = 0
        var slot: Int
    }

    mutating func build(root: Int) -> Bool {
        guard let rootNode = add(element: root, key: XMLTree.absent, parent: XMLTree.absent) else {
            return false
        }
        var stack: [Frame] = []
        if nodes[rootNode].kind.isContainer {
            guard let frame = frame(for: rootNode) else { return false }
            stack.append(frame)
        }
        while let top = stack.indices.last {
            let frame = stack[top]
            guard frame.next < frame.elements.count else {
                stack.removeLast()
                continue
            }
            var key = XMLTree.absent
            var valueIndex = frame.next
            if frame.isDictionary {
                let keyElement = frame.elements[frame.next]
                guard xml.hasName(keyElement, Self.keyName), !xml.hasElementChildren(keyElement)
                else { return false }
                key = UInt32(keyElement)
                valueIndex += 1
            }
            stack[top].next = valueIndex + 1
            let element = frame.elements[valueIndex]
            guard let added = add(element: element, key: key, parent: UInt32(frame.node)) else {
                return false
            }
            childSlots[stack[top].slot] = UInt32(added)
            stack[top].slot += 1
            if nodes[added].kind.isContainer {
                guard let child = self.frame(for: added) else { return false }
                stack.append(child)
            }
        }
        return true
    }

    /// A container's frame, its child slots reserved; `nil` for a malformed container.
    private mutating func frame(for node: Int) -> Frame? {
        let kind = nodes[node].kind
        guard kind.isContainer else { return nil }
        let element = Int(nodes[node].element)
        var elements = xml.content(of: element)
        guard elements.allSatisfy({ xml.kind(of: $0) == .element }) else { return nil }
        if kind == .dictionary, elements.count % 2 == 1 {
            // Only a cut can leave a key without its value.
            guard xml.isIncomplete(element) else { return nil }
            elements.removeLast()
        }
        let count = kind == .dictionary ? elements.count / 2 : elements.count
        nodes[node].childStart = UInt32(childSlots.count)
        nodes[node].childCount = UInt32(count)
        let slot = childSlots.count
        childSlots.append(contentsOf: repeatElement(0, count: count))
        return Frame(node: node, elements: elements, isDictionary: kind == .dictionary, slot: slot)
    }

    private mutating func add(element: Int, key: UInt32, parent: UInt32) -> Int? {
        guard xml.kind(of: element) == .element,
              let kind = Self.kinds.first(where: { xml.hasName(element, $0.name) })?.kind
        else { return nil }
        if !kind.isContainer, xml.hasElementChildren(element) { return nil }
        nodes.append(PropertyListTree.Node(
            kind: kind,
            element: UInt32(element),
            key: key,
            parent: parent,
            childStart: 0,
            childCount: 0
        ))
        return nodes.count - 1
    }

    static let keyName = Array("key".utf8)
    static let kinds: [(name: [UInt8], kind: PropertyListTree.Kind)] = [
        (Array("dict".utf8), .dictionary), (Array("array".utf8), .array),
        (Array("string".utf8), .string), (Array("integer".utf8), .integer),
        (Array("real".utf8), .real), (Array("true".utf8), .boolean),
        (Array("false".utf8), .boolean), (Array("date".utf8), .date),
        (Array("data".utf8), .data)
    ]
}
