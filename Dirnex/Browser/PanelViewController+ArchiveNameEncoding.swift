import AppKit
import DirnexCore

/// The code page a legacy archive's names are stored in — asked for once per archive, by whichever
/// gesture first cannot proceed without it.
///
/// The shape is `withArchivePassphrase`'s and for the same reason: several gestures need the same
/// answer about the same archive, and written out at each of them the "ask again, then re-list" pair
/// is several places for one of them to be forgotten. The difference is *when* it is asked. A
/// passphrase is wanted the moment bytes are; a code page is wanted the moment a **name** is, which
/// is earlier — so an archive that needs one is already drawing `���.txt` before any gesture fails.
///
/// **Nothing here asks unprompted.** Entering such an archive lists it, wrongly but harmlessly, and
/// the offer arrives only when a gesture the user made hits the refusal — the same separation
/// docs/NOTES.md draws for Quick View's JavaScript switch, between "is this safe" and "should this
/// happen unasked". A passive preview that mounted the archive must never raise this sheet.
extension PanelViewController {
    /// The code page declared for `archivePath` this session, if any. Every read of a browsed
    /// archive passes this along, so one answer reaches the listing, the previews, an extraction and
    /// the rewrite alike.
    func declaredNameEncoding(forArchiveAt archivePath: String) -> ArchiveNameEncoding? {
        (backend as? CompositeBackend)?.nameEncoding(forArchiveAt: archivePath)
    }

    /// Whether `error` is an archive refusing to be read because its names are not UTF-8.
    ///
    /// Matched on the case rather than on a message: it travels as itself out of
    /// `EncryptedArchiveReader.inspect`, which every write path calls before it touches anything, so
    /// the refusal arrives before the archive has been altered in any way.
    func isNameEncodingRefusal(_ error: Error) -> Bool {
        if case .entryNameNotUTF8 = error as? EncryptedArchiveError { return true }
        return false
    }

    /// If `error` is that refusal, offer the chooser and — on an answer — declare the code page and
    /// re-list. Returns `true` when it has taken responsibility for the error, so the caller reports
    /// nothing further.
    ///
    /// The gesture is deliberately **not** retried afterwards. Its targets were rows named from a
    /// listing nobody could read, and re-running it against names that have just changed would be
    /// acting on a stale selection — the trap docs/NOTES.md records for every other refresh. The
    /// pane comes back with readable names and the user presses the key again, on a row they can
    /// now see.
    @discardableResult
    func offerNameEncoding(after error: Error, forArchiveAt archivePath: String) -> Bool {
        guard isNameEncodingRefusal(error) else { return false }
        ArchiveNameEncodingPrompt.ask(
            forArchiveAt: archivePath, over: view.window
        ) { [weak self] encoding in
            guard let self, let encoding else { return }
            (backend as? CompositeBackend)?.declareNameEncoding(
                encoding, forArchiveAt: archivePath
            )
            panel.clearSelection()
            refreshArchiveDirectory()
            focusTable()
        }
        return true
    }
}
