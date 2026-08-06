import Foundation
import UniformTypeIdentifiers

/// How a rendered Markdown document reaches the images the file refers to (PLAN.md §M18 ▸ Slice 3).
///
/// ## Why the bytes have to be carried rather than pointed at
///
/// `![](img/x.png)` is the common case, and the obvious answer — load the generated page with the
/// file's own directory as `baseURL`, so relative sources resolve — **does not work**. Measured
/// against a real `WKWebView`: `loadHTMLString(_:baseURL:)` grants no filesystem read access
/// whatsoever, and an absolute `file://` source from such a page is refused just the same, so it is
/// the sandbox and not URL resolution. Only two shapes reached a real file:
///
/// - `loadFileURL(<a temp file>, allowingReadAccessTo: /)` — a generated page holding read access to
///   the **entire disk**, which is a preview that renders on cursor movement being handed rather
///   more than it needs; and
/// - a `data:` URI, which needs no grant at all (M16 measured that neither content rule touches
///   `data:`, so the inlined bytes load with the network still shut).
///
/// The second is chosen on those grounds and not on convenience: the page ends up able to read
/// exactly the images this code decided to give it, and nothing else. The price the plan named —
/// holding the bytes twice — measured small: 0.4 ms and 1.33× per megabyte, so a 4 MB screenshot
/// costs 1.6 ms of the render it rides on.
///
/// ## What it will hand over
///
/// A source is inlined only if it resolves **inside the document's own directory** — the same scope
/// `loadFileURL` grants a saved HTML page, so the two backends can be described with one sentence —
/// and only if it is an image type, and only while the document's budget lasts. Everything else
/// comes back untouched: a remote URL stays remote and is blocked by the content rules exactly as it
/// is for HTML, and a file that cannot be read renders as the alt text the author wrote.
enum QuickViewMarkdownImages {
    /// How many bytes of image one document may inline.
    ///
    /// Not a limit anybody sane will meet — this repo's own docs carry none, and a page of
    /// screenshots is a few MB. It exists because the preview re-renders on **every cursor step**,
    /// so a folder of pathological documents would otherwise turn arrow-key held down into
    /// hundreds of megabytes of transient string. At the cap that is ~13 ms and ~43 MB.
    static let budget = 32 * 1024 * 1024

    /// A resolver for `MarkdownRenderOptions`, scoped to `document`.
    ///
    /// The budget is per *document*, so it has to survive across the calls one render makes — and
    /// the render runs off the main actor, so the counter is behind a lock rather than merely
    /// captured. One resolver per render; nothing is shared between them.
    static func resolver(for document: URL) -> @Sendable (String) -> String {
        let directory = document.deletingLastPathComponent().resolvingSymlinksInPath()
        let remaining = Budget(bytes: budget)
        return { source in
            guard let url = readableURL(for: source, in: directory) else { return source }
            guard let data = try? Data(contentsOf: url), remaining.take(data.count) else {
                return source
            }
            guard let mime = imageMIMEType(of: url) else { return source }
            return "data:\(mime);base64," + data.base64EncodedString()
        }
    }

    /// The file `source` names, if the document is allowed to read it.
    ///
    /// `nil` for anything with a scheme (a remote image is not ours to fetch, and a `data:` one is
    /// already inline), for a source that escapes the document's directory, and for one that is not
    /// a regular file.
    ///
    /// The containment test is against **resolved** paths on both sides, so a `../` chain and a
    /// symlink out of the directory are both refused — `standardized` alone would fold the `..`
    /// away textually and answer for a path it never checked.
    private static func readableURL(for source: String, in directory: URL) -> URL? {
        guard !source.isEmpty, URL(string: source)?.scheme == nil else { return nil }
        // The source is a URL path, so `%20` in it is a space on disk. Anything that is not a valid
        // URL is taken literally, which is what a name containing a bare `%` needs.
        let path = source.removingPercentEncoding ?? source
        guard !path.hasPrefix("/") else { return nil }
        let candidate = directory.appendingPathComponent(path).resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(directory.path + "/") else { return nil }
        let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true ? candidate : nil
    }

    /// The MIME type for a file the page may draw, or `nil` for anything that is not an image.
    /// By content type rather than by extension list, so a `.jpeg`, a `.heic` and an `.svg` are all
    /// simply images — but gated on `conforms(to: .image)`, so a `.zip` renamed `.png` is refused
    /// rather than handed to the page as one.
    private static func imageMIMEType(of url: URL) -> String? {
        guard let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image),
              let mime = type.preferredMIMEType
        else { return nil }
        return mime
    }

    /// The remaining budget, shared by every call one render makes.
    ///
    /// `@unchecked Sendable` over an `NSLock` rather than `Mutex`, which is macOS 15 and this app
    /// targets 14. The lock is uncontended in practice — one render calls this serially — and is
    /// there because the closure is `@Sendable` and must be safe if that ever stops being true.
    private final class Budget: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: Int

        init(bytes: Int) { self.bytes = bytes }

        /// Whether `count` bytes fit, deducting them if so.
        func take(_ count: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard count <= bytes else { return false }
            bytes -= count
            return true
        }
    }
}
