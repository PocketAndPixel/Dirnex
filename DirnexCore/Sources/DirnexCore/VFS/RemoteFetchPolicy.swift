import Foundation

/// Why a remote file's bytes are about to be pulled down — one case per gesture that can ask for
/// them (PLAN.md §M21 Slice 10, widened to a set of files at §M24 Slice 1).
///
/// All but one are a **key somebody pressed**. The exception, ``cursorPreview``, is the preview mode
/// following the cursor with no key pressed for *this* file, and it is the one that changes what a
/// refusal may look like: there is nobody standing at a keystroke to answer a dialog, so an
/// automatic fetch that is too big must stand down silently rather than ask (see
/// ``RemoteFetchDecision/decline``). Same fork as Quick View's JavaScript switch and
/// Enter-vs-Unlock — "is this safe" and "should this happen unasked" are different questions — with
/// the size table answering the first and ``isAutomatic`` the second.
///
/// **A case per gesture, even where several share a row of the table.** Most of M24's do, and the
/// cases exist anyway for the one thing a shared constant cannot buy: `threshold(for:previewLimit:)`
/// switches exhaustively, so the next gesture that learns to fetch cannot reach a number by
/// inheriting one — somebody has to put it in a row and say which argument it belongs to. That is
/// the whole mechanism keeping "a new gesture is a line in the table" from becoming "a new gesture
/// is a constant at its call site", which is what this table was extracted to prevent.
public enum RemoteFetchPurpose: Sendable, Equatable, CaseIterable {
    /// The preview surface following the cursor, at any Quick View size or in the ⌘Y panel: nobody
    /// pressed a key for *this* file, the mode being on is the standing request.
    case cursorPreview
    /// ⌘Y / ⌃Q / F3 on a remote row: show me what is in this.
    case preview
    /// ⏎ on a remote row: open it in whatever owns the type.
    case open
    /// F4 on a remote row: open it in the text editor, and offer to write the save back.
    case edit
    /// Open With… or the Share sheet over the selection: hand these files to another application.
    ///
    /// One case for both verbs, because they are one act — `handoffTargets` is literally one helper
    /// serving both — and the question the size decides is the same either way: this much is coming
    /// down before anything happens. That Share then pushes the bytes somewhere else again is a fact
    /// about what the *other* application does with them.
    case handOff
    /// ⌥F3 Compare By Contents: two files, read end to end, and the verdict is all that is kept.
    case compare
    /// The Synchronize sheet comparing two trees by contents: every same-size pair the walk found,
    /// on whichever side is not on this disk.
    ///
    /// Its own case rather than ``compare``'s, though it shares that row of the table, because the
    /// two differ in the one dimension a size threshold cannot see: ⌥F3 is two files somebody put
    /// under the cursors and this is however many pairs two trees happen to hold. What answers that
    /// is ``RemoteFetchPolicy/unaskedRequestLimit``, which every purpose already shares — so what
    /// the separate case buys is that the number was *chosen* for this gesture rather than
    /// inherited by whoever wrote the call site.
    case syncContents
    /// A checksum run over the marked set — created or verified.
    case checksum
    /// A user script, over whatever the user marked.
    case userScript
    /// ⌥F5 Pack, where the *sources* are not on this disk and have to be staged before `bsdtar`
    /// can see them.
    case pack
    /// Entering an archive that lives on a server: `ArchiveBackend` needs a real path, so browsing
    /// one is fetch-the-whole-file-then-mount.
    ///
    /// The gesture is ⏎, which everywhere else in this app means *navigate* and has never cost
    /// anything — so this is the case whose confirmation has to say that the whole file is coming
    /// down, in those words. It shares the explicit row rather than taking a lower number of its
    /// own: the sentence is what makes the gesture honest, and lowering the *threshold* instead
    /// would quietly widen what the Settings preview limit governs (see the table below).
    case browseArchive

    /// Whether this fetch happens without anybody having pressed a key for the file in question.
    ///
    /// Named rather than spelled `== .cursorPreview` at the one site that reads it, because what it
    /// decides is not "is this case special" but "is there someone to ask" — and a second automatic
    /// gesture added later must inherit that answer rather than a comparison somebody has to find.
    public var isAutomatic: Bool { self == .cursorPreview }
}

/// Whether a fetch is small enough to just happen.
public enum RemoteFetchDecision: Sendable, Equatable {
    /// Start the transfer. The progress sheet still appears if it takes long enough.
    case fetch
    /// Ask first, naming the size.
    case confirm
    /// Don't fetch, and don't ask either — the answer for an automatic gesture over its threshold.
    ///
    /// Distinct from ``confirm`` because a dialog is itself something that must not happen unasked:
    /// raising one because the cursor came to rest on a large row is a question nobody invited, on a
    /// keystroke. The caller leaves its placeholder up instead, which already names the file and its
    /// size and carries the button that asks properly.
    case decline
}

/// When an explicit remote fetch is big enough to confirm before it starts.
///
/// A table rather than a constant at a call site, for the reason the multipart threshold is one:
/// these are **policy numbers, not measurements**, and policy numbers buried at the place they are
/// used get copied, drift apart, and can never be re-measured because nobody can find them all.
/// Ten gestures reach this and they land on two rows, because the thing that actually varies is not
/// the gesture but how *committed* it is — so the table is the feature, the rows are the arguments,
/// and the numbers in them are the part expected to move.
///
/// What the thresholds are arguing, in the order they were chosen:
///
/// - **Preview is the lowest**, because it is the least committed gesture and the most expensive to
///   get wrong. Every renderer behind it holds the whole file in memory, and "I wanted to see what
///   this was" is not worth a 40-second wait for bytes the user is about to discard.
/// - **Open and edit sit at 64 MiB**, matching `S3MultipartPlan`'s threshold — which is this
///   project's existing statement of where a transfer stops feeling instant, arrived at for a
///   different reason (a retry unit and a progress counter) and worth reusing rather than
///   re-inventing a second number that means the same thing.
/// - **Edit is not lower than open** even though a text editor suffers on a large file sooner than
///   Preview does, because the file the user pressed F4 on is one they intend to *change*, and
///   confirming that is a dialog in front of the work rather than in front of a look.
///
/// - **Everything M24 added sits on the open/edit row**, and that is a decision rather than a
///   default. Hand off, compare, checksum, a user script, a pack and browsing a remote archive are
///   all "somebody pressed a key naming these files", which is the same commitment ⏎ and F4 carry —
///   and M25's content sync joined them for the same reason. Six new constants a few megabytes apart
///   would each mean *approximately* 64 MiB and would drift apart on the first visit anybody paid to
///   one of them. Where those gestures genuinely differ
///   from ⏎ is not in how much is worth moving but in **how many things** are moving, and that is
///   ``unaskedRequestLimit`` — a second rule, not a second table.
///
/// The unknown-size row is the one that is not a number at all, and is the least arguable: not
/// knowing how much is about to be pulled is exactly when to ask.
///
/// ``RemoteFetchPurpose/cursorPreview`` shares Preview's number rather than minting a lower one of
/// its own, which is the same argument the paragraph above makes for open and edit: the two are the
/// *same act* — put this file on the preview surface — so a second constant a few megabytes apart
/// would mean nearly the same thing and would drift. What differs is not how much is worth fetching
/// but what happens when it is too much, and that is the ``RemoteFetchDecision/decline`` row rather
/// than a threshold.
///
/// **The preview row is the one number here the user owns** (Settings ▸ Panels), because it is the
/// only one whose right value is a fact about *their* files and *their* connection rather than about
/// the gesture: somebody whose photographs run to 300 MB is asking a reasonable question of a
/// preview, and somebody on a metered link is right to want none of it. So it arrives as a
/// parameter, and the rest of the table is expressed against it — open and edit stay at 64 MiB but
/// never below the preview limit, because "previewing this is fine, opening it must be confirmed"
/// is a contradiction the ordering below is written to prevent.
public enum RemoteFetchPolicy {
    /// What the preview limit is until somebody changes it.
    ///
    /// 10 MB in the decimal sense the Settings field shows, not 10 MiB: this is a number a user
    /// types and compares against the sizes their file list is already displaying, and quietly
    /// meaning something 4.9 % larger than what they typed is the kind of dishonesty nobody would
    /// ever catch.
    public static let defaultPreviewLimit: Int64 = 10 * 1_000_000

    /// The band the Settings field offers, in bytes. Zero is a real setting and the reason the range
    /// starts there — "never download a preview I did not ask for" is the honest answer on a metered
    /// connection, and it is exactly the behaviour Quick View had before the limit existed.
    public static let previewLimitRange: ClosedRange<Int64> = 0...(4096 * 1_000_000)

    /// `bytes` brought inside ``previewLimitRange``. One place, so a value typed into Settings, one
    /// restored from a defaults domain somebody hand-edited, and one carried over from an older
    /// build cannot disagree about what is allowed.
    public static func clampedPreviewLimit(_ bytes: Int64) -> Int64 {
        min(max(bytes, previewLimitRange.lowerBound), previewLimitRange.upperBound)
    }

    /// The size at or below which `purpose` fetches without asking, given the user's preview limit.
    public static func threshold(for purpose: RemoteFetchPurpose, previewLimit: Int64) -> Int64 {
        let limit = clampedPreviewLimit(previewLimit)
        return switch purpose {
        case .cursorPreview, .preview: limit
        // Never below the preview limit: a user who has said a 300 MB preview is fine has answered
        // the smaller question too, and confirming an *open* they would not be asked about for a
        // mere look is the ordering this table exists to keep straight.
        case .open, .edit,
             .handOff, .compare, .syncContents, .checksum, .userScript, .pack, .browseArchive:
            max(64 * 1024 * 1024, limit)
        }
    }

    /// Whether a fetch of `byteSize` bytes for `purpose` may just start.
    ///
    /// `nil` is "the backend did not say", and refuses. A negative size is treated the same way
    /// rather than clamped to zero: it can only come from a field that was not understood, which is
    /// the unknown case wearing a number.
    ///
    /// What a refusal *is* comes from the gesture, not from the size — `.confirm` where somebody is
    /// standing at a key waiting for the file, `.decline` where the fetch is the preview following
    /// the cursor and there is nobody to put a question to.
    public static func decision(
        forByteSize byteSize: Int64?,
        purpose: RemoteFetchPurpose,
        previewLimit: Int64
    ) -> RemoteFetchDecision {
        let refusal: RemoteFetchDecision = purpose.isAutomatic ? .decline : .confirm
        guard let byteSize, byteSize >= 0 else { return refusal }
        return byteSize <= threshold(for: purpose, previewLimit: previewLimit) ? .fetch : refusal
    }

    // MARK: - A set of files rather than one

    /// How many separate remote fetches may happen before the count alone is worth confirming.
    ///
    /// **A count as well as a size, because the two can disagree completely and the size cannot see
    /// it.** Every remote fetch is a fresh `curl` or `sftp` invocation with its own connect,
    /// handshake and authentication — measured at **0.512–0.519 s to first byte for a small S3
    /// object**, of which almost none is the bytes (docs/NOTES.md ▸ curl for S3). So 10 000 objects
    /// of 500 bytes each is 5 MB, under every row of the table above, and **83 minutes**. A rule
    /// expressed in bytes is structurally blind to that, and it fails in the quiet direction: the
    /// gesture starts, nothing is wrong, and it does not come back.
    ///
    /// Twenty is where the measured floor adds up to about ten seconds, which is roughly where a
    /// gesture stops feeling like a gesture. One number for every purpose, deliberately: the floor
    /// is a property of the *link*, not of what the user meant by pressing the key, so a per-purpose
    /// count would be six spellings of one measurement.
    ///
    /// It is not a cap. Over it the answer is ``RemoteFetchDecision/confirm`` — the plan names the
    /// count and the total and the user says yes — for the same reason nothing else in this table
    /// refuses outright.
    public static let unaskedRequestLimit = 20

    /// Whether `plan`'s outstanding work may just start, or has to be named to the user first.
    ///
    /// Three rules, in the order they can each be the only thing that fires:
    ///
    /// 1. **Inexact totals refuse.** ``MaterializationPlan/totalsAreExact`` is `false` when
    ///    something in the set cannot stand for its own cost — a remote directory, whose subtree is
    ///    unknown, or a size a listing did not understand. This is the unknown-size row of the table
    ///    above arriving over a set, and it is the least arguable rule here for the same reason.
    /// 2. **Too many round trips refuse**, by ``unaskedRequestLimit``, whatever they weigh.
    /// 3. **Too many bytes refuse**, by ``threshold(for:previewLimit:)``.
    ///
    /// A plan that needs nothing needs no special case: it weighs zero bytes in zero requests and is
    /// exact, so it falls through all three to ``RemoteFetchDecision/fetch``. That matters more than
    /// it looks — the ordinary use of every gesture M24 touches is a marked set of plain local files,
    /// and it must reach the engine without a dialog and without a branch anybody has to remember.
    public static func decision(
        for plan: MaterializationPlan,
        purpose: RemoteFetchPurpose,
        previewLimit: Int64
    ) -> RemoteFetchDecision {
        let refusal: RemoteFetchDecision = purpose.isAutomatic ? .decline : .confirm
        guard plan.totalsAreExact else { return refusal }
        guard plan.requestCount <= unaskedRequestLimit else { return refusal }
        return plan.byteTotal <= threshold(for: purpose, previewLimit: previewLimit)
            ? .fetch
            : refusal
    }
}
