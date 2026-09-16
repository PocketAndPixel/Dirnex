import Foundation

/// A JSON document as Quick View's tree reads it (2026-09-15; moved here from the app when XML became
/// the second file drawn as a tree, 2026-09-16).
///
/// Two columns, the key and the value: a member's key, an element's index as `[3]`, a string in
/// quotes, a number or a word as written, and a container as how many values it holds, `{3}` or
/// `[12]`, with `…` when the read limit cut it.
extension JSONDocument: TreeDocument {
    public var labelNoun: TreeLabelNoun { .key }

    public func opensOnArrival(_ value: Int) -> Bool {
        kind(of: value).isContainer
    }

    /// A member's key; an element's index, as `[3]`; and for a file that is one scalar, `$`.
    public func keyLabel(of value: Int) -> TreeLabel {
        if let key = key(of: value) {
            // An empty key is legal JSON, and a blank cell would read as a missing one.
            return key.isEmpty
                ? TreeLabel("\"\"", role: .annotation)
                : .searched(key, role: .name)
        }
        if parent(of: value) != nil || roots.count > 1 {
            return TreeLabel("[\(position(of: value))]", role: .annotation)
        }
        return TreeLabel("$", role: .annotation)
    }

    public func valueLabel(of value: Int) -> TreeLabel {
        let kind = kind(of: value)
        switch kind {
        case .object, .array:
            let count = "\(childCount(of: value))\(isIncomplete(value) ? "…" : "")"
            return TreeLabel(kind == .object ? "{\(count)}" : "[\(count)]", role: .annotation)
        case .string:
            return .quoted(scalarText(of: value, byteLimit: TreeLabel.cellTextLimit))
        case .number, .boolean, .null:
            return .searched(scalarText(of: value), role: kind == .number ? .number : .keyword)
        }
    }

    /// A string's text, a number or word as written, and a container as indented JSON.
    public func stripText(of value: Int, byteLimit: Int) -> String {
        if kind(of: value).isContainer {
            return formattedText(of: value, byteLimit: byteLimit)
        }
        let text = scalarText(of: value)
        guard text.utf8.count > byteLimit else { return text }
        return scalarText(of: value, byteLimit: byteLimit) + "…"
    }

    /// The value whole — a string's text, or a container as indented JSON.
    public func copiedText(of value: Int) -> String {
        kind(of: value).isContainer ? formattedText(of: value) : scalarText(of: value)
    }
}
