import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// What the Date column draws for a row whose backend has no date.
///
/// An S3 "folder" is a common prefix rather than an object, so there is no `LastModified` anywhere
/// to render — and formatting the sentinel drew **01.01.1, 02:02**, which reads as a corrupt
/// timestamp rather than an absent one. Caught by browsing a real bucket: every fixture in this area
/// carries a real date, so no listing test could see it.
@Suite("Date column text")
@MainActor
struct FileFormattingDateTests {
    private func entry(modified: Date) -> FileEntry {
        FileEntry(
            path: .local("/tmp/x"),
            name: "x",
            kind: .directory,
            byteSize: 0,
            modificationDate: modified,
            creationDate: modified,
            isHidden: false,
            permissions: 0o755,
            inode: 0,
            symlinkDestination: nil,
            symlinkTargetKind: nil
        )
    }

    @Test("a row with no date draws the same dash an unmeasured folder's size does")
    func unknownDateRendersAsDash() {
        #expect(FileFormatting.dateString(for: entry(modified: FileEntry.unknownDate)) == "—")
    }

    /// The other half, so the fix cannot become "never show a date": a real timestamp still
    /// formats, and it is asserted against the same formatter the rows use rather than against a
    /// literal, since the shape is the running Mac's region (docs/NOTES.md ▸ Localization).
    @Test("a real date still formats")
    func realDateStillFormats() {
        let now = Date()
        let rendered = FileFormatting.dateString(for: entry(modified: now))
        #expect(rendered != "—")
        #expect(!rendered.isEmpty)
    }
}
