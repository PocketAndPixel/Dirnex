import Foundation

/// Why a remote file's bytes are about to be pulled down — one case per gesture that can ask for
/// them (PLAN.md §M21 Slice 10).
///
/// Three of the four are a **key somebody pressed**. The fourth, ``cursorPreview``, is the preview
/// mode following the cursor with no key pressed for *this* file, and it is the one that changes what
/// a refusal may look like: there is nobody standing at a keystroke to answer a dialog, so an
/// automatic fetch that is too big must stand down silently rather than ask (see
/// ``RemoteFetchDecision/decline``). Same fork as Quick View's JavaScript switch and
/// Enter-vs-Unlock — "is this safe" and "should this happen unasked" are different questions — with
/// the size table answering the first and ``isAutomatic`` the second.
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
/// Three gestures reach this, and the sizes at which each stops being a reasonable thing to do
/// unasked are genuinely different — so the table is the feature, and the numbers in it are the
/// part expected to move.
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
        case .open, .edit: max(64 * 1024 * 1024, limit)
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
}
