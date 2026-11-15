import Foundation

/// The small text rules the class and ER diagrams share (PLAN.md §M39 ▸ Slice 14).
enum MermaidText {
    /// `text` with its HTML character references read, as Mermaid's labels read them.
    ///
    /// Mermaid sets a label as HTML, so the browser decodes every reference in it, and the one real
    /// class diagram on this Mac depends on that: a NuGet README writes `Task&lt;int&gt;` in a
    /// member and expects `Task<int>`. The named five, `&nbsp;` and numeric references are read; any
    /// other name stays as written, which is a wrong character rather than a lost one. The result is
    /// escaped again when it reaches the SVG (`MermaidSVG.text`), so `&lt;script&gt;` draws as text.
    static func decoded(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            rest = rest[ampersand...]
            guard let semicolon = rest.prefix(12).firstIndex(of: ";"),
                  let character = character(
                      named: rest[rest.index(after: rest.startIndex)..<semicolon]
                  )
            else {
                result.append("&")
                rest = rest.dropFirst()
                continue
            }
            result.append(character)
            rest = rest[rest.index(after: semicolon)...]
        }
        return result + rest
    }

    private static let named: [Substring: Character] = [
        "lt": "<", "gt": ">", "amp": "&", "quot": "\"", "apos": "'", "nbsp": "\u{A0}"
    ]

    private static func character(named name: Substring) -> Character? {
        if let character = named[name] { return character }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let value = digits.hasPrefix("x") || digits.hasPrefix("X")
            ? UInt32(digits.dropFirst(), radix: 16)
            : UInt32(digits, radix: 10)
        guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
        return Character(scalar)
    }

    /// A label's lines: Mermaid breaks one at `<br>`, `<br/>` and `<br />`, in any case.
    static func lines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "<") {
            current += rest[..<open]
            let tag = rest[open...].prefix(6).lowercased()
            let length = ["<br>", "<br/>", "<br />"].first { tag.hasPrefix($0) }?.count
            guard let length else {
                current.append("<")
                rest = rest[rest.index(after: open)...]
                continue
            }
            lines.append(current)
            current = ""
            rest = rest[open...].dropFirst(length)
        }
        lines.append(current + rest)
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// `"text"` without its quotes; anything else as written.
    static func unquoted(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
    }

    /// The index of the first `character` in `text` that is outside double quotes and backticks.
    static func firstUnquoted(_ character: Character, in text: String) -> String.Index? {
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let current = text[index]
            if let open = quote {
                if current == open { quote = nil }
            } else if current == "\"" || current == "`" {
                quote = current
            } else if current == character {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }
}
