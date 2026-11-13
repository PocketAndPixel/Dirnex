import Foundation

/// The commands: one symbol from `TeXMathSymbols`, or a construct that reads arguments.
extension TeXMathParser {
    /// A command that ends the list or changes it rather than adding one item to it.
    mutating func listCommand(
        _ name: String,
        _ items: inout [Item],
        _ separators: Separators
    ) throws -> Stop? {
        switch name {
        case "\\", "newline", "cr":
            // A line break outside a table has no line to break, so it draws nothing.
            return separators.contains(.row) ? .row : nil
        case "right":
            return try .right(delimiter())
        case "end":
            return try .endEnvironment(environmentName())
        case "limits", "nolimits":
            setLimits(name == "limits", on: &items)
            return nil
        case "not":
            try items.append(negated())
            return nil
        default:
            if let stop = try styleSwitch(name, &items, separators) { return stop }
            if let item = try command(name) { items.append(item) }
            return nil
        }
    }

    /// The item a command draws, its own text in the class `math-unknown` for a command outside the
    /// subset, or `nil` for one that draws nothing (`\hline`, `\nonumber`).
    mutating func command(_ name: String) throws -> Item? {
        if let item = symbol(name) { return item }
        if let item = try structure(name) { return item }
        if Self.silent.contains(name) { return nil }
        return Item(.text("\\" + name, unknown: true))
    }

    /// Commands TeX reads and MathML has nothing to draw for.
    private static let silent: Set<String> = [
        "hline", "hdashline", "nonumber", "notag", "displaybreak", "allowbreak", "nobreak",
        "relax", "strut", "mathstrut"
    ]

    /// `\$`, `\%`, `\#`, `\&` and `\_`: the character itself.
    private static let literals: Set<String> = ["$", "%", "#", "&", "_"]

    /// `\displaystyle` and its kin.
    private static let styles: [String: TeXMathStyle] = [
        "displaystyle": TeXMathStyle(displayStyle: true, scriptLevel: 0),
        "textstyle": TeXMathStyle(displayStyle: false, scriptLevel: 0),
        "scriptstyle": TeXMathStyle(displayStyle: false, scriptLevel: 1),
        "scriptscriptstyle": TeXMathStyle(displayStyle: false, scriptLevel: 2)
    ]

    // MARK: Symbols

    private func symbol(_ name: String) -> Item? {
        if let width = TeXMathSymbols.spaces[name] { return Item(.space(width)) }
        if name == " " { return Item(.text("\u{00A0}", unknown: false)) }
        if Self.literals.contains(name) { return Item(.identifier(name, upright: true)) }
        if let (glyph, upright) = TeXMathSymbols.letters[name] {
            return letter(glyph, upright: upright)
        }
        if let (glyph, kind) = TeXMathSymbols.operators[name] {
            return Item(.symbol(TeXMathOperator(glyph)), kind)
        }
        if let (glyph, limits) = TeXMathSymbols.largeOperators[name] {
            return Item(.symbol(TeXMathOperator(glyph)), .op, limits: limits)
        }
        if let (text, limits) = TeXMathSymbols.functions[name] {
            return function(text, limits: limits)
        }
        if let (glyph, kind) = TeXMathSymbols.delimiters[name] {
            return Item(.symbol(TeXMathOperator(glyph, stretchy: false)), kind)
        }
        return nil
    }

    /// A function's name, upright. One that takes limits is an `<mo>` so WebKit can move them
    /// beside it inline, and is unspaced so the thin spaces `row` gives a function are the only
    /// ones it has.
    func function(_ name: String, limits: Bool) -> Item {
        var item = if limits {
            Item(
                .symbol(TeXMathOperator(name, movableLimits: true, spaced: false)),
                .op,
                limits: true
            )
        } else {
            Item(.identifier(name, upright: name.count == 1), .op)
        }
        item.isFunction = true
        return item
    }

    // MARK: Constructs

    private mutating func structure(_ name: String) throws -> Item? {
        if let item = try fraction(name) { return item }
        if let item = try decoration(name) { return item }
        if let item = try fence(name) { return item }
        if let item = try text(name) { return item }
        if let item = try wrapper(name) { return item }
        if name == "begin" { return try environment() }
        return nil
    }

    private mutating func fraction(_ name: String) throws -> Item? {
        switch name {
        case "frac", "dfrac", "tfrac", "cfrac", "binom", "dbinom", "tbinom":
            let top = try argument()
            let bottom = try argument()
            var node = TeXMathNode.fraction(top, bottom, rule: !name.hasSuffix("binom"))
            if name.hasSuffix("binom") { node = .row([Self.fence("("), node, Self.fence(")")]) }
            if name.hasPrefix("d") || name == "cfrac" {
                node = .style(node, TeXMathStyle(displayStyle: true))
            } else if name.hasPrefix("t") {
                node = .style(node, TeXMathStyle(displayStyle: false))
            }
            return Item(node)
        case "sqrt":
            skipSpace()
            guard index < characters.count, characters[index] == "[" else {
                return try Item(.squareRoot(argument()))
            }
            index += 1
            let (items, stop) = try list([.bracket])
            guard stop == .closeBracket else { throw Failure() }
            return try Item(.root(argument(), index: Self.row(items)))
        default:
            return nil
        }
    }

    /// Accents, braces and stacked symbols: something drawn over or under an argument.
    private mutating func decoration(_ name: String) throws -> Item? {
        if let accent = TeXMathSymbols.accents[name] {
            let base = try argument()
            let mark = TeXMathNode.symbol(TeXMathOperator(
                accent.glyph,
                stretchy: accent.stretchy,
                spaced: false,
                scale: accent.scale
            ))
            return Item(
                accent.under ? .under(base, mark, accent: true) : .over(base, mark, accent: true)
            )
        }
        switch name {
        case "overbrace":
            return try Item(.over(argument(), Self.fence("⏞"), accent: false), limits: true)
        case "underbrace":
            return try Item(.under(argument(), Self.fence("⏟"), accent: false), limits: true)
        case "overset", "stackrel":
            let top = try argument()
            let base = try argumentItem()
            return Item(.over(base.node, top, accent: false), name == "stackrel" ? .rel : base.kind)
        case "underset":
            let bottom = try argument()
            let base = try argumentItem()
            return Item(.under(base.node, bottom, accent: false), base.kind)
        default:
            return nil
        }
    }

    private mutating func fence(_ name: String) throws -> Item? {
        switch name {
        case "left":
            return try fenced()
        case "middle":
            return try Item(delimiter().map(Self.fence) ?? .row([]), .rel)
        default:
            guard let (size, kind) = TeXMathSymbols.bigDelimiters[name] else { return nil }
            guard let glyph = try delimiter() else { return Item(.row([])) }
            return Item(.symbol(TeXMathOperator(glyph, stretchy: true, size: size)), kind)
        }
    }

    /// `\text`, the font commands and `\operatorname`.
    private mutating func text(_ name: String) throws -> Item? {
        if let textFont = TeXMathFont.textCommands[name] {
            let text = try textArgument()
            return Item(.text(textFont.map { String(text.map($0.styled)) } ?? text, unknown: false))
        }
        if let mathFont = TeXMathFont.commands[name] {
            let saved = font
            font = mathFont
            defer { font = saved }
            return try Item(argument())
        }
        guard name == "operatorname" else { return nil }
        let limits = index < characters.count && characters[index] == "*"
        if limits { index += 1 }
        return try function(textArgument(), limits: limits)
    }

    private mutating func wrapper(_ name: String) throws -> Item? {
        switch name {
        case "phantom", "hphantom", "vphantom":
            return try Item(.phantom(argument()))
        case "boxed":
            return try Item(.boxed(argument()))
        case "mathop":
            return try Item(argument(), .op, limits: true)
        case "mathrel", "mathbin", "mathopen", "mathclose", "mathpunct", "mathord", "mathinner":
            return try Item(argument(), Self.explicitClasses[name] ?? .ord)
        case "pmod":
            let modulus = try argument()
            return Item(.row([
                .space("1em"), .symbol(TeXMathOperator("(", stretchy: false)),
                .identifier("mod", upright: false), .space("0.3333em"), modulus,
                .symbol(TeXMathOperator(")", stretchy: false))
            ]))
        case "bmod", "mod":
            return Item(.symbol(TeXMathOperator("mod")), .bin)
        default:
            return nil
        }
    }

    private static let explicitClasses: [String: TeXMathClass] = [
        "mathrel": .rel, "mathbin": .bin, "mathopen": .open, "mathclose": .close,
        "mathpunct": .punct
    ]

    // MARK: Modifiers

    /// `\displaystyle`, `\Large` and `{\bf …}`: each applies to the rest of the list it is in.
    private mutating func styleSwitch(
        _ name: String,
        _ items: inout [Item],
        _ separators: Separators
    ) throws -> Stop? {
        let style = Self.styles[name] ?? TeXMathSymbols.sizes[name].map { TeXMathStyle(size: $0) }
        let switched = TeXMathFont.switches[name]
        guard style != nil || switched != nil else { return nil }
        let saved = font
        if let switched { font = switched }
        defer { font = saved }
        let (rest, stop) = try list(separators)
        let body = Self.row(rest)
        items.append(Item(style.map { .style(body, $0) } ?? body))
        return stop
    }

    /// `\sum\limits` keeps its limits under and over inline too; `\int\nolimits` keeps them beside.
    private func setLimits(_ limits: Bool, on items: inout [Item]) {
        guard var last = items.popLast() else { return }
        if last.limits != nil {
            last.limits = limits
            if case var .symbol(symbol) = last.node {
                symbol.movableLimits = limits ? false : symbol.movableLimits
                last.node = .symbol(symbol)
            }
        }
        items.append(last)
    }

    /// `\not=` is `≠`: the negated character where Unicode has one, U+0338 through the symbol where
    /// it does not.
    private mutating func negated() throws -> Item {
        var item = try argumentItem()
        switch item.node {
        case var .symbol(symbol):
            symbol.glyph = TeXMathSymbols.negations[symbol.glyph] ?? symbol.glyph + "\u{0338}"
            item.node = .symbol(symbol)
        case let .identifier(text, upright):
            item.node = .identifier(text + "\u{0338}", upright: upright)
        default:
            break
        }
        return item
    }
}
