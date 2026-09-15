import Foundation

/// The bytes JSON's grammar gives meaning to. Every one is ASCII, so none can occur inside a UTF-8
/// multi-byte sequence — which is what makes reading UTF-8 JSON a byte at a time safe.
enum JSONByte {
    static let tab: UInt8 = 0x09
    static let lineFeed: UInt8 = 0x0A
    static let carriageReturn: UInt8 = 0x0D
    static let space: UInt8 = 0x20
    static let quote: UInt8 = 0x22
    static let star: UInt8 = 0x2A
    static let plus: UInt8 = 0x2B
    static let comma: UInt8 = 0x2C
    static let minus: UInt8 = 0x2D
    static let dot: UInt8 = 0x2E
    static let slash: UInt8 = 0x2F
    static let zero: UInt8 = 0x30
    static let colon: UInt8 = 0x3A
    static let openBracket: UInt8 = 0x5B
    static let backslash: UInt8 = 0x5C
    static let closeBracket: UInt8 = 0x5D
    static let openBrace: UInt8 = 0x7B
    static let closeBrace: UInt8 = 0x7D

    static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    /// A hex digit's value, or `nil` for any other byte.
    static func hexValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case 0x30...0x39: UInt32(byte - 0x30)
        case 0x41...0x46: UInt32(byte - 0x41 + 10)
        case 0x61...0x66: UInt32(byte - 0x61 + 10)
        default: nil
        }
    }
}

/// The pass that reads JSON text into `JSONDocument`'s values (2026-09-15).
///
/// One pass over the bytes, with a stack of its own rather than recursion: how deep the nesting goes
/// is the file's choice, and a hundred thousand `[` in a row must not run the thread out of stack.
///
/// What it reads beyond RFC 8259, and why, is `JSONDocument`'s doc comment. What it refuses is
/// everything else, since a file that is not JSON after all is more honestly shown as its text.
struct JSONScanner {
    struct Result {
        var nodes: [JSONDocument.Node] = []
        var childSlots: [UInt32] = []
        var roots: [Int] = []
    }

    /// Why a scan stopped.
    enum Stop: Error {
        /// The bytes are not JSON this reads.
        case malformed
        /// The bytes ended part-way through something: a string, a number, a member, a comment.
        case ranOut
        /// There are more values than the document is built with.
        case tooManyValues
    }

    struct Frame {
        let node: UInt32
        let pendingStart: Int
        var expecting: Expecting
    }

    enum Expecting {
        /// After `{` or a comma: a key, or `}` — which after a comma is JSONC's trailing comma.
        case key
        /// After a member: a comma, or `}`.
        case memberEnd
        /// After `[` or a comma: a value, or `]`.
        case element
        /// After an element: a comma, or `]`.
        case elementEnd
    }

    let bytes: UnsafeBufferPointer<UInt8>
    let isTruncated: Bool
    let valueLimit: Int
    var position = 0
    var result = Result()
    /// The children found so far of every container still open, each container's run starting where
    /// its frame says. A run moves to `childSlots` when its container closes — inner containers close
    /// first, so every run lands there contiguous.
    var pending: [UInt32] = []
    var stack: [Frame] = []

    /// Read `bytes`, or `nil` when they are not JSON this reads. Running out part-way is malformed in
    /// a whole file, and in a truncated one closes whatever is still open.
    static func scan(
        _ bytes: UnsafeBufferPointer<UInt8>,
        isTruncated: Bool,
        valueLimit: Int
    ) -> Result? {
        var scanner = JSONScanner(bytes: bytes, isTruncated: isTruncated, valueLimit: valueLimit)
        do throws(Stop) {
            try scanner.run()
            guard scanner.stack.isEmpty || isTruncated else { return nil }
        } catch {
            guard error == .ranOut, isTruncated else { return nil }
        }
        while !scanner.stack.isEmpty {
            scanner.close(cut: true)
        }
        return scanner.result
    }

    private init(bytes: UnsafeBufferPointer<UInt8>, isTruncated: Bool, valueLimit: Int) {
        self.bytes = bytes
        self.isTruncated = isTruncated
        self.valueLimit = valueLimit
    }

    private mutating func run() throws(Stop) {
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            position = 3
        }
        while true {
            try skipTrivia()
            guard position < bytes.count else { return }
            guard let top = stack.indices.last else {
                try value(key: JSONDocument.absent, keyHasEscapes: false)
                continue
            }
            let byte = bytes[position]
            switch stack[top].expecting {
            case .key:
                guard byte != JSONByte.closeBrace else {
                    close(cut: false)
                    continue
                }
                try member(in: top)
            case .memberEnd:
                try separator(byte, closing: JSONByte.closeBrace, next: .key, in: top)
            case .element:
                guard byte != JSONByte.closeBracket else {
                    close(cut: false)
                    continue
                }
                stack[top].expecting = .elementEnd
                try value(key: JSONDocument.absent, keyHasEscapes: false)
            case .elementEnd:
                try separator(byte, closing: JSONByte.closeBracket, next: .element, in: top)
            }
        }
    }

    /// Read the member starting at `position`: its key, the colon, and its value.
    private mutating func member(in frame: Int) throws(Stop) {
        guard bytes[position] == JSONByte.quote else { throw .malformed }
        let key = UInt32(position)
        let keyHasEscapes = try string()
        try skipTrivia()
        guard position < bytes.count else { throw .ranOut }
        guard bytes[position] == JSONByte.colon else { throw .malformed }
        position += 1
        try skipTrivia()
        guard position < bytes.count else { throw .ranOut }
        stack[frame].expecting = .memberEnd
        try value(key: key, keyHasEscapes: keyHasEscapes)
    }

    /// What may follow a member or an element: a comma, or the bracket that closes its container.
    private mutating func separator(
        _ byte: UInt8,
        closing: UInt8,
        next: Expecting,
        in frame: Int
    ) throws(Stop) {
        if byte == JSONByte.comma {
            position += 1
            stack[frame].expecting = next
        } else if byte == closing {
            close(cut: false)
        } else {
            throw .malformed
        }
    }

    /// Read the value starting at `position`: a scalar whole, or a container's opening bracket.
    private mutating func value(key: UInt32, keyHasEscapes: Bool) throws(Stop) {
        let start = position
        let byte = bytes[start]
        var flags = keyHasEscapes ? JSONDocument.Node.keyHasEscapes : 0
        let kind: JSONDocument.Kind
        switch byte {
        case JSONByte.openBrace, JSONByte.openBracket:
            let isObject = byte == JSONByte.openBrace
            let node = try append(
                kind: isObject ? .object : .array,
                key: key,
                flags: flags,
                start: start,
                end: start
            )
            stack.append(Frame(
                node: node,
                pendingStart: pending.count,
                expecting: isObject ? .key : .element
            ))
            position += 1
            return
        case JSONByte.quote:
            if try string() { flags |= JSONDocument.Node.valueHasEscapes }
            kind = .string
        case JSONByte.minus, 0x30...0x39:
            try number()
            kind = .number
        case 0x74: // t
            try literal(Self.trueWord)
            kind = .boolean
        case 0x66: // f
            try literal(Self.falseWord)
            kind = .boolean
        case 0x6E: // n
            try literal(Self.nullWord)
            kind = .null
        case 0x4E: // N
            try literal(Self.notANumberWord)
            kind = .number
        case 0x49: // I
            try literal(Self.infinityWord)
            kind = .number
        default:
            throw .malformed
        }
        try append(kind: kind, key: key, flags: flags, start: start, end: position)
    }

    @discardableResult
    private mutating func append(
        kind: JSONDocument.Kind,
        key: UInt32,
        flags: UInt8,
        start: Int,
        end: Int
    ) throws(Stop) -> UInt32 {
        guard result.nodes.count < valueLimit else { throw .tooManyValues }
        let index = UInt32(result.nodes.count)
        result.nodes.append(JSONDocument.Node(
            kind: kind,
            flags: flags,
            keyStart: key,
            valueStart: UInt32(start),
            valueEnd: UInt32(end),
            childStart: 0,
            childCount: 0,
            parent: stack.last?.node ?? JSONDocument.absent
        ))
        if stack.isEmpty {
            result.roots.append(Int(index))
        } else {
            pending.append(index)
        }
        return index
    }

    /// Close the innermost open container at `position` — or, for a container the read limit cut, at
    /// the end of the bytes, marked incomplete.
    private mutating func close(cut: Bool) {
        let frame = stack.removeLast()
        let index = Int(frame.node)
        result.nodes[index].valueEnd = UInt32(cut ? bytes.count : position + 1)
        result.nodes[index].childStart = UInt32(result.childSlots.count)
        result.nodes[index].childCount = UInt32(pending.count - frame.pendingStart)
        if cut {
            result.nodes[index].flags |= JSONDocument.Node.incomplete
        } else {
            position += 1
        }
        result.childSlots.append(contentsOf: pending[frame.pendingStart...])
        pending.removeSubrange(frame.pendingStart...)
    }
}

// MARK: - Tokens

extension JSONScanner {
    /// Skip whitespace and comments.
    private mutating func skipTrivia() throws(Stop) {
        let count = bytes.count
        while position < count {
            switch bytes[position] {
            case JSONByte.space, JSONByte.tab, JSONByte.lineFeed, JSONByte.carriageReturn:
                position += 1
            case JSONByte.slash:
                guard position + 1 < count else { throw .ranOut }
                switch bytes[position + 1] {
                case JSONByte.slash:
                    position += 2
                    while position < count, bytes[position] != JSONByte.lineFeed,
                          bytes[position] != JSONByte.carriageReturn {
                        position += 1
                    }
                case JSONByte.star:
                    var index = position + 2
                    while index + 1 < count,
                          !(bytes[index] == JSONByte.star && bytes[index + 1] == JSONByte.slash) {
                        index += 1
                    }
                    guard index + 1 < count else { throw .ranOut }
                    position = index + 2
                default:
                    throw .malformed
                }
            default:
                return
            }
        }
    }

    /// Skip the string whose opening quote is at `position`, leaving `position` past its closing
    /// quote, and say whether it has an escape. A raw line break or tab inside is read as text.
    private mutating func string() throws(Stop) -> Bool {
        let count = bytes.count
        var index = position + 1
        var hasEscapes = false
        while index < count {
            let byte = bytes[index]
            if byte == JSONByte.quote {
                position = index + 1
                return hasEscapes
            }
            guard byte == JSONByte.backslash else {
                index += 1
                continue
            }
            hasEscapes = true
            guard index + 1 < count else { throw .ranOut }
            switch bytes[index + 1] {
            case JSONByte.quote, JSONByte.backslash, JSONByte.slash,
                 0x62, 0x66, 0x6E, 0x72, 0x74: // b f n r t
                index += 2
            case 0x75: // u
                for offset in 2...5 {
                    guard index + offset < count else { throw .ranOut }
                    guard JSONByte.hexValue(bytes[index + offset]) != nil else { throw .malformed }
                }
                index += 6
            default:
                throw .malformed
            }
        }
        throw .ranOut
    }

    /// Skip the number at `position`: `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`, or
    /// `-Infinity`.
    private mutating func number() throws(Stop) {
        let count = bytes.count
        var index = position
        if bytes[index] == JSONByte.minus {
            index += 1
            guard index < count else { throw .ranOut }
            if bytes[index] == 0x49 { // I
                position = index
                try literal(Self.infinityWord)
                return
            }
        }
        if bytes[index] == JSONByte.zero {
            index += 1
        } else {
            guard JSONByte.isDigit(bytes[index]) else { throw .malformed }
            index = digits(from: index)
        }
        if index < count, bytes[index] == JSONByte.dot {
            index += 1
            guard index < count else { throw .ranOut }
            guard JSONByte.isDigit(bytes[index]) else { throw .malformed }
            index = digits(from: index)
        }
        if index < count, bytes[index] == 0x65 || bytes[index] == 0x45 { // e E
            index += 1
            guard index < count else { throw .ranOut }
            if bytes[index] == JSONByte.plus || bytes[index] == JSONByte.minus {
                index += 1
                guard index < count else { throw .ranOut }
            }
            guard JSONByte.isDigit(bytes[index]) else { throw .malformed }
            index = digits(from: index)
        }
        position = index
        try requireDelimiter(valueCanRunOn: true)
    }

    private func digits(from start: Int) -> Int {
        var index = start
        while index < bytes.count, JSONByte.isDigit(bytes[index]) {
            index += 1
        }
        return index
    }

    private mutating func literal(_ word: [UInt8]) throws(Stop) {
        for (offset, expected) in word.enumerated() {
            guard position + offset < bytes.count else { throw .ranOut }
            guard bytes[position + offset] == expected else { throw .malformed }
        }
        position += word.count
        try requireDelimiter(valueCanRunOn: false)
    }

    /// A scalar ends where something that cannot continue it begins. At the end of the bytes a number
    /// in a truncated file may have had more digits, so it is cut; a word cannot run on.
    private func requireDelimiter(valueCanRunOn: Bool) throws(Stop) {
        guard position < bytes.count else {
            if valueCanRunOn, isTruncated { throw .ranOut }
            return
        }
        switch bytes[position] {
        case JSONByte.space, JSONByte.tab, JSONByte.lineFeed, JSONByte.carriageReturn,
             JSONByte.comma, JSONByte.closeBracket, JSONByte.closeBrace, JSONByte.slash:
            return
        default:
            throw .malformed
        }
    }

    private static let trueWord = Array("true".utf8)
    private static let falseWord = Array("false".utf8)
    private static let nullWord = Array("null".utf8)
    private static let notANumberWord = Array("NaN".utf8)
    private static let infinityWord = Array("Infinity".utf8)
}
