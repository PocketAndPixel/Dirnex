import Foundation
import Testing

@testable import DirnexCore

@Suite("TextLines")
struct TextLinesTests {
    /// Each line as `content|terminator`, so one comparison checks both.
    private func shape(_ text: String) -> [String] {
        TextLines.split(text).map { "\($0.content)|\($0.terminator)" }
    }

    @Test("splits at LF, CRLF and a lone CR, and keeps which one ended each line")
    func terminators() {
        #expect(shape("a\nb\r\nc\rd") == ["a|lf", "b|crlf", "c|cr", "d|none"])
    }

    @Test("a final line break ends the last line rather than starting an empty one, as git counts")
    func finalBreak() {
        #expect(shape("a\n") == ["a|lf"])
        #expect(shape("a") == ["a|none"])
        #expect(shape("a\r") == ["a|cr"])
        #expect(shape("\n") == ["|lf"])
        #expect(shape("\r\n\r\n") == ["|crlf", "|crlf"])
        #expect(TextLines.split("").isEmpty)
    }

    @Test("a CR is part of a CRLF only when the LF follows it directly")
    func carriageReturnRuns() {
        #expect(shape("a\r\r\nb") == ["a|cr", "|crlf", "b|none"])
        #expect(shape("a\n\rb") == ["a|lf", "|cr", "b|none"])
    }

    @Test("Unicode's other separators are content, as they are to git")
    func otherSeparatorsAreContent() {
        #expect(shape("a\u{2028}b\u{85}c\u{0C}d\n") == ["a\u{2028}b\u{85}c\u{0C}d|lf"])
    }

    @Test("multi-byte text and a combining mark after a break split cleanly")
    func multiByteText() {
        #expect(shape("привет\r\nмир") == ["привет|crlf", "мир|none"])
        // A mark cannot join the line break before it, so it starts the next line's content.
        #expect(shape("a\n\u{301}b") == ["a|lf", "\u{301}b|none"])
    }

    @Test("a string bridged from NSString splits the same as a native one")
    func bridgedString() {
        let text = "x\r\ny\rz\n"
        let bridged = NSString(string: text) as String
        #expect(shape(bridged) == shape(text))
        #expect(shape(bridged) == ["x|crlf", "y|cr", "z|lf"])
    }
}
