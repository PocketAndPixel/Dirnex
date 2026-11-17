import Testing

@testable import DirnexCore

@Suite("FileNameDisplay")
struct FileNameDisplayTests {
    @Test("an ordinary name draws as itself")
    func ordinaryName() {
        for name in [
            "report.pdf",
            "Screenshot 2026-07-01 233926.png",
            "Документы",
            "café",
            ".DS_Store",
            ""
        ] {
            #expect(FileNameDisplay.visible(name) == name)
        }
    }

    @Test("the custom-icon file's carriage return draws as a picture")
    func iconFile() {
        #expect(FileNameDisplay.visible("Icon\r") == "Icon\u{240D}")
    }

    @Test("both halves of a CRLF show, though Swift counts them as one character")
    func crlf() {
        #expect("a\r\nb".count == 3)
        #expect(FileNameDisplay.visible("a\r\nb") == "a\u{240D}\u{240A}b")
    }

    @Test("every C0 control maps to its own picture, in order")
    func everyC0Control() {
        for value in UInt32(0x00)...0x1F {
            let control = String(Unicode.Scalar(value)!)
            let picture = String(Unicode.Scalar(0x2400 + value)!)
            #expect(FileNameDisplay.visible("x\(control)y") == "x\(picture)y")
        }
        #expect(FileNameDisplay.visible("tab\there") == "tab\u{2409}here")
    }

    @Test("DEL draws as its picture")
    func delete() {
        #expect(FileNameDisplay.visible("a\u{7F}b") == "a\u{2421}b")
    }

    @Test("the line breaks with no picture of their own draw as the newline symbol")
    func otherLineBreaks() {
        #expect(
            FileNameDisplay.visible("a\u{85}b\u{2028}c\u{2029}d") == "a\u{2424}b\u{2424}c\u{2424}d"
        )
    }

    @Test("the result is one line however many breaks the name had")
    func oneLine() {
        let names = ["Icon\r", "a\nb", "a\r\nb", "x\u{2028}y", "\n\n\n", "a\u{0B}b\u{0C}c"]
        for name in names {
            let breaks = FileNameDisplay.visible(name).filter(\.isNewline)
            #expect(breaks.isEmpty, "\(name.debugDescription)")
        }
    }

    @Test("a name that already holds a picture is left alone")
    func existingPicture() {
        #expect(FileNameDisplay.visible("Icon\u{240D}") == "Icon\u{240D}")
    }
}
