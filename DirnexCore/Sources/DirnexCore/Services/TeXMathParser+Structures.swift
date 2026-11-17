import Foundation

/// Environments, `\left…\right` and text: the constructs that read more than an argument.
extension TeXMathParser {
    // MARK: Environments

    /// `\begin{name}…\end{name}`. An environment outside the subset draws its rows centred between
    /// its own `\begin` and `\end` as text, as an unknown command does.
    mutating func environment() throws -> Item {
        let name = try environmentName()
        let base = name.hasSuffix("*") ? String(name.dropLast()) : name
        switch base {
        case "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "smallmatrix":
            return try matrix(name)
        case "cases", "dcases", "rcases":
            let table = try TeXMathNode.table(TeXMathTable(
                rows: rows(until: name),
                alignments: ["left", "left"]
            ))
            return Item(.row(name == "rcases" ? [table, Self.fence("}")] : [Self.fence("{"), table]))
        case "aligned", "align", "split", "alignat", "alignedat", "flalign", "eqnarray":
            if base.hasPrefix("alignat") || base == "alignedat" { _ = try argument() }
            var table = try TeXMathTable(
                rows: rows(until: name, aligned: true),
                alignments: ["right", "left"]
            )
            table.isAligned = true
            return Item(.table(table))
        case "gathered", "gather", "equation", "multline", "displaymath":
            return try Item(.table(TeXMathTable(rows: rows(until: name), alignments: [])))
        case "array", "subarray":
            let alignments = try columnAlignments()
            return try Item(.table(TeXMathTable(rows: rows(until: name), alignments: alignments)))
        default:
            let table = try TeXMathNode.table(TeXMathTable(rows: rows(until: name), alignments: []))
            return Item(.row([
                .text("\\begin{\(name)}", unknown: true), table,
                .text("\\end{\(name)}", unknown: true)
            ]))
        }
    }

    private static let matrixFences: [String: (String, String)] = [
        "pmatrix": ("(", ")"), "bmatrix": ("[", "]"), "Bmatrix": ("{", "}"),
        "vmatrix": ("|", "|"), "Vmatrix": ("‖", "‖")
    ]

    private mutating func matrix(_ name: String) throws -> Item {
        var node = try TeXMathNode.table(TeXMathTable(rows: rows(until: name), alignments: []))
        if name == "smallmatrix" { node = .style(node, TeXMathStyle(scriptLevel: 1)) }
        if let (open, close) = Self.matrixFences[name] {
            node = .row([Self.fence(open), node, Self.fence(close)])
        }
        return Item(node)
    }

    /// The cells up to `\end{name}`, row by row. A `\\` before the `\end` leaves no empty row. In
    /// `aligned`, each cell after an `&` opens with an empty `<mi>` so the `=` it usually starts
    /// with keeps a relation's spacing, as amsmath's `{}` does.
    private mutating func rows(until name: String, aligned: Bool = false) throws -> [[TeXMathNode]] {
        var rows: [[TeXMathNode]] = []
        var cells: [TeXMathNode] = []
        while true {
            var (items, stop) = try list([.cell, .row])
            if aligned, cells.count % 2 == 1 {
                items.insert(Item(.identifier("", upright: false)), at: 0)
            }
            cells.append(Self.row(items))
            switch stop {
            case .cell:
                continue
            case .row:
                rows.append(cells)
                cells = []
                skipRowSpacing()
            case .endEnvironment(name):
                rows.append(cells)
                if rows.count > 1, rows.last == [.row([])] { rows.removeLast() }
                return rows
            default:
                throw Failure()
            }
        }
    }

    /// `{name}` after `\begin` or `\end`.
    mutating func environmentName() throws -> String {
        skipSpace()
        guard index < characters.count, characters[index] == "{",
              let close = characters[index...].firstIndex(of: "}")
        else { throw Failure() }
        let name = String(characters[(index + 1)..<close]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0 == "*" }) else { throw Failure() }
        index = close + 1
        return name
    }

    /// An `array`'s `{lcr}`. Rules (`|`) are not drawn, and `p{…}` and `@{…}` columns align left.
    private mutating func columnAlignments() throws -> [String] {
        let spec = try textArgument()
        var alignments: [String] = []
        for character in spec {
            switch character {
            case "l", "p": alignments.append("left")
            case "c": alignments.append("center")
            case "r": alignments.append("right")
            default: continue
            }
        }
        return alignments
    }

    // MARK: Delimiters

    /// `\left(` … `\right)`, each delimiter stretched to the height of what is between them.
    mutating func fenced() throws -> Item {
        let open = try delimiter()
        let (items, stop) = try list()
        guard case let .right(close) = stop else { throw Failure() }
        var nodes: [TeXMathNode] = []
        if let open { nodes.append(Self.fence(open)) }
        nodes.append(Self.row(items))
        if let close { nodes.append(Self.fence(close)) }
        return Item(.row(nodes))
    }

    /// The delimiter after `\left`, `\right`, `\middle` or `\big`: `nil` for `.`, which draws none.
    /// Anything that is not a delimiter fails the formula, as it does in TeX.
    mutating func delimiter() throws -> String? {
        skipSpace()
        guard index < characters.count else { throw Failure() }
        let character = characters[index]
        index += 1
        if character == "." { return nil }
        if let glyph = TeXMathSymbols.delimiterCharacters[character] { return glyph }
        guard character == "\\" else { throw Failure() }
        let name = readCommand()
        if let (glyph, _) = TeXMathSymbols.delimiters[name] { return glyph }
        if name.hasSuffix("arrow") || name == "backslash",
           let (glyph, _) = TeXMathSymbols.operators[name] {
            return glyph
        }
        throw Failure()
    }

    // MARK: Text

    /// The text of `\text{…}`: the escaped characters as themselves and other commands as written,
    /// with each run of spaces one no-break space, since WebKit drops an `<mtext>`'s spaces at its
    /// ends and `\text{ if }` means the spaces.
    mutating func textArgument() throws -> String {
        skipSpace()
        guard index < characters.count else { throw Failure() }
        guard characters[index] == "{" else {
            index += 1
            return String(characters[index - 1])
        }
        index += 1
        var depth = 1
        var text = ""
        while index < characters.count {
            let character = characters[index]
            index += 1
            switch character {
            case "\\": text += textEscape()
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return Self.spacedText(text) }
            case "~": text.append("\u{00A0}")
            default: text.append(character)
            }
        }
        throw Failure()
    }

    private mutating func textEscape() -> String {
        guard index < characters.count else { return "\\" }
        let next = characters[index]
        switch next {
        case "{", "}", "$", "%", "&", "#", "_", " ":
            index += 1
            return String(next)
        case ",":
            index += 1
            return "\u{2009}"
        case "\\":
            index += 1
            return " "
        default:
            return "\\"
        }
    }

    private static func spacedText(_ text: String) -> String {
        var result = ""
        var inSpace = false
        for character in text {
            if character.isWhitespace, character != "\u{00A0}", character != "\u{2009}" {
                if !inSpace { result.append("\u{00A0}") }
                inSpace = true
            } else {
                result.append(character)
                inSpace = false
            }
        }
        return result
    }
}
