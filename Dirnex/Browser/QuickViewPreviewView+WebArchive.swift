import AppKit
import DirnexCore
import UniformTypeIdentifiers

/// Quick View's saved-page backend: a `.webarchive` or an `.mhtml`, drawn as the page somebody saved
/// (PLAN.md §M39).
///
/// Both used to reach Quick Look, which drew a webarchive through its own generator and an MHTML file
/// not at all. Both are pages, and the web surface already draws pages, so they render there: read,
/// converted when the file is MHTML (WebKit has none), and **sealed** by `DirnexCore` before WebKit
/// sees a byte, which moves every origin the page was saved from into a scheme nothing serves
/// (``DirnexCore/WebArchiveSeal``). That seal is the whole of the network argument. WebKit draws an
/// archive from itself, but it asks the network for whatever it fails to find there, and a crafted
/// file decides what it fails to find; sealed, a miss has nowhere to go.
///
/// One style, the page. A saved page's "source" is a binary property list or a MIME message, which
/// is nobody's idea of the file, and the page is a snapshot of the DOM as it stood when it was saved
/// (WebKit serializes the live document), so it draws whole with the page's scripts refused, the
/// shipped default.
extension QuickViewPreviewView {
    /// Show `url` as the page it saved, standing the other backends down.
    ///
    /// The read runs off the main actor under the one `loadToken`, like the Markdown backend's: small
    /// as it measured (19 ms for a 65 MB webarchive, 232 ms for an 88 MB MHTML, release build), the
    /// preview re-runs on every cursor step. A file that cannot be read as a saved page goes to Quick
    /// Look, which is where it went before, and so does a surface that cannot be built at all.
    func showWebArchive(_ url: URL) {
        standDownPDF()
        standDownQuickLook()
        standDownImage()
        standDownText()
        loadToken += 1
        let token = loadToken
        Task { [weak self] in
            let page = await BlockingWork.run {
                SavedPage.read(url)
            }
            guard let self, token == loadToken else { return }
            guard let page else {
                showQuickLook(url)
                return
            }
            ensureWebSurface { [weak self] surface in
                guard let self, token == loadToken else { return }
                guard let surface else {
                    showQuickLook(url)
                    return
                }
                surface.isHidden = false
                surface.showArchive(page.archive, document: page.document, source: url)
            }
        }
    }

    /// A saved page, sealed and encoded for WebKit: everything the detached read produces.
    struct SavedPage: Sendable {
        /// The sealed archive as the property list `WKWebView` loads.
        let archive: Data
        /// The sealed URL of the page itself, which its in-page anchors arrive against.
        let document: URL

        /// Blocking; call it off the main thread. `nil` for a file over the limit, or one that is
        /// not the saved page its name says.
        static func read(_ url: URL) -> SavedPage? {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= webArchiveByteLimit,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            else { return nil }
            let archive = isMHTML(url)
                ? try? MHTMLArchive.webArchive(from: data)
                : WebArchive(propertyList: data)
            guard let archive else { return nil }
            let sealed = WebArchiveSeal.seal(archive).archive
            guard let encoded = try? sealed.propertyListData() else { return nil }
            return SavedPage(
                archive: encoded,
                document: URL(string: sealed.mainResource.url) ?? url.deletingLastPathComponent()
            )
        }
    }

    /// The largest saved page read in-process. Reading, converting and sealing cost little at this
    /// size (above); what a larger page costs is WebKit decoding that many images on a cursor step.
    /// A larger one keeps Quick Look's view, which draws a webarchive itself.
    nonisolated static let webArchiveByteLimit = 64 * 1024 * 1024

    /// Whether `url` is a saved page this backend draws: a `.webarchive`, or an `.mhtml` / `.mht`.
    nonisolated static func isWebArchive(_ url: URL) -> Bool {
        isMHTML(url) || conforms(url, to: webArchiveType, extensions: ["webarchive"])
    }

    /// Whether `url` is MHTML, which is converted before it is sealed.
    ///
    /// Named by type and by extension, for the reason `isRenderableMarkdown` names both: macOS gives
    /// `.mhtml` and `.mht` the type `org.ietf.mhtml` today (measured), and a Mac where nothing declares
    /// it would resolve both to a dynamic type that conforms to nothing.
    nonisolated static func isMHTML(_ url: URL) -> Bool {
        conforms(url, to: mhtmlType, extensions: MHTMLArchive.fileExtensions)
    }

    private nonisolated static func conforms(_ url: URL, to type: UTType?, extensions: Set<String>) -> Bool {
        if extensions.contains(url.pathExtension.lowercased()) { return true }
        guard let type,
              let fileType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        else { return false }
        return fileType.conforms(to: type)
    }

    private nonisolated static let webArchiveType = UTType(WebArchive.contentType)
    private nonisolated static let mhtmlType = UTType(MHTMLArchive.contentType)
}
