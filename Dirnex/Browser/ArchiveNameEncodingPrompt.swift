import AppKit
import DirnexCore

/// Asking which code page a legacy archive's entry names are stored in.
///
/// A zip written before UTF-8 was usual records its names in an OEM code page and says nothing
/// about which one, so this is the one fact about such an archive that nothing on this machine can
/// work out (``DirnexCore/ArchiveNameEncoding``). Until it is answered the pane draws `���.txt`,
/// every verb built from that row addresses a member that is not there, and the rewrite refuses
/// outright — APFS will not accept a file name that is not valid UTF-8, so extract-edit-repack has
/// nowhere to put it.
///
/// **It is a chooser over a preview, not a detector.** A wrong code page does not fail: it produces
/// a well-formed name that is simply somebody else's language — and it can be *invisibly* wrong, as
/// CP1251 reads the CP866 fixture's separators as no-break spaces and soft hyphens. Nothing but a
/// person who can read the language can tell, which is why the samples are on screen and there is no
/// "detect" button.
///
/// Only the code pages that **fit** are offered. One that cannot represent a byte in this archive
/// makes libarchive answer NULL for the name, and that is a definite no rather than a guess — so it
/// is dropped from the list instead of being offered and then failing. That usually takes nineteen
/// candidates down to a handful.
enum ArchiveNameEncodingPrompt {
    /// One candidate and what the archive's names look like under it.
    private struct Candidate: Sendable {
        let encoding: ArchiveNameEncoding
        let samples: [String]
    }

    /// Raise the chooser over `window`, calling `completion` with the chosen code page — or with
    /// `nil` when the user cancelled or when no offered code page fits this archive at all.
    ///
    /// **The reads are off the main actor, and that is a measurement rather than caution.** This
    /// opened the archive once per candidate on the main actor, on the stated ground that sampling
    /// stops at the first few *non-ASCII* names — which an archive reaching this prompt has by
    /// construction, so the walk really is short. Measured 2026-09-09 against real CP866 fixtures,
    /// that bounds the wrong quantity: every candidate costs the same **~260 ms** on a
    /// 50 000-entry zip whether it bails at the first entry or samples at the fifth, because what
    /// it is paying for is the *open* — libarchive reading a five-megabyte central directory — and
    /// not the walk.
    ///
    /// | entries | all 19 candidates |
    /// |---|---|
    /// | 2 | 5 ms |
    /// | 1 000 | 81 ms |
    /// | 20 000 | 1.4 s |
    /// | 50 000 | 3.6 s (4.9 s with the non-ASCII names last) |
    ///
    /// On the main actor that is a beachball rather than a slow sheet. `BlockingWork.run` is the
    /// house answer for a blocking body — never `Task.detached`, which is the cooperative pool and
    /// would hold one of its workers for the whole read (docs/NOTES.md ▸ Swift 6 and concurrency).
    ///
    /// What is deliberately *not* done is the twenty-times-faster version: one open answers for
    /// every code page, since with no `hdrcharset` set `archive_entry_pathname` hands back the raw
    /// stored bytes verbatim while `archive_entry_pathname_utf8` answers NULL (probed against
    /// libarchive 3.7.4 — `hdrcharset=BINARY` is *not* available, `iconv_open` refuses it). Those
    /// bytes could then be decoded nineteen ways in-process. It is refused because it would
    /// introduce a **second decoder**: the preview would come from CoreFoundation and the listing
    /// from libarchive's iconv, and where the two disagree the sheet would show a name the archive
    /// will not open under. A preview whose whole job is to be recognised has to be produced by the
    /// reader that will do the reading.
    @MainActor
    static func ask(
        forArchiveAt archivePath: String,
        over window: NSWindow?,
        completion: @escaping (ArchiveNameEncoding?) -> Void
    ) {
        let name = (archivePath as NSString).lastPathComponent
        Task { @MainActor in
            let candidates = await BlockingWork.run { fittingCandidates(forArchiveAt: archivePath) }
            present(candidates, archiveNamed: name, over: window, completion: completion)
        }
    }

    /// Put the chooser on screen, or say that there is nothing to offer.
    ///
    /// Split from `ask` only because the reads now happen in between; everything here is the same
    /// main-actor work it always was.
    @MainActor
    private static func present(
        _ candidates: [Candidate],
        archiveNamed name: String,
        over window: NSWindow?,
        completion: @escaping (ArchiveNameEncoding?) -> Void
    ) {
        guard !candidates.isEmpty else {
            // Somebody asked and there is nothing to offer, so saying nothing is not available: from
            // the File menu that is a command that does nothing when clicked, and from a refusal it
            // is a gesture that failed in silence, since `offerNameEncoding` has by then told its
            // caller to report nothing further. Reported here rather than at either call site
            // because both want the same sentence.
            reportNothingFits(archiveNamed: name, over: window)
            completion(nil)
            return
        }

        let alert = NSAlert()
        alert.messageText = String(
            localized: "The names in “\(name)” aren’t Unicode",
            comment: "Title of the archive name-encoding chooser; %@ is the archive's name."
        )
        alert.informativeText = String(
            localized: """
            This archive stores its file names in a code page rather than Unicode, and doesn’t \
            record which one. Choose the one that makes the names below readable.
            """,
            comment: "Body of the archive name-encoding chooser."
        )
        alert.addButton(withTitle: String(
            localized: "Use",
            comment: "Button that accepts the chosen code page for an archive's names."
        ))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))
        // `NSAlert` binds Escape by matching the byte string "Cancel", so a translated button gets
        // no key equivalent at all (docs/NOTES.md ▸ Localization).
        alert.enableEscapeToCancel(safe: .alertSecondButtonReturn)

        let accessory = Accessory(candidates: candidates)
        alert.accessoryView = accessory.view

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }
            completion(accessory.selectedEncoding)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            // A gesture somebody made and is waiting on, so the window-less fallback stays — see
            // docs/NOTES.md ▸ Testing, "who is waiting?".
            finish(alert.runModal())
        }
    }

    /// Say that no offered code page can read this archive's names.
    ///
    /// Reachable in practice only when libarchive cannot read the archive **at all**, which is why
    /// the sentence does not blame the encoding: CP437 and Mac OS Roman map all 256 byte values, so
    /// a file whose headers can be read always has at least those two candidates. Both causes are
    /// indistinguishable from here, so neither is asserted.
    @MainActor
    private static func reportNothingFits(archiveNamed name: String, over window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Dirnex couldn’t read the names in “\(name)”",
            comment: """
            Title of the alert shown when no offered code page can read an archive's file names; \
            %@ is the archive's name.
            """
        )
        alert.informativeText = String(
            localized: """
            None of the code pages Dirnex offers can represent them. The archive may be damaged, \
            or its names may be stored in an encoding Dirnex doesn’t know.
            """,
            comment: "Body of the alert shown when no offered code page can read an archive's names."
        )
        alert.enableEscapeToCancel(safe: .alertFirstButtonReturn)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// The offered code pages that can actually represent this archive's names, each with its
    /// samples. Order follows ``ArchiveNameEncoding/allCases``, which groups by script family.
    private static func fittingCandidates(forArchiveAt archivePath: String) -> [Candidate] {
        ArchiveNameEncoding.allCases.compactMap { encoding in
            guard let samples = try? EncryptedArchiveReader.nameSamples(
                archiveAt: archivePath, encoding: encoding
            ), !samples.isEmpty else { return nil }
            return Candidate(encoding: encoding, samples: samples)
        }
    }

    /// The popup and its live preview, kept as an object so the popup's action has somewhere to live
    /// for as long as the sheet is up.
    @MainActor
    private final class Accessory: NSObject {
        private let candidates: [Candidate]
        private let popup = NSPopUpButton(frame: NSRect(x: 0, y: 40, width: 340, height: 25))
        private let preview = NSTextField(wrappingLabelWithString: "")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 74))

        var selectedEncoding: ArchiveNameEncoding {
            candidates[popup.indexOfSelectedItem].encoding
        }

        init(candidates: [Candidate]) {
            self.candidates = candidates
            super.init()

            popup.addItems(withTitles: candidates.map {
                L10n.string($0.encoding.localizationKey, fallback: $0.encoding.englishName)
            })
            popup.target = self
            popup.action = #selector(selectionChanged)

            // A wrapping label with no width of its own does not wrap, it *overruns* (docs/NOTES.md
            // ▸ Localization), so the frame is set here and the line count capped — the accessory's
            // height is read from its frame, and a preview that grew would push the alert about.
            preview.frame = NSRect(x: 0, y: 0, width: 340, height: 34)
            preview.maximumNumberOfLines = 2
            preview.lineBreakMode = .byTruncatingTail
            preview.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            preview.textColor = .secondaryLabelColor

            view.addSubview(popup)
            view.addSubview(preview)
            updatePreview()
        }

        @objc private func selectionChanged() { updatePreview() }

        private func updatePreview() {
            preview.stringValue = candidates[popup.indexOfSelectedItem]
                .samples
                .joined(separator: "   ")
        }
    }
}
