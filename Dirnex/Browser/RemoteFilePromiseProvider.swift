import AppKit
import DirnexCore
import UniformTypeIdentifiers

/// A dragged row whose bytes are not on this Mac — what Finder, Mail or Teams is handed so a file
/// on a server can be dropped into them (PLAN.md §M23 Slice 4).
///
/// A **promise** is the only shape available: the receiving app wants a `file://` URL, and there is
/// no such URL until somebody has spent a transfer. macOS's own answer to that is
/// `NSFilePromiseProvider` — the board advertises "a file of this type, under this name, on demand",
/// and the bytes are fetched when (and only when) something accepts the drop. So arrowing past a
/// 4 GB object and dragging it to the desktop costs nothing until the mouse is let go.
///
/// **It carries the payload too**, which is what keeps one drag from being two. Overriding the three
/// `NSPasteboardWriting` members adds `com.dirnex.locations` to the promise's own types, so a drag
/// *inside* Dirnex reads the same snapshot `PanelPasteboard.items` writes for a local row and routes
/// through the same `submitTransfer` — rather than the pane accepting its own promise and
/// round-tripping a server's file through this Mac. Measured 2026-08-26 on a real board: a mixed
/// drag of one promise and one local row exposes `com.dirnex.locations` on **both** items, hands
/// `readObjects` only the local URL, and still advertises `Apple files promise pasteboard type` at
/// board level.
final class RemoteFilePromiseProvider: NSFilePromiseProvider {
    /// The row this promise stands for, so the delegate fulfilling it knows what to fetch.
    ///
    /// Typed, rather than the inherited `userInfo`: that property is `Any?`, so every reader would
    /// cast, and a cast that silently fails here is a promise that resolves to nothing while the
    /// receiving app waits.
    private(set) var entry: FileEntry?

    /// The encoded `PasteboardPayload`, or `nil` if it could not be encoded — in which case the
    /// private type is simply not advertised and the promise is still a perfectly good promise.
    private var locations: Data?

    /// Whether `entry` is a row a promise can stand for.
    ///
    /// Two conditions and each rules out a different thing. It must live on a **server**, because a
    /// local row already has a real `file://` URL and needs nothing promised; and it must be a
    /// **file**, because a promise is one file — a folder would mean a recursive fetch behind a
    /// Finder drop, with no progress surface and no way to stop it, which PLAN.md §M23 puts out of
    /// scope deliberately rather than by omission. A remote folder still drags *inside* Dirnex on
    /// its payload alone, exactly as it did before this existed.
    static func canPromise(_ entry: FileEntry) -> Bool {
        entry.path.backend.isRemoteConnection && entry.kind == .file
    }

    /// The promise for `entry`, or `nil` when the row needs none (``canPromise(_:)``).
    ///
    /// `payload` is passed in rather than encoded here so that the caller's one decision about what
    /// goes on the board — `PanelPasteboard` — stays the only place a payload is made.
    static func promise(
        for entry: FileEntry,
        payload: Data,
        delegate: any NSFilePromiseProviderDelegate
    ) -> RemoteFilePromiseProvider? {
        guard canPromise(entry) else { return nil }
        let provider = RemoteFilePromiseProvider(
            fileType: fileType(for: entry.name), delegate: delegate
        )
        provider.entry = entry
        provider.locations = payload
        return provider
    }

    /// The UTI a promise of `name` advertises — how the receiving app decides what it is being
    /// offered before any byte is fetched.
    ///
    /// Derived from the extension, with `public.data` as the floor for two separate reasons:
    /// `NSFilePromiseProvider` **raises** for a type conforming to neither `public.data` nor
    /// `public.directory`, and a name with no extension (or one macOS has never heard of) resolves
    /// to nothing at all. So the fallback is not defensive tidiness — it is what stops a file called
    /// `README` from throwing while its neighbour drags fine.
    static func fileType(for name: String) -> String {
        let suffix = (name as NSString).pathExtension
        guard !suffix.isEmpty, let type = UTType(filenameExtension: suffix),
              type.conforms(to: .data) else { return UTType.data.identifier }
        return type.identifier
    }

    // MARK: - Carrying the payload alongside the promise

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        if locations != nil { types.append(PanelPasteboard.locationsType) }
        return types
    }

    /// No options for our own type, whatever the superclass says about its promised ones.
    ///
    /// The payload is a handful of bytes that already exist, so there is nothing to defer — and
    /// `.promised` here would make a drop's read of it depend on this object still being alive,
    /// which is a lifetime question the drag has no reason to ask.
    override func writingOptions(
        forType type: NSPasteboard.PasteboardType,
        pasteboard: NSPasteboard
    ) -> NSPasteboard.WritingOptions {
        guard type != PanelPasteboard.locationsType else { return [] }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        guard type != PanelPasteboard.locationsType else { return locations }
        return super.pasteboardPropertyList(forType: type)
    }
}
