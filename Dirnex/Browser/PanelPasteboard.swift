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
/// **Every row is carryable since Slice 5**, an archive member included. The payload could always
/// name one; what was missing was a *reader* that knew to route it to an extraction rather than to
/// the copy queue, so writing one would have replaced "⌘C does nothing" with "⌘V fails inside the
/// queue". `PanelViewController.resolveTransferSources` is that reader, and it is shared by ⌘V and
/// drop — so the only filter left here is whether a payload encodes at all.
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
            guard let data = PasteboardPayload(entry).encoded() else { return nil }
            return item(for: entry, payload: data)
        }
    }

    /// One writer per entry for a **drag**, which is where the clipboard's shape stops being enough:
    /// a row whose bytes are on a server gets an `NSFilePromiseProvider` instead of a plain item, so
    /// another app has something it can actually accept (PLAN.md §M23 Slice 4).
    ///
    /// The promise carries the payload as well (see `RemoteFilePromiseProvider`), so this stays one
    /// definition of what a dragged row *is* rather than two — a drag inside Dirnex reads the same
    /// snapshot whichever kind of writer produced the item, and only a drop in somebody else's app
    /// ever asks for the bytes.
    ///
    /// `delegate` is held **weakly** by every promise AppKit builds here, so the caller has to be
    /// something that outlives the drag; a pane is, which is why it is the pane that conforms.
    ///
    /// `routes` says which rows are promised (`DragOutRoute.isPromised`): a file on a server, and
    /// since M36 Slice 2 a file inside an archive this session can open. A row with no route, or a
    /// route that promises nothing, gets the plain item, which another app takes only for a row on
    /// this disk.
    static func dragWriters(
        for entries: [FileEntry],
        routes: [VFSPath: DragOutRoute],
        promisedTo delegate: any NSFilePromiseProviderDelegate
    ) -> [any NSPasteboardWriting] {
        entries.compactMap { entry -> (any NSPasteboardWriting)? in
            guard let data = PasteboardPayload(entry).encoded() else { return nil }
            if routes[entry.path]?.isPromised == true {
                return RemoteFilePromiseProvider.promise(
                    for: entry,
                    payload: data,
                    delegate: delegate
                )
            }
            return item(for: entry, payload: data)
        }
    }

    /// How a row whose bytes were on a server offers its file, once the drag has left the promise.
    enum HandoffFile {
        /// Declared now, and answered by this provider if anybody reads it.
        case answeredWhenRead(any NSPasteboardItemDataProvider)
        /// Here already.
        case here(URL)
    }

    /// One item per entry for a drag's board once it has left its promises (`RemoteDragHandoff`).
    ///
    /// Every row keeps its payload, which is what a drop back inside Dirnex reads, so it reads no file
    /// URL and costs no hold. A row `file` says nothing about keeps the shape a plain item has.
    static func handoffItems(
        for entries: [FileEntry],
        file: (FileEntry) -> HandoffFile?
    ) -> [NSPasteboardItem] {
        entries.compactMap { entry in
            guard let data = PasteboardPayload(entry).encoded() else { return nil }
            guard let offered = file(entry) else { return item(for: entry, payload: data) }
            let item = NSPasteboardItem()
            item.setData(data, forType: locationsType)
            switch offered {
            case let .answeredWhenRead(provider):
                item.setDataProvider(provider, forTypes: [.fileURL])
            case let .here(url):
                item.setString(url.absoluteString, forType: .fileURL)
            }
            return item
        }
    }

    /// The plain item for `entry`: the payload always, plus `public.file-url` for a row that has a
    /// real one. Built fresh on every call — see ``items(for:)``.
    private static func item(for entry: FileEntry, payload: Data) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(payload, forType: locationsType)
        if entry.path.backend == .local {
            item.setString(entry.path.localURL.absoluteString, forType: .fileURL)
        }
        return item
    }

    /// Replace `pasteboard`'s contents with `entries`. Returns `false` when there was nothing
    /// writable, so the caller can leave the previous clipboard alone rather than clearing it.
    @discardableResult
    static func write(_ entries: [FileEntry], to pasteboard: NSPasteboard) -> Bool {
        write(items(for: entries), to: pasteboard)
    }

    /// The one place the board is actually replaced, so every caller agrees about what "there was
    /// nothing to write" does to whatever was already on it.
    private static func write(
        _ writers: [any NSPasteboardWriting],
        to pasteboard: NSPasteboard
    ) -> Bool {
        guard !writers.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(writers)
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
