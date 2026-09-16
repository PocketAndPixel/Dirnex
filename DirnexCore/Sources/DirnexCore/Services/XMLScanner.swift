import Foundation

/// The bytes XML's markup gives meaning to. Every one is ASCII, so none can occur inside a UTF-8
/// multi-byte sequence — which is what makes reading UTF-8 XML a byte at a time safe.
enum XMLByte {
    static let tab: UInt8 = 0x09
    static let lineFeed: UInt8 = 0x0A
    static let carriageReturn: UInt8 = 0x0D
    static let space: UInt8 = 0x20
    static let bang: UInt8 = 0x21
    static let quote: UInt8 = 0x22
    static let hash: UInt8 = 0x23
    static let ampersand: UInt8 = 0x26
    static let apostrophe: UInt8 = 0x27
    static let slash: UInt8 = 0x2F
    static let semicolon: UInt8 = 0x3B
    static let lessThan: UInt8 = 0x3C
    static let equals: UInt8 = 0x3D
    static let greaterThan: UInt8 = 0x3E
    static let question: UInt8 = 0x3F
    static let openBracket: UInt8 = 0x5B
    static let closeBracket: UInt8 = 0x5D

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == space || byte == tab || byte == lineFeed || byte == carriageReturn
    }

    /// A byte that ends a name: whitespace, or markup that cannot be part of one.
    static func endsName(_ byte: UInt8) -> Bool {
        isWhitespace(byte) || byte == slash || byte == greaterThan || byte == equals
            || byte == lessThan || byte == quote || byte == apostrophe
    }

    static let commentOpen = Array("<!--".utf8)
    static let commentClose = Array("-->".utf8)
    static let cdataOpen = Array("<![CDATA[".utf8)
    static let cdataClose = Array("]]>".utf8)
    static let instructionClose = Array("?>".utf8)
    static let doctypeOpen = Array("<!DOCTYPE".utf8)
}

/// The pass that reads XML text into `XMLTree`'s nodes (2026-09-16).
///
/// One pass over the bytes, with a stack of its own rather than recursion, for the reason
/// `JSONScanner` has one: how deep the nesting goes is the file's choice.
///
/// A leaf's text is never a node. Text found before an element's first child element is held back
/// (`heldTexts`) until either a child element arrives — the element holds both, and the text becomes
/// rows in the order the file writes them — or the element closes, when it is dropped and the element's
/// content range stands for it. So nodes are still numbered in the order they start.
struct XMLScanner {
    struct Result {
        var nodes: [XMLTree.Node] = []
        var childSlots: [UInt32] = []
        var roots: [Int] = []
    }

    /// Why a scan stopped.
    enum Stop: Error {
        /// The bytes are not XML this reads.
        case malformed
        /// The bytes ended part-way through something: a tag, a comment, a CDATA section.
        case ranOut
        /// There are more nodes than the tree is built with.
        case tooManyNodes
    }

    struct Frame {
        let node: UInt32
        /// Where this element's rows start in `pending`: its attributes, then its content.
        let pendingStart: Int
        let attributeCount: Int
        /// Where this element's held-back text starts in `heldTexts`.
        let heldStart: Int
        var sawElementChild = false
    }

    struct HeldText {
        let start: Int
        let end: Int
        let flags: UInt8
    }

    struct AttributeSpan {
        let nameStart: Int
        let nameEnd: Int
        let valueStart: Int
        let valueEnd: Int
        let needsDecoding: Bool
    }

    let bytes: UnsafeBufferPointer<UInt8>
    let nodeLimit: Int
    /// Where the next token starts. Every token is read ahead of it, and it moves only once the token is
    /// whole, so a scan that runs out leaves it where the token the cut split began.
    var position = 0
    var result = Result()
    var pending: [UInt32] = []
    var heldTexts: [HeldText] = []
    var stack: [Frame] = []

    /// Read `bytes`, or `nil` when they are not XML this reads. Running out part-way is malformed in a
    /// whole file, and in a truncated one closes whatever is still open where the cut token began.
    static func scan(
        _ bytes: UnsafeBufferPointer<UInt8>,
        isTruncated: Bool,
        nodeLimit: Int
    ) -> Result? {
        var scanner = XMLScanner(bytes: bytes, nodeLimit: nodeLimit)
        do throws(Stop) {
            try scanner.run()
            guard scanner.stack.isEmpty || isTruncated else { return nil }
        } catch {
            guard error == .ranOut, isTruncated else { return nil }
        }
        while !scanner.stack.isEmpty {
            scanner.close(contentEnd: scanner.position, end: scanner.position, cut: true)
        }
        return scanner.result
    }

    private init(bytes: UnsafeBufferPointer<UInt8>, nodeLimit: Int) {
        self.bytes = bytes
        self.nodeLimit = nodeLimit
    }

    private mutating func run() throws(Stop) {
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            position = 3
        }
        let count = bytes.count
        while position < count {
            let start = position
            guard bytes[position] == XMLByte.lessThan else {
                try text()
                if stack.isEmpty, !isWhitespace(from: start, to: position) { throw .malformed }
                continue
            }
            guard position + 1 < count else { throw .ranOut }
            switch bytes[position + 1] {
            case XMLByte.question:
                try skip(past: XMLByte.instructionClose, from: position + 2)
                markContentHasMarkup()
            case XMLByte.bang:
                try markupDeclaration()
            case XMLByte.slash:
                try endTag()
            default:
                try startTag()
            }
        }
    }

    // MARK: - Nodes

    /// Add `node`, and list it as a row of the element it is in — every node is one, but a root.
    @discardableResult
    private mutating func appendNode(_ node: XMLTree.Node) throws(Stop) -> UInt32 {
        guard result.nodes.count < nodeLimit else { throw .tooManyNodes }
        let index = UInt32(result.nodes.count)
        result.nodes.append(node)
        if node.kind == .attribute || !stack.isEmpty {
            pending.append(index)
        }
        return index
    }

    private mutating func appendNode(attribute: AttributeSpan, parent: UInt32) throws(Stop) {
        try appendNode(XMLTree.Node(
            kind: .attribute,
            flags: attribute.needsDecoding ? XMLTree.Node.needsDecoding : 0,
            nameStart: UInt32(attribute.nameStart),
            nameEnd: UInt32(attribute.nameEnd),
            start: UInt32(attribute.valueStart),
            end: UInt32(attribute.valueEnd),
            contentStart: 0,
            contentEnd: 0,
            childStart: 0,
            childCount: 0,
            attributeCount: 0,
            parent: parent
        ))
    }

    private mutating func appendNode(text start: Int, end: Int, flags: UInt8) throws(Stop) {
        try appendNode(XMLTree.Node(
            kind: .text,
            flags: flags,
            nameStart: UInt32(start),
            nameEnd: UInt32(start),
            start: UInt32(start),
            end: UInt32(end),
            contentStart: 0,
            contentEnd: 0,
            childStart: 0,
            childCount: 0,
            attributeCount: 0,
            parent: stack.last?.node ?? XMLTree.absent
        ))
    }
}

// MARK: - Content and tags

extension XMLScanner {
    // MARK: Content

    /// Read the text from `position` to the next `<` or the end.
    private mutating func text() throws(Stop) {
        let start = position
        var needsDecoding = false
        while position < bytes.count, bytes[position] != XMLByte.lessThan {
            let byte = bytes[position]
            if byte == XMLByte.ampersand || byte == XMLByte.carriageReturn { needsDecoding = true }
            position += 1
        }
        guard !stack.isEmpty, !isWhitespace(from: start, to: position) else { return }
        if needsDecoding { markContentHasMarkup() }
        try addText(
            start: start,
            end: position,
            flags: needsDecoding ? XMLTree.Node.needsDecoding : 0
        )
    }

    /// A comment, a CDATA section or the document type declaration.
    private mutating func markupDeclaration() throws(Stop) {
        if try starts(with: XMLByte.commentOpen) {
            try skip(past: XMLByte.commentClose, from: position + XMLByte.commentOpen.count)
            markContentHasMarkup()
        } else if try starts(with: XMLByte.cdataOpen) {
            guard !stack.isEmpty else { throw .malformed }
            let start = position + XMLByte.cdataOpen.count
            try skip(past: XMLByte.cdataClose, from: start)
            markContentHasMarkup()
            let end = position - XMLByte.cdataClose.count
            let hasReturn = bytes[start..<end].contains(XMLByte.carriageReturn)
            try addText(
                start: start,
                end: end,
                flags: XMLTree.Node.isCDATA | (hasReturn ? XMLTree.Node.needsDecoding : 0)
            )
        } else if try starts(with: XMLByte.doctypeOpen) {
            guard stack.isEmpty else { throw .malformed }
            try skipDocumentType()
        } else {
            throw .malformed
        }
    }

    private mutating func addText(start: Int, end: Int, flags: UInt8) throws(Stop) {
        guard let top = stack.indices.last else { return }
        if stack[top].sawElementChild {
            try appendNode(text: start, end: end, flags: flags)
        } else {
            heldTexts.append(HeldText(start: start, end: end, flags: flags))
        }
    }

    // MARK: Tags

    private mutating func startTag() throws(Stop) {
        let count = bytes.count
        let nameStart = position + 1
        var index = nameStart
        while index < count, !XMLByte.endsName(bytes[index]) {
            index += 1
        }
        guard index < count else { throw .ranOut }
        guard index > nameStart else { throw .malformed }
        let nameEnd = index
        var attributes: [AttributeSpan] = []
        var selfClosing = false
        while true {
            index = skipWhitespace(from: index)
            guard index < count else { throw .ranOut }
            let byte = bytes[index]
            if byte == XMLByte.greaterThan {
                index += 1
                break
            }
            if byte == XMLByte.slash {
                guard index + 1 < count else { throw .ranOut }
                guard bytes[index + 1] == XMLByte.greaterThan else { throw .malformed }
                selfClosing = true
                index += 2
                break
            }
            let attribute = try attributeSpan(from: index)
            attributes.append(attribute)
            index = attribute.valueEnd + 1
        }

        let element = try openElement(nameStart: nameStart, nameEnd: nameEnd, contentStart: index)
        // Added before the element's frame is pushed, so they land at the end of `pending`, where the
        // frame then starts the element's run.
        for attribute in attributes {
            try appendNode(attribute: attribute, parent: element)
        }
        stack.append(Frame(
            node: element,
            pendingStart: pending.count - attributes.count,
            attributeCount: attributes.count,
            heldStart: heldTexts.count
        ))
        position = index
        if selfClosing {
            close(contentEnd: index, end: index, cut: false)
        }
    }

    private mutating func endTag() throws(Stop) {
        let count = bytes.count
        let nameStart = position + 2
        var index = nameStart
        while index < count, !XMLByte.isWhitespace(bytes[index]), bytes[index] != XMLByte.greaterThan {
            index += 1
        }
        let nameEnd = index
        index = skipWhitespace(from: index)
        guard index < count else { throw .ranOut }
        guard bytes[index] == XMLByte.greaterThan, let top = stack.last else { throw .malformed }
        let open = result.nodes[Int(top.node)]
        let openName = bytes[Int(open.nameStart)..<Int(open.nameEnd)]
        guard openName.elementsEqual(bytes[nameStart..<nameEnd]) else { throw .malformed }
        close(contentEnd: position, end: index + 1, cut: false)
        position = index + 1
    }

    /// Add an element node, first turning its parent's held-back text into rows: a parent holding an
    /// element lists its text.
    private mutating func openElement(nameStart: Int, nameEnd: Int, contentStart: Int) throws(Stop) -> UInt32 {
        if let top = stack.indices.last, !stack[top].sawElementChild {
            stack[top].sawElementChild = true
            for held in heldTexts[stack[top].heldStart...] {
                try appendNode(text: held.start, end: held.end, flags: held.flags)
            }
            heldTexts.removeSubrange(stack[top].heldStart...)
        }
        let index = try appendNode(XMLTree.Node(
            kind: .element,
            flags: 0,
            nameStart: UInt32(nameStart),
            nameEnd: UInt32(nameEnd),
            start: UInt32(position),
            end: 0,
            contentStart: UInt32(contentStart),
            contentEnd: 0,
            childStart: 0,
            childCount: 0,
            attributeCount: 0,
            parent: stack.last?.node ?? XMLTree.absent
        ))
        if stack.isEmpty {
            result.roots.append(Int(index))
        }
        return index
    }

    /// Close the innermost open element: its content ends at `contentEnd` and the element at `end`.
    mutating func close(contentEnd: Int, end: Int, cut: Bool) {
        let frame = stack.removeLast()
        let index = Int(frame.node)
        result.nodes[index].contentEnd = UInt32(contentEnd)
        result.nodes[index].end = UInt32(end)
        result.nodes[index].attributeCount = UInt32(frame.attributeCount)
        if cut {
            result.nodes[index].flags |= XMLTree.Node.incomplete
        }
        if frame.sawElementChild {
            result.nodes[index].flags |= XMLTree.Node.hasElementChildren
        }
        result.nodes[index].childStart = UInt32(result.childSlots.count)
        result.nodes[index].childCount = UInt32(pending.count - frame.pendingStart)
        result.childSlots.append(contentsOf: pending[frame.pendingStart...])
        pending.removeSubrange(frame.pendingStart...)
        heldTexts.removeSubrange(frame.heldStart...)
    }
}

// MARK: - Skipping

extension XMLScanner {
    /// Whether the bytes at `position` start with `marker`, or `ranOut` when they end part-way through
    /// something that could still be it.
    private func starts(with marker: [UInt8]) throws(Stop) -> Bool {
        for (offset, expected) in marker.enumerated() {
            guard position + offset < bytes.count else { throw .ranOut }
            guard bytes[position + offset] == expected else { return false }
        }
        return true
    }

    /// Move `position` past the next `marker` at or after `start`.
    private mutating func skip(past marker: [UInt8], from start: Int) throws(Stop) {
        let count = bytes.count
        var index = start
        while index + marker.count <= count {
            if bytes[index] == marker[0],
               marker.indices.allSatisfy({ bytes[index + $0] == marker[$0] }) {
                position = index + marker.count
                return
            }
            index += 1
        }
        throw .ranOut
    }

    /// Skip `<!DOCTYPE …>`, its internal subset in brackets included, reading quotes so that a `>` or a
    /// `]` inside a quoted string does not end it.
    private mutating func skipDocumentType() throws(Stop) {
        let count = bytes.count
        var index = position + XMLByte.doctypeOpen.count
        var depth = 0
        var quote: UInt8?
        while index < count {
            let byte = bytes[index]
            if let open = quote {
                if byte == open { quote = nil }
            } else if byte == XMLByte.quote || byte == XMLByte.apostrophe {
                quote = byte
            } else if byte == XMLByte.openBracket {
                depth += 1
            } else if byte == XMLByte.closeBracket {
                depth -= 1
            } else if byte == XMLByte.greaterThan, depth <= 0 {
                position = index + 1
                return
            }
            index += 1
        }
        throw .ranOut
    }

    private func skipWhitespace(from start: Int) -> Int {
        var index = start
        while index < bytes.count, XMLByte.isWhitespace(bytes[index]) {
            index += 1
        }
        return index
    }

    private func isWhitespace(from start: Int, to end: Int) -> Bool {
        (start..<end).allSatisfy { XMLByte.isWhitespace(bytes[$0]) }
    }

    /// Note on the open element that its content is not its text byte for byte.
    private mutating func markContentHasMarkup() {
        guard let top = stack.last else { return }
        result.nodes[Int(top.node)].flags |= XMLTree.Node.contentHasMarkup
    }

    /// `name="value"` or `name='value'`, starting at `start`.
    private func attributeSpan(from start: Int) throws(Stop) -> AttributeSpan {
        let count = bytes.count
        var index = start
        while index < count, !XMLByte.endsName(bytes[index]) {
            index += 1
        }
        guard index < count else { throw .ranOut }
        guard index > start else { throw .malformed }
        let nameEnd = index
        index = skipWhitespace(from: index)
        guard index < count else { throw .ranOut }
        guard bytes[index] == XMLByte.equals else { throw .malformed }
        index = skipWhitespace(from: index + 1)
        guard index < count else { throw .ranOut }
        let quote = bytes[index]
        guard quote == XMLByte.quote || quote == XMLByte.apostrophe else { throw .malformed }
        let valueStart = index + 1
        index = valueStart
        var needsDecoding = false
        while index < count, bytes[index] != quote {
            let byte = bytes[index]
            if byte == XMLByte.ampersand || (byte != XMLByte.space && XMLByte.isWhitespace(byte)) {
                needsDecoding = true
            }
            index += 1
        }
        guard index < count else { throw .ranOut }
        return AttributeSpan(
            nameStart: start,
            nameEnd: nameEnd,
            valueStart: valueStart,
            valueEnd: index,
            needsDecoding: needsDecoding
        )
    }
}
