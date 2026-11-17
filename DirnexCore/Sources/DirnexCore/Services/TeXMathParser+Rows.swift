import Foundation

/// Scripts, primes and rows: what turns a list of items into one node.
extension TeXMathParser {
    // MARK: Scripts

    mutating func attachScript(superscript: Bool, to items: inout [Item]) throws {
        let argument = try argument()
        var base = items.popLast() ?? Item(.row([]))
        if superscript, argument == .identifier("′", upright: true) {
            base.node = .row([base.node, .symbol(TeXMathOperator("′"))])
        } else if case let .scripts(inner, sub, sup, limits) = base.node,
                  superscript ? sup == nil : sub == nil {
            base.node = .scripts(
                inner,
                sub: superscript ? sub : argument,
                sup: superscript ? argument : sup,
                limits: limits
            )
        } else {
            base.node = .scripts(
                base.node,
                sub: superscript ? nil : argument,
                sup: superscript ? argument : nil,
                limits: base.limits ?? false
            )
        }
        items.append(base)
    }

    /// `f'` is `f` and then a prime at full size, which WebKit draws where a superscript prime
    /// comes out tiny (see `TeXMath`). A superscript after it lands on `f′`, as in `f'^2`.
    mutating func attachPrimes(to items: inout [Item]) {
        var count = 0
        while index < characters.count, characters[index] == "'" {
            count += 1
            index += 1
        }
        let glyph = switch count {
        case 1: "′"
        case 2: "″"
        case 3: "‴"
        default: String(repeating: "′", count: count)
        }
        var base = items.popLast() ?? Item(.row([]))
        base.node = .row([base.node, .symbol(TeXMathOperator(glyph))])
        base.limits = nil
        items.append(base)
    }

    // MARK: Rows

    /// A list as one node, with TeX's spacing rules applied where MathML's dictionary cannot
    /// know them: a `+` or `-` that is a sign, and the thin space around a function's name.
    static func row(_ items: [Item]) -> TeXMathNode {
        var nodes: [TeXMathNode] = []
        var previous: Item?
        for (position, original) in items.enumerated() {
            var item = original
            if item.kind == .bin, case var .symbol(symbol) = item.node,
               previous.map({ [.bin, .op, .rel, .open, .punct].contains($0.kind) }) ?? true {
                symbol.prefix = true
                item.node = .symbol(symbol)
                item.kind = .ord
            }
            // Only between two atoms: a `\quad` beside the name is space enough.
            let before = position > 0 ? items[position - 1] : nil
            let after = position + 1 < items.count ? items[position + 1] : nil
            if item.isFunction, let before, !before.isSpace, [.ord, .close].contains(before.kind) {
                nodes.append(.space(thinSpace))
            }
            nodes.append(item.node)
            if item.isFunction, let after, !after.isSpace, !after.isFunction,
               [.ord, .op].contains(after.kind) {
                nodes.append(.space(thinSpace))
            }
            if !item.isSpace { previous = item }
        }
        return nodes.count == 1 ? nodes[0] : .row(nodes)
    }

    static let thinSpace = "0.1667em"

    /// A delimiter that stretches to the height of what it encloses.
    static func fence(_ glyph: String) -> TeXMathNode {
        .symbol(TeXMathOperator(glyph, stretchy: true))
    }
}
