import DirnexCore
import Foundation

/// The bytes of an exported Markdown page (PLAN.md §M39 ▸ Slice 12): the preview's render of the
/// whole file, under `QuickViewMarkdownStyle`'s export stylesheet, as an HTML file or printed to PDF.
///
/// The render is the preview's own (`MarkdownScan`), so the page holds what the preview drew: the
/// same images inlined from the document's folder down within the same budget, a remote image left
/// as its URL, and a link to another file as written (Oleg's calls, 2026-11-14). The one difference
/// is the length: an export reads the whole file, up to ``DirnexCore/MarkdownExport/sourceByteLimit``,
/// where the preview stops at 4 MB.
@MainActor
enum MarkdownExportFile {
    enum Failure: Error {
        /// The file is not text, `TextPreview`'s answer for a binary named `.md`.
        case notText
        /// The file is larger than an export reads.
        case tooLarge
    }

    /// Write `url`, the Markdown file `sourceName` names, as a `format` file at `destination`.
    ///
    /// `locateFile` finds the files a wiki link names, as the preview's does: the disk beside `url`
    /// when it is `nil`, which is right for a file on this disk.
    static func write(
        _ format: MarkdownExport.Format,
        from url: URL,
        sourceName: String,
        locateFile: (@Sendable (String) -> String?)? = nil,
        to destination: URL
    ) async throws {
        let page = try await html(from: url, sourceName: sourceName, locateFile: locateFile)
        switch format {
        case .html:
            try await BlockingWork.run { Result { try page.write(to: destination) } }.get()
        case .pdf:
            try await MarkdownExportPDF.write(page, to: destination)
        }
    }

    /// The HTML file's bytes for `url`.
    static func html(
        from url: URL,
        sourceName: String,
        locateFile: (@Sendable (String) -> String?)? = nil
    ) async throws -> Data {
        // Asked of the file before anything is read: past the ceiling, the read would hand back 64 MB
        // of text for the render to work through, only for the answer to be no.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= MarkdownExport.sourceByteLimit else { throw Failure.tooLarge }
        // On the main actor, since it resolves `NSColor`s; the render after it is not.
        let stylesheet = QuickViewMarkdownStyle.exportStylesheet()
        let scan = await BlockingWork.run {
            QuickViewPreviewView.MarkdownScan.read(
                url,
                byteLimit: MarkdownExport.sourceByteLimit,
                locateFile: locateFile
            )
        }
        guard let scan else { throw Failure.notText }
        guard !scan.isTruncated else { throw Failure.tooLarge }
        return MarkdownExport.htmlDocument(
            title: MarkdownExport.title(
                of: MarkdownRender(html: scan.html, title: scan.title),
                sourceName: sourceName
            ),
            stylesheet: stylesheet,
            body: scan.html
        )
    }
}
