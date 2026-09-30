import AppKit
import DirnexCore

/// Fulfilling a promise another application accepted — the second half of dragging a file off a
/// server into Finder, Mail or Teams (PLAN.md §M23 Slice 4).
///
/// The pane is the delegate rather than an object of its own, for the reason the property is
/// declared `weak`: whatever fulfils a promise has to outlive the drag, and a drag can be let go
/// long after the row that started it has scrolled away. A pane does; a per-drag helper would need
/// somebody to hold it, which is a lifetime nobody would notice getting wrong until a promise
/// silently resolved to nothing.
///
/// **This runs outside the queue bar**, which is what makes it different from every other transfer
/// in the app. There is no `FileOperation`, no Stop button in the toolbar and no per-item report,
/// because the receiving app owns the destination and is blocked waiting on us — so the two things a
/// queued job would have provided are supplied here instead: `RemoteFetchPrompt`'s deferred sheet
/// carries the bar and the Stop, and the completion handler carries the outcome. Answering it is not
/// optional on any path. A promise left unanswered is a beachball in somebody else's app; a promise
/// answered with `nil` after a failed transfer is a **zero-byte file** under the right name, which
/// is worse than an error because nothing anywhere says the bytes are missing.
extension PanelViewController: NSFilePromiseProviderDelegate {
    /// What the file will be called where it lands. Asked before anything is fetched, which is why
    /// the name comes off the snapshot the drag was started with rather than from a fresh listing.
    ///
    /// The receiving app is free to disambiguate a collision itself (Finder appends a counter), so
    /// this is the *requested* name, not a promise about the final one.
    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        (filePromiseProvider as? RemoteFilePromiseProvider)?.entry?.name ?? "file"
    }

    /// Put the bytes at `url` and say how it went.
    ///
    /// `nonisolated` because the requirement is (`NS_SWIFT_NONISOLATED`), while the queue it is
    /// issued from is the **main** one — `operationQueueForFilePromiseProvider` is deliberately not
    /// implemented, and AppKit's documented default is `mainOperationQueue`. So the hop below is
    /// almost always a no-op; it is written as a funnel rather than an `assumeIsolated` on its own
    /// because the isolation is the *requirement's*, and nothing here should depend on a default
    /// that lives in another framework's header.
    ///
    /// The fetch itself is async and does its blocking work off the main actor, so returning at once
    /// leaves nothing on the main thread waiting for a network round trip.
    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping @Sendable ((any Error)?) -> Void
    ) {
        // The **row** crosses to the main actor, never the provider: `NSFilePromiseProvider` is not
        // `Sendable` (Swift 6 refuses to send it), while a `FileEntry` is a value and is exactly what
        // the fetch needs. So the translation from one to the other happens here, on whichever thread
        // AppKit called us on, and only the snapshot travels.
        let entry = (filePromiseProvider as? RemoteFilePromiseProvider)?.entry
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                fulfillPromise(entry, writingTo: url, then: completionHandler)
            }
        } else {
            Task { @MainActor in
                fulfillPromise(entry, writingTo: url, then: completionHandler)
            }
        }
    }

    private func fulfillPromise(
        _ row: FileEntry?,
        writingTo url: URL,
        then completionHandler: @escaping @Sendable ((any Error)?) -> Void
    ) {
        guard let entry = row else {
            // Unreachable: only `RemoteFilePromiseProvider.promise` builds one of these, and it
            // always carries its row. Answered rather than dropped, with a stock Cocoa error and no
            // invented sentence of our own — the receiving app words this, not Dirnex.
            completionHandler(CocoaError(.fileReadUnknown))
            return
        }
        fulfillRemotePromise(for: entry) { source in
            completionHandler(Self.place(source, at: url))
        } onEnded: { error in
            // Only a *failure* answers here: success and cancellation are both settled by the
            // branch above, which is the one that knows whether the bytes made it to `url`.
            guard let error else { return }
            completionHandler(error)
        }
    }

    /// Copy the fetched file into the destination the receiving app chose.
    ///
    /// A copy rather than a move, because the fetched file is the *cache's* — an editor may have it
    /// open, and a later drag of the same row must not have to fetch it again. On APFS
    /// `copyItem(at:to:)` clones, so the second copy of the bytes costs metadata rather than the
    /// file, which is what makes reusing the cache the cheap answer as well as the correct one.
    ///
    /// `url` is created by the promise machinery, so an existing file there is ours to replace: a
    /// stale zero-byte placeholder left by an earlier attempt would otherwise fail the copy and
    /// report the wrong thing entirely.
    private nonisolated static func place(_ source: URL, at url: URL) -> (any Error)? {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: source, to: url)
            return nil
        } catch {
            return error
        }
    }
}
