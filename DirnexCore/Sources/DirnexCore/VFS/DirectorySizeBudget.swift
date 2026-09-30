import Foundation

/// How much a recursive size walk may spend before it gives up (PLAN.md §M21 Slice 11).
///
/// A local walk is a `readdir` per directory and needs no budget — it is bounded by the disk. A
/// **remote** one is a billed request per directory at a network round trip apiece, and the cost
/// cannot be stated before the walk, because finding out how many directories there are *is* the
/// walk. That asymmetry is the whole reason this type exists: a download can be confirmed against
/// a number on the row, and this cannot.
///
/// Measured 2026-08-14 against the live third-party S3 endpoint, through the real `S3Backend` and
/// the app's own `S3CurlTransport`: one `ListObjectsV2` per directory, issued serially, at
/// **0.601–0.699 s each** (mean 0.621, matching Slice 10 probe 5's 0.51 s time-to-first-byte
/// floor — every request is a fresh `curl`, since HTTP keeps no session). A ten-directory prefix
/// therefore costs 6.21 s and ten billed requests, and it scales linearly from there:
///
///     directories      wall time      billed requests
///            10           6.2 s                    10
///           100          62.1 s                   100
///          1000         10.3 min                 1000
///         10000          1.7 h                  10000
///
/// **The budget is not the patience limit** — Stop and navigating away are, and both cancel at
/// one-listing granularity (measured: 1.27 s to abandon after two). It is the runaway guard for a
/// walk nobody is waiting on any more: Space pressed on a bucket root holding a data lake, and
/// then a closed laptop. `S3Backend.pageLimit` is the same argument one level down, in the same
/// words — far past anything a person browses, and low enough that a runaway fails instead of
/// billing indefinitely.
public struct DirectorySizeBudget: Sendable, Hashable {
    /// The most directories one walk may list before it gives up, or `nil` for no limit.
    ///
    /// Directories rather than seconds, for two reasons. It is the unit that is actually *billed*
    /// on a request-priced backend, so it is the honest thing to bound; and it is deterministic,
    /// where a wall-clock bound would make the same tree pass on a fast link and fail on a slow
    /// one — untestable, and a limit that moves with the weather.
    public let directoryLimit: Int?

    public init(directoryLimit: Int?) {
        self.directoryLimit = directoryLimit
    }

    /// No limit — what a local walk gets, and the default everywhere, so adding this parameter
    /// changed no existing caller's behaviour.
    public static let unbounded = DirectorySizeBudget(directoryLimit: nil)

    /// What a walk over a connected server gets.
    ///
    /// 1000 is `S3Backend.pageLimit`'s number and its reasoning: at the measured 0.621 s per
    /// listing it is ~10 minutes and 1000 requests, which no folder a person points at reaches and
    /// which an abandoned walk over a data lake hits in a bounded time instead of never. The
    /// number is expected to move — it is a policy, not a fact about the protocol — which is why
    /// it is named here rather than written at the call site.
    public static let remote = DirectorySizeBudget(directoryLimit: 1000)

    /// The budget a walk over `backend` runs under.
    ///
    /// Keyed on ``VFSBackendID/isRemoteConnection`` rather than on a list of backend cases, which
    /// is this milestone's most-repeated finding: one question with several spellings is how a
    /// backend added later inherits the wrong answer silently. An archive is deliberately
    /// *unbounded* — its listing is a cached `bsdtar -tvf` of a file already on this disk, so it
    /// costs no round trip and no money.
    public static func forBackend(_ backend: VFSBackendID) -> DirectorySizeBudget {
        backend.isRemoteConnection ? .remote : .unbounded
    }

    /// Whether a walk that has listed `directories` so far may list another.
    public func allows(directoriesListed directories: Int) -> Bool {
        guard let directoryLimit else { return true }
        return directories < directoryLimit
    }

    /// Whether a walk under this budget should be abandoned once the pane that asked for it has
    /// stopped looking — navigated away, switched tabs, or closed.
    ///
    /// Derived from the limit rather than stored beside it, because it is the *same question*: who
    /// pays for a walk nobody is waiting for. Locally nobody does, so `DirectoryLoader.size`
    /// deliberately outlives its caller and banks the total for free — that is its doc comment's
    /// own argument and it is correct. Remotely it is the user's money and their bandwidth, spent
    /// on a number that now has no row to land in, so the same argument runs the other way.
    ///
    /// Keeping it here is what stops the two halves from being two spellings the compiler cannot
    /// compare: a backend that gains a budget gains the cancellation with it.
    public var abandonsWhenUnwatched: Bool { directoryLimit != nil }

    /// The allowance a **whole bar column's worth of walks** shares — size-visualization mode asks
    /// for every sibling's recursive total at once, because the mode is on rather than because
    /// anybody pointed at a folder.
    ///
    /// The same number as one walk's, and that is the finding rather than a shortcut: **the set
    /// costs one walk of the parent, not N of them.** The siblings' subtrees are disjoint, so
    /// however the work is sliced it is the same directories listed once each — measured
    /// 2026-09-01 through the real ``DirectorySizer``, sizing 40 top-level rows separately against
    /// sizing their container whole (6.46 ms against 6.59 ms over an archive of 1410 directories),
    /// and again against a live `sshd`, where the set of 8 spent **136** sessions against the whole
    /// walk's 137. So what a bounded backend needed before its rows could carry bars was not a
    /// bigger number but an allowance held across the *set*: without one, N walks each entitled to
    /// ``remote``'s thousand listings is N thousand billed requests for one keystroke.
    ///
    /// A separate function rather than a second call to ``forBackend(_:)`` because the *subject*
    /// differs even where the number does not — this is what one keystroke may spend, and it is the
    /// place to change if the two ever have to part.
    public static func forSet(ofBackend backend: VFSBackendID) -> DirectorySizeBudget {
        forBackend(backend)
    }
}

/// Thrown by ``DirectorySizer/size(of:using:budget:excluding:isCancelled:)`` when a walk reaches
/// its ``DirectorySizeBudget`` — deliberately an error rather than a partial total.
///
/// The bytes counted so far are *not* carried, and that is the point. A partial rendered as the
/// answer claims something about the folder when the truth is a claim about the question, which is
/// the same trap as a filtered-out row drawn as "Zero KB · 0.0 %" (docs/NOTES.md ▸ Design lessons).
/// It throws for the same reason a cancelled walk throws `CancellationError`: both mean *no total*,
/// so every existing `try?` caller already turns it into the `nil` the size cache stores nothing
/// for. A caller that wants to say which of the two happened catches this case by name.
public struct DirectorySizeBudgetExceeded: Error, Equatable, Sendable {
    /// How many directories were listed before giving up — the budget's `directoryLimit`, and
    /// therefore also the number of requests a remote walk actually spent.
    public let directoriesListed: Int

    public init(directoriesListed: Int) {
        self.directoriesListed = directoriesListed
    }
}
