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
    private struct Candidate {
        let encoding: ArchiveNameEncoding
        let samples: [String]
    }

    /// Raise the chooser over `window`, calling `completion` with the chosen code page — or with
    /// `nil` when the user cancelled or when no offered code page fits this archive at all.
    ///
    /// Reads headers, on the main actor, once per candidate. That is bounded by the fact that
    /// sampling stops at the first few *non-ASCII* names, which an archive reaching this prompt has
    /// by construction — measured at 3–4 ms for a header read of a 600 MB archive, so the whole list
    /// costs well under a tenth of a second.
    @MainActor
    static func ask(
        forArchiveAt archivePath: String,
        over window: NSWindow?,
        completion: @escaping (ArchiveNameEncoding?) -> Void
    ) {
        let candidates = fittingCandidates(forArchiveAt: archivePath)
        guard !candidates.isEmpty else {
            completion(nil)
            return
        }

        let name = (archivePath as NSString).lastPathComponent
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
