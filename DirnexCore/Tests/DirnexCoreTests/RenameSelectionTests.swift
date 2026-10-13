import Foundation
import Testing

@testable import DirnexCore

@Suite("RenameSelection")
struct RenameSelectionTests {
    /// The preselected text, which reads better in a failure than a range does.
    private func selected(_ name: String, isDirectory: Bool) -> String {
        let range = RenameSelection.range(forName: name, isDirectory: isDirectory)
        return (name as NSString).substring(with: range)
    }

    @Test("a file selects everything before its last dot")
    func fileStem() {
        #expect(selected("report.pdf", isDirectory: false) == "report")
        #expect(selected("archive.tar.gz", isDirectory: false) == "archive.tar")
        #expect(selected("aaa.bbb.ccc", isDirectory: false) == "aaa.bbb")
    }

    @Test("a file with no extension, or only a leading dot, selects whole")
    func fileWithoutExtension() {
        #expect(selected("Makefile", isDirectory: false) == "Makefile")
        #expect(selected(".zshrc", isDirectory: false) == ".zshrc")
    }

    @Test("a folder with dots in its name selects whole")
    func folderWithDots() {
        #expect(selected("aaa.bbb.ccc", isDirectory: true) == "aaa.bbb.ccc")
        #expect(selected("v1.2", isDirectory: true) == "v1.2")
        #expect(selected("com.example.app.d", isDirectory: true) == "com.example.app.d")
        #expect(selected(".config.old", isDirectory: true) == ".config.old")
    }

    @Test("a folder whose extension names a non-package bundle selects whole")
    func nonPackageBundles() {
        #expect(selected("Sparkle.framework", isDirectory: true) == "Sparkle.framework")
        #expect(selected("Assets.xcassets", isDirectory: true) == "Assets.xcassets")
        #expect(selected("en.lproj", isDirectory: true) == "en.lproj")
    }

    @Test("a package keeps its extension out of the selection, as a file does")
    func packages() {
        #expect(selected("Safari.app", isDirectory: true) == "Safari")
        #expect(selected("My.Tool.app", isDirectory: true) == "My.Tool")
        #expect(selected("Notes.rtfd", isDirectory: true) == "Notes")
        #expect(selected("Dirnex.xcodeproj", isDirectory: true) == "Dirnex")
        #expect(selected("Helper.bundle", isDirectory: true) == "Helper")
    }

    @Test("the range is in UTF-16 units, so a name past the BMP selects cleanly")
    func utf16Range() {
        #expect(selected("📁.notes.d", isDirectory: true) == "📁.notes.d")
        #expect(selected("📄 draft.txt", isDirectory: false) == "📄 draft")
    }
}
