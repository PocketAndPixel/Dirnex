import DirnexCore
import Foundation

/// Which files a rendered Markdown document's wiki links find (PLAN.md §M39 ▸ Slice 7).
///
/// `[[name]]` is a link only when its file is there (`MarkdownWikiLink`), and the core asks the app,
/// once per name per render. Two answers, by where the document is:
///
/// - **On this disk**, the disk is asked beside the file. A name is answered as the disk spells it
///   (`URLResourceValues.name`), so `[[Note]]` on a volume that ignores case finds `note.md` and
///   links to that, and the click lands on the row: the pane finds a link's target by its exact
///   path, and `Note.md` is no row in it.
/// - **On a server or in an archive** the page is drawn from a local copy that sits alone in a temp
///   folder, so the disk knows nothing. The pane's own listing does: the files the active pane lists
///   in the document's folder, which is where the cursor that chose the document is. That costs no
///   request, which matters because the preview renders again on every cursor step. A name in a
///   subfolder is not in that listing and stays text, as does every name when the document came from
///   a results listing that shows nothing else from its folder.
enum QuickViewMarkdownWikiLinks {
    /// For a document on this disk: the file `path` names beside `document`, spelled as it is.
    static func onDisk(beside document: URL) -> @Sendable (String) -> String? {
        let directory = document.deletingLastPathComponent()
        return { path in
            let url = directory.appendingPathComponent(path)
            // Followed through a symlink, as opening the row would be.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { return nil }
            guard let name = try? url.resourceValues(forKeys: [.nameKey]).name else { return path }
            let folder = path.lastIndex(of: "/").map { String(path[...$0]) } ?? ""
            return folder + name
        }
    }

    /// For a document anywhere else: `path` when it is one of `names`, the files listed beside it.
    static func listed(_ names: Set<String>) -> @Sendable (String) -> String? {
        { names.contains($0) ? $0 : nil }
    }
}
