import AppKit
import DirnexCore

/// The code page a legacy archive's names are stored in — asked for once per archive, either by
/// whichever gesture first cannot proceed without it or by the user, from the File menu.
///
/// The shape is `withArchivePassphrase`'s and for the same reason: several gestures need the same
/// answer about the same archive, and written out at each of them the "ask again, then re-list" pair
/// is several places for one of them to be forgotten. The difference is *when* it is asked. A
/// passphrase is wanted the moment bytes are; a code page is wanted the moment a **name** is, which
/// is earlier — so an archive that needs one is already drawing `���.txt` before any gesture fails.
///
/// **Nothing here asks unprompted.** Entering such an archive lists it, wrongly but harmlessly, and
/// the offer arrives only when the user asks for it or when a gesture they made hits the refusal —
/// the same separation docs/NOTES.md draws for Quick View's JavaScript switch, between "is this
/// safe" and "should this happen unasked". A passive preview that mounted the archive must never
/// raise this sheet.
///
/// The menu item is what the refusal alone could not offer: until it existed the chooser was
/// reachable only by *failing* at something, so somebody who merely wanted to **read** the names had
/// no route at all (PLAN.md §M27). A prompt on navigation would have been the other way to close
/// that, and is the thing docs/NOTES.md keeps warning about — a sheet raised by a gesture nobody
/// made.
///
/// **Every gesture that asks for a member's bytes offers it, not only the three writes that shipped
/// with it.** A member of an undeclared legacy archive is looked for under the name the pane drew —
/// `\217\255…`, which no entry is called — so `bsdtar` places nothing, `ArchiveExtractor` asks why,
/// and the refusal reaches whoever asked. That is one funnel per gesture and there are seven of
/// them: ⏎ and F4 (`+ArchiveOpen`), ⏎ into a nested archive (`+NestedArchive`), ⌘Y and ⌃Q
/// (`+ArchivePreview`), the hand-offs that stage members first — Open With, Share, checksum,
/// compare, ⌥F5 pack (`+Materialize`) — and the three writes, F5 copy-out (`+ArchiveExtract`), F8
/// delete (`+ArchiveWrite`) and paste (`+ArchiveAdd`). Reported by a user 2026-09-10: the chooser
/// existed and only a copy could reach it, so opening or previewing a row said *"Couldn't open this
/// item"* — true, useless, and naming the wrong thing, since the archive is fine and only its code
/// page is unknown.
///
/// The one deliberate silence is `prepareArchivePreview`, the preview that follows the **cursor**.
/// It reaches the identical refusal on every arrow key and must go on saying nothing: a sheet raised
/// because the cursor came to rest somewhere is the question nobody asked (docs/NOTES.md ▸ Design
/// lessons, the credential-shaped split). ⌃Q turning the mode *on* is the gesture, and it asks.
extension PanelViewController {
    /// The code page declared for `archivePath` this session, if any. Every read of a browsed
    /// archive passes this along, so one answer reaches the listing, the previews, an extraction and
    /// the rewrite alike.
    func declaredNameEncoding(forArchiveAt archivePath: String) -> ArchiveNameEncoding? {
        (backend as? CompositeBackend)?.nameEncoding(forArchiveAt: archivePath)
    }

    /// The archive this pane is inside whose names the chooser has something to say about, or `nil`
    /// where the question does not arise.
    ///
    /// Two states qualify, and the second is the one that is easy to leave out. **Names that did not
    /// decode** is the reported case — the pane is drawing rows nobody can use. **A declaration
    /// already in force** is the other, because a wrong pick costs a second pick and a code page can
    /// be *invisibly* wrong: CP1251 reads the CP866 fixture's separators as no-break spaces and soft
    /// hyphens, so the names look plausible and no refusal will ever be raised to offer the chooser
    /// again. Gated on the unreadable half alone, changing your mind would be impossible.
    ///
    /// Asked of the **archive** rather than of the directory the cursor is in, since one declaration
    /// covers the whole file: a folder inside it whose own rows happen to be ASCII must not read as
    /// an archive with nothing wrong with it.
    ///
    /// Internal, and read by the *action* as well as by `validateMenuItem`, because two hand-written
    /// copies of one rule is how a working command ends up grayed out and a gray one ends up
    /// running — docs/NOTES.md's most repeated family, and `canRenameHere`'s own reason for
    /// existing.
    var archiveAwaitingNameEncoding: String? {
        guard let composite = backend as? CompositeBackend,
              let archivePath = panel.path.backend.archivePath
        else { return nil }
        let unresolved = composite.nameEncoding(forArchiveAt: archivePath) != nil
            || composite.mountedArchiveHasUnreadableNames(forArchiveAt: archivePath)
        return unresolved ? archivePath : nil
    }

    /// Ask which code page this archive's names are in — the File menu's route to the chooser.
    @objc func chooseArchiveNameEncoding(_ sender: Any?) {
        guard let archivePath = archiveAwaitingNameEncoding else { return }
        askForNameEncoding(forArchiveAt: archivePath)
    }

    /// Whether `error` is an archive refusing to be read because its names are not UTF-8.
    ///
    /// Matched on the case rather than on a message: it travels as itself out of
    /// `EncryptedArchiveReader.inspect`, which every write path calls before it touches anything, so
    /// the refusal arrives before the archive has been altered in any way.
    ///
    /// `nonisolated static` because it is a fact about the *error* and not about a pane — which is
    /// what lets `ArchiveExtractor` ask it off the main actor, and what lets a test assert a refusal
    /// through the app's own predicate rather than through a second copy of it.
    nonisolated static func isNameEncodingRefusal(_ error: Error) -> Bool {
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
        guard Self.isNameEncodingRefusal(error) else { return false }
        askForNameEncoding(forArchiveAt: archivePath)
        return true
    }

    /// Raise the chooser and, on an answer, declare the code page and re-list the pane.
    ///
    /// One funnel for both ways in, so the answer can only ever be acted on one way. The selection
    /// is cleared first because the marks were made against names that are about to change; keeping
    /// them would hand the next gesture a set the user never chose.
    private func askForNameEncoding(forArchiveAt archivePath: String) {
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
    }
}
