import AppKit
import DirnexCore

/// The bridge between a pasteboard and the VFS: what Dirnex *writes* when you ⌘C or start a drag,
/// and what it makes of whatever it is *handed* (PLAN.md §M23).
///
/// A namespace rather than a `PanelViewController` extension, for two reasons. ⌘C and drag are two
/// gestures that have to put the identical thing on the board — the whole reason the payload is one
/// row per item — and Slice 3's drag/drop reads exactly what Slice 2's clipboard writes, so a second
/// spelling is how they drift. And nothing here needs a pane, which makes it testable without one.
///
/// **Every read iterates `pasteboardItems`.** A multi-row drag is N items by AppKit's construction
/// (`pasteboardWriterForRow` is asked once per row), and a board-level `data(forType:)` returns only
/// the **first** item's data — measured 2026-08-26. A reader written the obvious way therefore drops
/// every row but one, silently, and a two-row drag is the smallest case that shows it.
enum PanelPasteboard {
    /// The private type carrying a `PasteboardPayload`. Named by the core beside the encoding it
    /// describes, so the writer and the reader cannot disagree about the string.
    static let locationsType = NSPasteboard.PasteboardType(PasteboardPayload.typeIdentifier)

    /// The types a pane accepts in a drag — ours first, since it is the richer one.
    static let acceptedDragTypes: [NSPasteboard.PasteboardType] = [locationsType, .fileURL]

    // MARK: - Writing

    /// Whether `entry` can go on the pasteboard at all.
    ///
    /// Everything except an **archive member**, which is deliberately left out until Slice 5: the
    /// payload can name one perfectly well, but nothing that *reads* one yet knows to route it to
    /// the extraction path, so a paste would enqueue a copy whose backend has no `copyFile` and fail
    /// inside the queue. Refusing to write it keeps the archive case exactly as it shipped —
    /// nothing on the board — rather than replacing "does nothing" with "fails later".
    ///
    /// Asked of the **row**, not of the pane: a results tab's container reads `search:` while its
    /// rows can be archive members, local files and objects on a server all at once.
    static func canWrite(_ entry: FileEntry) -> Bool {
        !entry.path.backend.isArchive
    }

    /// One pasteboard item per entry: the payload always, plus `public.file-url` for a row that has
    /// a real one.
    ///
    /// Carrying both on the same item is what keeps a **local** copy byte-identical to what shipped
    /// — macOS still promotes the URL into `NSFilenamesPboardType` and the rest, so Finder, Mail and
    /// everything else see an ordinary file — while a **mixed** selection hands other apps exactly
    /// the local subset and hands Dirnex every row, in order (measured 2026-08-26).
    ///
    /// Items are built fresh on every call and never cached: `-[NSPasteboard writeObjects:]`
    /// **raises** if handed an item that has already been written to a board (probed fatally).
    static func items(for entries: [FileEntry]) -> [NSPasteboardItem] {
        entries.compactMap { entry in
            guard canWrite(entry), let data = PasteboardPayload(entry).encoded() else { return nil }
            let item = NSPasteboardItem()
            item.setData(data, forType: locationsType)
            if entry.path.backend == .local {
                item.setString(entry.path.localURL.absoluteString, forType: .fileURL)
            }
            return item
        }
    }

    /// Replace `pasteboard`'s contents with `entries`. Returns `false` when there was nothing
    /// writable, so the caller can leave the previous clipboard alone rather than clearing it.
    @discardableResult
    static func write(_ entries: [FileEntry], to pasteboard: NSPasteboard) -> Bool {
        let items = items(for: entries)
        guard !items.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(items)
    }

    // MARK: - Reading

    /// What a transfer can be built from, resolved without touching the disk or the network.
    ///
    /// The two cases are not two formats of the same thing — they differ in what the caller still
    /// owes. Our own payload is already a snapshot, so it needs nothing; a foreign board is a list
    /// of URLs that has to be `stat`ed, which is I/O and belongs off the main actor.
    enum Sources {
        /// Dirnex's own payload — entries ready to hand the queue, at no round trip.
        case locations([FileEntry])
        /// Someone else's file URLs (Finder, Mail, a browser). The caller stats them.
        case fileURLs([URL])
    }

    /// Every payload on the board, in item order.
    static func payloads(in pasteboard: NSPasteboard) -> [PasteboardPayload] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            item.data(forType: locationsType).flatMap(PasteboardPayload.decode)
        }
    }

    /// The file URLs on the board, or an empty array.
    static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    /// What `pasteboard` offers, preferring our own payload, or `nil` when it offers nothing.
    ///
    /// **Payload first, and it is not merely the richer one.** Our board carries both for a local
    /// row, and reading the URLs there would be a *different answer*: a mixed selection's URL list
    /// silently omits every remote row, so a copy of three files — one on a server — would paste
    /// two and report success. Preferring the payload is what makes the count right.
    static func sources(in pasteboard: NSPasteboard) -> Sources? {
        let payloads = payloads(in: pasteboard)
        if !payloads.isEmpty { return .locations(payloads.map(\.entry)) }
        let urls = fileURLs(in: pasteboard)
        return urls.isEmpty ? nil : .fileURLs(urls)
    }

    /// Whether `pasteboard` holds anything a paste or a drop could act on — the gate behind Paste /
    /// Move Items Here in `validateMenuItem`.
    ///
    /// It asks for *either* carrier rather than replacing one with the other: a board written by
    /// Finder has no payload, and a board holding only remote rows has no file URL (probed — such a
    /// board answers `canReadObject(forClasses: [NSURL.self])` → `false`), so testing one alone
    /// grays the menu item out for half the cases the feature exists to serve.
    static func holdsSomethingToTransfer(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) { return true }
        return !payloads(in: pasteboard).isEmpty
    }
}
