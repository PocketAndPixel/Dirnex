import Foundation

@testable import DirnexCore

/// A token rendered back as the text it covers, which is the only readable way to assert a scan.
///
/// An offset assertion says nothing to a reader and passes for the wrong reason the moment a
/// fixture gains a character; `keyword(class)` is the claim the test is actually making. Shared
/// across the scanner suites so the three do not drift into three spellings of the same helper.
struct SyntaxSpan: Equatable, CustomStringConvertible {
    let text: String
    let kind: SyntaxToken.Kind

    init(_ text: String, _ kind: SyntaxToken.Kind) {
        self.text = text
        self.kind = kind
    }

    var description: String { "\(kind)(\(text))" }
}

/// Every span `language` finds in `text`, in order.
///
/// Slicing back out of the same `[UInt16]` the scanner indexed is deliberate: it proves the offsets
/// are usable as given, which is `SyntaxToken`'s whole contract with the app.
func syntaxSpans(_ text: String, _ language: SyntaxLanguage) -> [SyntaxSpan] {
    let units = Array(text.utf16)
    return SyntaxHighlighter.tokens(in: text, language: language).map {
        SyntaxSpan(String(decoding: units[$0.offset..<$0.end], as: UTF16.self), $0.kind)
    }
}
