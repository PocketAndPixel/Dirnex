import Foundation

/// How a line ended in the file it came from (PLAN.md §M31).
public enum LineTerminator: Sendable, Hashable {
    /// `\n`, every Unix and macOS text file since OS X.
    case lf
    /// `\r\n`, a Windows file.
    case crlf
    /// A lone `\r`, a classic Mac OS file.
    case cr
    /// The last line of a file that does not end in a line break.
    case none

    /// The characters that end the line in the file: empty for `none`.
    public var text: String {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        case .cr: "\r"
        case .none: ""
        }
    }
}

/// One line of a text file: what it says, and how it ended.
///
/// The terminator is kept apart from the content so a comparison can decide whether it counts.
/// git counts it, and so does `LineDiff` unless an option says otherwise: a file whose last line
/// has lost its newline is a different file, and ⌥F3 has already said so.
public struct TextLine: Sendable, Hashable {
    /// The line without its terminator.
    public let content: Substring
    public let terminator: LineTerminator

    public init(content: Substring, terminator: LineTerminator) {
        self.content = content
        self.terminator = terminator
    }
}

/// Splitting decoded text into lines for a comparison (PLAN.md §M31).
///
/// A line ends at `\n`, `\r\n` or a lone `\r`. That is one place this departs from git, which splits
/// at `\n` only and so reads a classic Mac file as a single line; Quick View's text view breaks such
/// a file into lines, and the compare window has to show the same lines it does. Unicode's other
/// separators (U+2028, U+0085, a form feed) are content, as they are to git.
public enum TextLines {
    /// The lines of `text`, in order. Empty text has none, and text ending in a line break has no
    /// empty line after it, which is how git counts lines too.
    public static func split(_ text: String) -> [TextLine] {
        // A string bridged from an `NSString` stores UTF-16, and walking its UTF-8 view would
        // transcode every byte on the way. One copy up front makes the walk below a plain scan.
        var text = text
        text.makeContiguousUTF8()
        let utf8 = text.utf8
        var lines: [TextLine] = []
        var start = utf8.startIndex
        var index = start
        while index != utf8.endIndex {
            let byte = utf8[index]
            guard byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") else {
                index = utf8.index(after: index)
                continue
            }
            // Slicing at a line break is always on a `Character` boundary: Unicode never joins a
            // break to the character before it, and `\r\n`, the one cluster that spans two bytes,
            // is consumed whole.
            let content = text[start..<index]
            let next = utf8.index(after: index)
            if byte == UInt8(ascii: "\n") {
                lines.append(TextLine(content: content, terminator: .lf))
                index = next
            } else if next != utf8.endIndex, utf8[next] == UInt8(ascii: "\n") {
                lines.append(TextLine(content: content, terminator: .crlf))
                index = utf8.index(after: next)
            } else {
                lines.append(TextLine(content: content, terminator: .cr))
                index = next
            }
            start = index
        }
        if start != utf8.endIndex {
            lines.append(TextLine(content: text[start...], terminator: .none))
        }
        return lines
    }
}
