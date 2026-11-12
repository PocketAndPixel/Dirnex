import Foundation
import Testing

@testable import DirnexCore

/// RTF's source, colored (PLAN.md §M39 ▸ Slice 3). The fixtures are cut from the shapes the 1 779
/// RTF files on the development Mac were written in: TextEdit's and every other Cocoa writer's, and
/// Word's, whose font table nests an ignorable `\panose` group in every entry.
@Suite("SyntaxRTFScanner")
struct SyntaxRTFScannerTests {
    private typealias Span = SyntaxSpan

    private func rtf(_ text: String) -> [Span] { syntaxSpans(text, .rtf) }

    // MARK: - Control words

    @Test("a control word is a keyword and its parameter a number, and a brace is a tag")
    func controlWords() {
        #expect(rtf(#"{\rtf1\ansi\ansicpg1252\cocoartf2822"#) == [
            Span("{", .typeOrTag),
            Span(#"\rtf"#, .keyword), Span("1", .number),
            Span(#"\ansi"#, .keyword),
            Span(#"\ansicpg"#, .keyword), Span("1252", .number),
            Span(#"\cocoartf"#, .keyword), Span("2822", .number)
        ])
    }

    @Test("a parameter may be negative, and a minus with no digit after it is text")
    func signedParameters() {
        #expect(rtf(#"\fi-360\li720"#) == [
            Span(#"\fi"#, .keyword), Span("-360", .number),
            Span(#"\li"#, .keyword), Span("720", .number)
        ])
        #expect(rtf(#"\endash- x"#) == [Span(#"\endash"#, .keyword)])
    }

    @Test("the text between control words, and the space that ends one, keep the document's color")
    func textIsLeftAlone() {
        #expect(rtf(#"\f0\b\fs28 \cf0 Legal Notices:"#) == [
            Span(#"\f"#, .keyword), Span("0", .number),
            Span(#"\b"#, .keyword),
            Span(#"\fs"#, .keyword), Span("28", .number),
            Span(#"\cf"#, .keyword), Span("0", .number)
        ])
        // A font table's names and a color table's separators are a destination's data, not markup.
        #expect(rtf(#"{\fonttbl\f0\fnil\fcharset0 LucidaGrande;}"#) == [
            Span("{", .typeOrTag),
            Span(#"\fonttbl"#, .keyword),
            Span(#"\f"#, .keyword), Span("0", .number),
            Span(#"\fnil"#, .keyword),
            Span(#"\fcharset"#, .keyword), Span("0", .number),
            Span("}", .typeOrTag)
        ])
    }

    // MARK: - Control symbols

    @Test("a control symbol that stands for a character is a string")
    func characterSymbols() {
        #expect(rtf(#"Copyright \'a9 caf\'E9 \\ \{ \} \~ \- \_"#) == [
            Span(#"\'a9"#, .string), Span(#"\'E9"#, .string),
            Span(#"\\"#, .string), Span(#"\{"#, .string), Span(#"\}"#, .string),
            Span(#"\~"#, .string), Span(#"\-"#, .string), Span(#"\_"#, .string)
        ])
    }

    @Test("a hex escape takes at most two hex digits, and what follows them is text")
    func hexEscapeEdges() {
        #expect(rtf(#"\'e9e9"#) == [Span(#"\'e9"#, .string)])
        #expect(rtf(#"\'zz"#) == [Span(#"\'"#, .string)])
        #expect(rtf(#"x\'4"#) == [Span(#"\'4"#, .string)])
    }

    /// Every Cocoa writer ends a paragraph this way, so it is on nearly every line of a TextEdit file.
    @Test("a backslash before a line break is a paragraph mark, and the break is not colored")
    func paragraphMark() {
        #expect(rtf("rights reserved. \\\n\\\nNext") == [
            Span("\\", .keyword), Span("\\", .keyword)
        ])
        #expect(rtf("a\\\r\nb") == [Span("\\", .keyword)])
    }

    @Test("every other control symbol is a keyword")
    func otherSymbols() {
        #expect(rtf(#"\| \: \*"#) == [
            Span(#"\|"#, .keyword), Span(#"\:"#, .keyword), Span(#"\*"#, .keyword)
        ])
    }

    @Test("a backslash that ends the text colors nothing")
    func trailingBackslash() {
        #expect(rtf("text \\").isEmpty)
        #expect(rtf("\\").isEmpty)
    }

    // MARK: - Ignorable groups

    @Test("a group marked ignorable is a comment, braces and nested groups included")
    func ignorableGroups() {
        #expect(rtf(#"{\*\generator Cocoa;}\pard"#) == [
            Span(#"{\*\generator Cocoa;}"#, .comment),
            Span(#"\pard"#, .keyword)
        ])
        // A field's instruction is skippable; its result is the text a reader shows.
        #expect(rtf(#"{\field{\*\fldinst{HYPERLINK "https://example.com"}}{\fldrslt site}}"#) == [
            Span("{", .typeOrTag),
            Span(#"\field"#, .keyword),
            Span(#"{\*\fldinst{HYPERLINK "https://example.com"}}"#, .comment),
            Span("{", .typeOrTag),
            Span(#"\fldrslt"#, .keyword),
            Span("}", .typeOrTag),
            Span("}", .typeOrTag)
        ])
    }

    @Test("Word's font table nests an ignorable group inside each entry")
    func wordFontTable() {
        let entry = #"{\f0\fbidi \froman\fcharset0\fprq2{\*\panose 02020603050405020304}Times New Roman;}"#
        #expect(rtf(entry) == [
            Span("{", .typeOrTag),
            Span(#"\f"#, .keyword), Span("0", .number),
            Span(#"\fbidi"#, .keyword),
            Span(#"\froman"#, .keyword),
            Span(#"\fcharset"#, .keyword), Span("0", .number),
            Span(#"\fprq"#, .keyword), Span("2", .number),
            Span(#"{\*\panose 02020603050405020304}"#, .comment),
            Span("}", .typeOrTag)
        ])
    }

    @Test("an escaped brace inside an ignorable group does not close it")
    func escapedBracesInsideAGroup() {
        #expect(rtf(#"{\*\comment a \} b \\}x\b"#) == [
            Span(#"{\*\comment a \} b \\}"#, .comment),
            Span(#"\b"#, .keyword)
        ])
    }

    /// A preview cut at `TextPreview.byteLimit`, or a broken file: the rest stays in the comment rather
    /// than the scanner guessing where the group was meant to end.
    @Test("an ignorable group that never closes runs to the end of the text")
    func unclosedGroup() {
        #expect(rtf(#"\pard{\*\themedata 504b0304{\b"#) == [
            Span(#"\pard"#, .keyword),
            Span(#"{\*\themedata 504b0304{\b"#, .comment)
        ])
    }

    @Test("a brace followed by anything but a backslash and an asterisk opens an ordinary group")
    func ordinaryGroups() {
        #expect(rtf(#"{\b bold}{*}"#) == [
            Span("{", .typeOrTag), Span(#"\b"#, .keyword), Span("}", .typeOrTag),
            Span("{", .typeOrTag), Span("}", .typeOrTag)
        ])
    }

    // MARK: - Offsets and routing

    @Test("offsets are UTF-16 units, past text outside the Basic Multilingual Plane")
    func offsetsAreUTF16() {
        #expect(rtf(#"🎉 Привет \b x\'e9"#) == [Span(#"\b"#, .keyword), Span(#"\'e9"#, .string)])
    }

    @Test(".rtf routes here by name, as a fence's language, and an RTFD package's TXT.rtf too")
    func routing() {
        #expect(SyntaxLanguage.forFile(named: "letter.rtf") == .rtf)
        #expect(SyntaxLanguage.forFile(named: "LETTER.RTF") == .rtf)
        #expect(SyntaxLanguage.forFile(named: "Help.rtfd/TXT.rtf") == .rtf)
        #expect(SyntaxLanguage.forFile(named: "notes.rtfd") == nil)
        #expect(SyntaxLanguage.forFenceInfo("rtf") == .rtf)
    }
}
