import Foundation

/// Reads TeX math into `TeXMathNode`s (PLAN.md §M39 ▸ Slice 8). The commands are in
/// `TeXMathParser+Commands`, the environments and delimiters in `TeXMathParser+Structures`.
///
/// One pass, left to right, with the recursion TeX's own grammar has: a group, a `\left`, an
/// environment's cell and a command's argument each read a list of their own. `^`, `_` and `'`
/// attach to the item before them, and `\over` splits the list it is in, which is why a list is
/// read whole before it becomes a row.
struct TeXMathParser {
    /// A formula that cannot be drawn: its structure does not close, or nests deeper than any
    /// formula a person writes.
    struct Failure: Error {}

    /// What ended a list.
    enum Stop: Equatable {
        case end
        case closeBrace
        case closeBracket
        /// `\right` and the delimiter it draws, `nil` for `\right.`.
        case right(String?)
        case cell
        case row
        case endEnvironment(String)
    }

    /// Which of the separators end the list being read rather than being drawn: `&` and `\\`
    /// only in an environment's cell, `]` only in `\sqrt[…]`'s index.
    struct Separators: OptionSet {
        let rawValue: Int
        static let cell = Separators(rawValue: 1)
        static let row = Separators(rawValue: 2)
        static let bracket = Separators(rawValue: 4)
    }

    /// One atom of a list, with what its neighbours need to know about it.
    struct Item {
        var node: TeXMathNode
        var kind: TeXMathClass
        /// An operator's: whether its scripts go under and over. `nil` for anything else.
        var limits: Bool?
        /// A named function, `\sin`, which TeX spaces from a letter on either side.
        var isFunction = false

        init(_ node: TeXMathNode, _ kind: TeXMathClass = .ord, limits: Bool? = nil) {
            self.node = node
            self.kind = kind
            self.limits = limits
        }
    }

    /// What `\over` and its kin leave above the bar while the rest of their list is read.
    struct Numerator {
        let items: [Item]
        let rule: Bool
        let delimiters: (String, String)?
    }

    /// Deep enough for any formula a person writes, and shallow enough that a file of ten thousand
    /// `{` fails rather than exhausting the stack.
    static let maximumDepth = 64

    let characters: [Character]
    var index = 0
    /// The font `\mathbf{…}` and its kin put the letters of their argument in.
    var font: TeXMathFont?
    private var depth = 0

    init(_ tex: String) {
        characters = Array(tex)
    }

    /// The whole formula. `\\` at the top breaks it into lines, centred one under another.
    mutating func formula() throws -> TeXMathNode {
        var lines: [TeXMathNode] = []
        while true {
            let (items, stop) = try list([.row])
            lines.append(Self.row(items))
            switch stop {
            case .end:
                if lines.count > 1, lines.last == .row([]) { lines.removeLast() }
                guard lines.count > 1 else { return lines[0] }
                return .table(TeXMathTable(rows: lines.map { [$0] }, alignments: []))
            case .row:
                skipRowSpacing()
            default:
                throw Failure()
            }
        }
    }

    /// Items up to whatever ends the list, which the caller checks is what it expected.
    mutating func list(_ separators: Separators = []) throws -> (items: [Item], stop: Stop) {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maximumDepth else { throw Failure() }
        var items: [Item] = []
        var numerator: Numerator?
        while true {
            guard let stop = try step(&items, &numerator, separators) else { continue }
            if let fraction = numerator {
                var node = TeXMathNode.fraction(
                    Self.row(fraction.items),
                    Self.row(items),
                    rule: fraction.rule
                )
                if let (open, close) = fraction.delimiters {
                    node = .row([Self.fence(open), node, Self.fence(close)])
                }
                items = [Item(node)]
            }
            return (items, stop)
        }
    }

    /// One token of a list: an item appended, a script attached, or the list's end.
    private mutating func step(
        _ items: inout [Item],
        _ numerator: inout Numerator?,
        _ separators: Separators
    ) throws -> Stop? {
        skipSpace()
        guard index < characters.count else { return .end }
        let character = characters[index]
        switch character {
        case "}":
            index += 1
            return .closeBrace
        case "]" where separators.contains(.bracket):
            index += 1
            return .closeBracket
        case "&" where separators.contains(.cell):
            index += 1
            return .cell
        case "{":
            items.append(try group())
        case "^", "_":
            index += 1
            try attachScript(superscript: character == "^", to: &items)
        case "'":
            attachPrimes(to: &items)
        case "\\":
            index += 1
            let name = readCommand()
            if let infix = Self.infixFractions[name] {
                numerator = Numerator(items: items, rule: infix.rule, delimiters: infix.delimiters)
                items = []
                return nil
            }
            return try listCommand(name, &items, separators)
        default:
            items.append(self.character())
        }
        return nil
    }

    /// `\over` and its kin, which divide the list they are in.
    private static let infixFractions: [String: (rule: Bool, delimiters: (String, String)?)] = [
        "over": (true, nil), "atop": (false, nil), "choose": (false, ("(", ")")),
        "brace": (false, ("{", "}")), "brack": (false, ("[", "]"))
    ]

    // MARK: Atoms

    /// `{…}`, read as one item.
    mutating func group() throws -> Item {
        index += 1
        let (items, stop) = try list()
        guard stop == .closeBrace else { throw Failure() }
        return Item(Self.row(items))
    }

    /// The argument of a command or a script: a group, or one token, so `x^12` raises the `1`
    /// alone and `\frac12` is a half, as in TeX.
    mutating func argument() throws -> TeXMathNode {
        try argumentItem().node
    }

    mutating func argumentItem() throws -> Item {
        // Counted here as well as in `list`: `\frac\frac\frac…` nests through arguments alone.
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maximumDepth else { throw Failure() }
        skipSpace()
        guard index < characters.count else { throw Failure() }
        let character = characters[index]
        switch character {
        case "{":
            return try group()
        case "}", "&", "^", "_":
            throw Failure()
        case "\\":
            index += 1
            let name = readCommand()
            guard let item = try command(name) else { throw Failure() }
            return item
        default:
            if character.isASCII, character.isNumber {
                index += 1
                return Item(.number(styledText(String(character))))
            }
            return self.character()
        }
    }

    /// A character written as itself: a letter, a number, or an operator.
    private mutating func character() -> Item {
        let character = characters[index]
        if character.isASCII, character.isNumber { return number() }
        if character == ".", index + 1 < characters.count, characters[index + 1].isASCII,
           characters[index + 1].isNumber {
            return number()
        }
        index += 1
        if character.isLetter { return letter(String(character)) }
        if character == "~" { return Item(.text("\u{00A0}", unknown: false)) }
        let glyph = switch character {
        case "-": "−"
        case "*": "∗"
        default: String(character)
        }
        let isDelimiter = "()[]|".contains(character)
        return Item(
            .symbol(TeXMathOperator(glyph, stretchy: isDelimiter ? false : nil)),
            TeXMathSymbols.characterClass(glyph) ?? .ord
        )
    }

    /// Digits, with a decimal point between them: `1.2345` is one number.
    private mutating func number() -> Item {
        let start = index
        var seenPoint = false
        while index < characters.count {
            let character = characters[index]
            if character.isASCII, character.isNumber {
                index += 1
            } else if character == ".", !seenPoint, index + 1 < characters.count,
                      characters[index + 1].isASCII, characters[index + 1].isNumber {
                seenPoint = true
                index += 1
            } else {
                break
            }
        }
        return Item(.number(styledText(String(characters[start..<index]))))
    }

    /// A letter in the current font: italic by default, as a one-letter `<mi>` is.
    func letter(_ glyph: String, upright: Bool = false) -> Item {
        switch font {
        case .roman: Item(.identifier(glyph, upright: true))
        case nil: Item(.identifier(glyph, upright: upright))
        default:
            Item(.identifier(styledText(glyph), upright: upright && styledText(glyph) == glyph))
        }
    }

    func styledText(_ text: String) -> String {
        guard let font, font != .roman else { return text }
        return String(text.map(font.styled))
    }

    // MARK: Reading

    /// The name after a `\`: a run of letters, or the one character that follows. A name made of
    /// letters swallows the spaces after it, as TeX's does.
    mutating func readCommand() -> String {
        guard index < characters.count else { return "" }
        let start = index
        while index < characters.count, characters[index].isASCII, characters[index].isLetter {
            index += 1
        }
        guard index == start else {
            let name = String(characters[start..<index])
            skipSpace()
            return name
        }
        index += 1
        return String(characters[start])
    }

    /// Spaces, line breaks and `%` comments, which math mode ignores.
    mutating func skipSpace() {
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
            } else if character == "%" {
                while index < characters.count, !characters[index].isNewline {
                    index += 1
                }
            } else {
                return
            }
        }
    }

    /// The `[2pt]` that may follow `\\`, which sets the space under a row and is not drawn.
    mutating func skipRowSpacing() {
        skipSpace()
        guard index < characters.count, characters[index] == "[",
              let close = characters[index...].firstIndex(of: "]")
        else { return }
        index = close + 1
    }
}

extension TeXMathParser.Item {
    var isSpace: Bool {
        if case .space = node { return true }
        return false
    }
}
