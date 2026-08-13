import Foundation

/// Why a remote file's bytes are about to be pulled down — one case per gesture that can ask for
/// them (PLAN.md §M21 Slice 10).
///
/// Every case here is a **key somebody pressed**. Cursor movement is deliberately not one of them:
/// a preview that follows the cursor would spend a billed request and somebody's bandwidth because
/// an arrow key passed over a row, which is the same fork Quick View's JavaScript switch and
/// Enter-vs-Unlock were settled on — "is this safe" and "should this happen unasked" are different
/// questions, and only the first is about the size of the file.
public enum RemoteFetchPurpose: Sendable, Equatable, CaseIterable {
    /// ⌘Y / ⌃Q / F3 on a remote row: show me what is in this.
    case preview
    /// ⏎ on a remote row: open it in whatever owns the type.
    case open
    /// F4 on a remote row: open it in the text editor, and offer to write the save back.
    case edit
}

/// Whether a fetch is small enough to just happen.
public enum RemoteFetchDecision: Sendable, Equatable {
    /// Start the transfer. The progress sheet still appears if it takes long enough.
    case fetch
    /// Ask first, naming the size.
    case confirm
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
public enum RemoteFetchPolicy {
    /// The size at or below which `purpose` fetches without asking.
    public static func threshold(for purpose: RemoteFetchPurpose) -> Int64 {
        switch purpose {
        case .preview: 16 * 1024 * 1024
        case .open, .edit: 64 * 1024 * 1024
        }
    }

    /// Whether a fetch of `byteSize` bytes for `purpose` may just start.
    ///
    /// `nil` is "the backend did not say", and confirms. A negative size is treated the same way
    /// rather than clamped to zero: it can only come from a field that was not understood, which is
    /// the unknown case wearing a number.
    public static func decision(
        forByteSize byteSize: Int64?,
        purpose: RemoteFetchPurpose
    ) -> RemoteFetchDecision {
        guard let byteSize, byteSize >= 0 else { return .confirm }
        return byteSize <= threshold(for: purpose) ? .fetch : .confirm
    }
}
