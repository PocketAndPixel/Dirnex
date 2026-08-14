import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The pane's status line **tail-truncates**, so a sentence too wide for it loses its own ending
/// (PLAN.md §M21 Slice 11).
///
/// `statusLabel` is `.byTruncatingTail` with `.defaultLow` horizontal compression resistance —
/// deliberately, so a long type-to-filter string cannot shove the split divider across. The cost of
/// that correct decision is that an over-long *sentence* fails silently and in the worst possible
/// place: what goes missing is the tail, which in an explanatory sentence is the explanation. There
/// is no Auto Layout complaint, nothing logs, both suites stay green, and an English screenshot of a
/// short folder name looks perfect.
///
/// Slice 11's give-up sentence shipped its first draft that way — **557 pt in English and 713 pt
/// in Russian** against a pane measured at **542 pt**, so it clipped in 10 of 14 languages, leaving
/// `Stopped measuring “x” — it holds more folders than Dirnex will…` on screen: the half stating
/// *why* was exactly the half cut.
///
/// **How the width was established is the other half of the lesson, because two ways of getting it
/// were wrong first.** Subtracting an assumed sidebar from the window frame gave 532 — close, and
/// arrived at by exactly the derivation docs/NOTES.md ▸ Live verification forbids. Reading
/// `statusLabel.frame.width` in the running app then gave *409.5*, which looked like the
/// correction and was worse: the label is sized to its own text, so that number is the **sentence**
/// plus 3.5 pt of padding and says nothing whatever about the constraint. What answers the question
/// is the enclosing stack's width (542 pt) and, better, `NSCell.expansionFrame(withFrame:in:)` —
/// AppKit's own "is this truncated", asked of the real label in the real pane. Probed that way, the
/// first draft truncates and every candidate at ~496 pt and below does not.
///
/// The residual is the *folder name*, which is unbounded: 40 characters puts even the shortened
/// English at 468 pt and a longer one past the pane whatever the wording. So truncation here is
/// made unlikely, never impossible — which is why the explanation itself lives in a tooltip
/// (`FileFormatting.sizeToolTip`) and only a short note lives on this line.
///
/// This is the docs/NOTES.md ▸ Localization family — the pack sheet's fixed label column, the sync
/// sheet's crushed segmented control, the recorder pill's overrun placeholder — arriving on the one
/// surface that is on screen at all times.
@Suite("Status-line sentence widths")
struct StatusSentenceWidthTests {
    /// The widest a status sentence may render, over every language it ships in.
    ///
    /// **400 pt against a pane measured at 542**, and the headroom is the point rather than slack.
    ///
    /// The obvious budget is the pane itself, and it is the wrong one: it would pass a sentence
    /// that fits *this* sample folder name and truncates the moment someone's folder is called
    /// something longer. 400 leaves ~140 pt — roughly 20 more characters of name — before the line
    /// is in danger at all, which is what makes the check about the **sentence** rather than about
    /// the fixture. The worst translation currently measures 350 pt (Russian).
    ///
    /// Keying it to a *precedent* was the other tempting answer and is worse: the longest sentence
    /// already on this line measures 513 pt in German, so a precedent budget would license a
    /// sentence with no room for a name at all. That an existing string is close to the edge is a
    /// reason to know about it, not a licence to add another.
    static let budget: CGFloat = 400

    /// The give-up sentence, keyed by its English text as every app-side literal is.
    static let giveUpKey = "Stopped measuring “%@” — too many folders."

    /// The tooltip that carries what the status line cannot.
    static let toolTipKey = "Measuring stopped: this folder holds more folders than Dirnex "
        + "counts over a network connection. Press Space to try again."

    /// Measured through the class that draws it, configured as `PanelViewController` configures it.
    ///
    /// A label's `intrinsicContentSize` is a usable measure and needs no window (docs/NOTES.md ▸
    /// Localization) — unlike an *editable* field's, which reports `noIntrinsicMetric`, and unlike
    /// `NSButtonCell.titleRect(forBounds:)`, which reports the bounds unchanged.
    private func width(_ text: String) -> CGFloat {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return ceil(field.intrinsicContentSize.width)
    }

    /// Every shipped translation of `key`, read from the **compiled** `.strings` in the app bundle
    /// rather than from `Localizable.xcstrings`.
    ///
    /// The catalog is the source and the bundle is what runs, and they are not the same claim: an
    /// entry can be in the catalog and absent from the build. Read as a *dictionary* and looked up
    /// by key, which also sidesteps `plutil -extract`'s dotted-key trap — irrelevant for a key
    /// spelled in English text, and the habit is what makes it irrelevant.
    private func translations(of key: String) -> [(language: String, text: String)] {
        let bundle = Bundle(for: PanelViewController.self)
        let lprojs = bundle.paths(forResourcesOfType: "lproj", inDirectory: nil)
        var found: [(language: String, text: String)] = []
        for lproj in lprojs {
            let language = (lproj as NSString).lastPathComponent
                .replacingOccurrences(of: ".lproj", with: "")
            let table = (lproj as NSString).appendingPathComponent("Localizable.strings")
            guard let strings = NSDictionary(contentsOfFile: table) as? [String: String],
                  let value = strings[key] else { continue }
            found.append((language, value))
        }
        return found.sorted { $0.language < $1.language }
    }

    /// A folder name long enough to be ordinary and short enough not to be the thing under test.
    ///
    /// The sentence has to fit around a real name, not around an empty one — and the name is the
    /// one term here that is genuinely **unbounded**: measured, a 40-character folder puts even the
    /// shortened English sentence at 468 pt, past any budget this line could have. So what is
    /// pinned is the sentence's own cost around an ordinary name; the unbounded case is answered by
    /// moving the explanation to the tooltip, not by a number.
    private static let sampleName = "sizerprobe"

    private static func entry(at path: VFSPath, kind: FileEntry.Kind) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: kind,
            byteSize: kind == .file ? 1 : 0,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o755,
            inode: 0
        )
    }

    private static func folder() -> FileEntry { entry(at: .local("/tmp/dir"), kind: .directory) }
    private static func file() -> FileEntry { entry(at: .local("/tmp/f.txt"), kind: .file) }

    @Test("the give-up sentence fits the status line in every language it ships in")
    func giveUpSentenceFits() throws {
        let all = translations(of: Self.giveUpKey)
        // A key absent from every compiled bundle would make this suite pass by measuring nothing —
        // the same "a check that cannot see its subject is not a check" shape the localization
        // sweep is built around.
        try #require(!all.isEmpty, "no compiled translation of the give-up sentence was found")
        #expect(all.count >= 14, "expected all 14 shipped languages, found \(all.count)")

        var over: [String] = []
        for (language, text) in all {
            let rendered = text.replacingOccurrences(of: "%@", with: Self.sampleName)
            let measured = width(rendered)
            if measured > Self.budget {
                over.append("\(language) \(Int(measured)) pt")
            }
        }
        #expect(
            over.isEmpty,
            "over the \(Int(Self.budget)) pt status budget: \(over.joined(separator: ", "))"
        )
    }

    @Test("every translation keeps the folder name's placeholder")
    func giveUpSentenceKeepsItsArgument() throws {
        let all = translations(of: Self.giveUpKey)
        try #require(!all.isEmpty)
        for (language, text) in all {
            // A translation that drops the `%@` silently swallows the folder the sentence is about,
            // leaving a message that names nothing — and it is the give-up marker's only prose.
            #expect(
                text.components(separatedBy: "%@").count == 2,
                "\(language) does not carry exactly one %@: \(text)"
            )
        }
    }

    /// The negative control: the budget must be able to *fail*.
    ///
    /// Without this, shortening the sentence to two words would leave the suite green while proving
    /// nothing — and so would a `budget` accidentally set to `.greatestFiniteMagnitude`. The string
    /// measured is the first draft's own English, the one that actually clipped on screen.
    @Test("the budget rejects the draft that clipped")
    func budgetRejectsTheOverlongDraft() {
        let draft = "Stopped measuring “\(Self.sampleName)” — it holds more folders "
            + "than Dirnex will count over a network connection."
        #expect(width(draft) > Self.budget)
    }

    /// The name is the unbounded term, so pin what that costs rather than leaving it in prose.
    ///
    /// Not a failure — an ordinary long folder name genuinely can push this line past the pane, and
    /// no wording prevents it. The assertion exists so that the day someone tightens `budget`
    /// towards the pane's own width, this states out loud what such a budget would not be buying.
    @Test("a long folder name outruns the line whatever the sentence says")
    func aLongNameOutrunsTheLine() {
        let long = String(repeating: "a", count: 40)
        let rendered = "Stopped measuring “\(long)” — too many folders."
        #expect(width(rendered) > Self.budget)
    }

    /// The tooltip must exist in every language, because it is where the explanation went.
    ///
    /// Deliberately *not* width-checked: a tooltip wraps and is not in a column, which is the whole
    /// reason the prose was moved into it. What matters is that it is there — a missing translation
    /// would leave the `?` explained in English inside a translated build, and the glyph is
    /// otherwise a symbol nobody has been taught.
    @Test("the give-up tooltip ships in every language")
    func toolTipIsTranslatedEverywhere() throws {
        let all = translations(of: Self.toolTipKey)
        try #require(!all.isEmpty, "no compiled translation of the give-up tooltip was found")
        #expect(all.count >= 14, "expected all 14 shipped languages, found \(all.count)")
    }

    /// The row's own explanation is offered exactly when the marker is, and withdrawn otherwise.
    ///
    /// The withdrawal is the half worth pinning: a size cell comes out of the same reuse pool as
    /// every other one, so a tooltip that is set but never cleared rides a recycled cell onto a row
    /// it says nothing true about (docs/NOTES.md ▸ AppKit, the synthesized `..` row).
    @Test("only a folder that gave up carries a tooltip")
    @MainActor
    func toolTipTracksTheState() {
        let folder = Self.folder()
        #expect(FileFormatting.sizeToolTip(for: folder, state: .gaveUp) != nil)
        #expect(FileFormatting.sizeToolTip(for: folder, state: .idle) == nil)
        #expect(FileFormatting.sizeToolTip(for: folder, state: .measuring) == nil)
        // A *file* never gives up, because it is never walked.
        #expect(FileFormatting.sizeToolTip(for: Self.file(), state: .gaveUp) == nil)
    }
}
