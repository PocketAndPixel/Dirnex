import AppKit
import DirnexCore

/// Turning what a pasteboard offered into the entries the copy queue takes — the one step ⌘V and a
/// drop share, and the reason neither had to learn about archives twice (PLAN.md §M23 Slice 5).
///
/// Three things happen here and each is somebody's bug elsewhere in this file's neighbourhood. A
/// **foreign board** owes a `stat` and our own payload does not (`PanelPasteboard.Sources` keeps
/// them apart rather than normalising, so a paste of twenty objects off a server costs no round
/// trips). The blocking half runs **off the main actor**, since a `stat` on a mounted share is I/O.
/// And an **archive member** is routed to an extraction rather than to the queue, because
/// `CopyEngine` takes one backend for both ends and the archive backend has no `copyFile` — the
/// gap that kept ⌘C gray inside an archive until this slice.
extension PanelViewController {
    /// Resolve `offered` into copy-queue sources and hand them to `continuation`, which runs on the
    /// main actor once everything — including any extraction — is done.
    ///
    /// `admits` filters by **location**, before any I/O: a paste drops a source that would recurse
    /// into its own destination, while a drop has already refused the whole gesture for the same
    /// reason and passes everything. It is asked of the URL rather than of the stat'd entry so a
    /// refused source costs no round trip.
    ///
    /// The continuation may be handed an empty array — every source dropped, nothing extracted, or
    /// a URL that no longer stats — and callers treat that as "nothing to do" rather than as a
    /// failure. An extraction that fails *outright* reports itself and never reaches here.
    func resolveTransferSources(
        _ offered: PanelPasteboard.Sources,
        admitting admits: @escaping @Sendable (VFSPath) -> Bool = { _ in true },
        then continuation: @escaping @MainActor ([FileEntry]) -> Void
    ) {
        let backend = backend
        Task {
            let entries = await BlockingWork.run { () -> [FileEntry] in
                switch offered {
                case let .locations(rows):
                    // No stat: the payload carries what the engine reads, so pasting twenty objects
                    // off a server costs no round trips (PLAN.md §M23). A source that has since
                    // vanished is reported per item by the engine, exactly as it is for F5.
                    return rows.filter { admits($0.path) }
                case let .fileURLs(urls):
                    return urls.compactMap { url -> FileEntry? in
                        let source = VFSPath.local(url.path)
                        guard admits(source) else { return nil }
                        return try? backend.stat(at: source)
                    }
                }
            }
            let split = ArchiveTransferSources(entries)
            guard split.needsExtraction else {
                continuation(split.direct)
                return
            }
            // The archive members become real files first, through the funnel F5 copy-out uses —
            // so the passphrase question, its retry and the temp directory are all the shipped
            // ones, and a paste cannot become a second way out of an archive.
            extractArchiveSources(split.groups) { extracted in
                continuation(split.direct + extracted)
            }
        }
    }
}
