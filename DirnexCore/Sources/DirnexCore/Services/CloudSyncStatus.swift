import Foundation

/// Where a cloud-synced file's bytes actually are (PLAN.md §M6 "iCloud/provider sync status").
///
/// This is the single state a panel row renders, distilled from the seven-odd ubiquity attributes
/// the system reports per file — see `CloudItemAttributes.status` for how they collapse into one, and
/// why the order they are consulted in is not the order they are documented in.
///
/// The vocabulary is deliberately provider-neutral. iCloud is what can be tested here, but every
/// state below is something any File Provider can be in, and the attributes are the system's
/// cross-provider ones rather than anything iCloud-specific.
public enum CloudSyncStatus: Sendable, Hashable, CaseIterable {
    /// Downloaded, uploaded, nothing in flight — the overwhelming majority of rows, and the one that
    /// renders nothing. Finder draws nothing for it either: a badge on every synced file in an
    /// all-synced folder is a column of noise that says the same thing on every line.
    case upToDate
    /// A placeholder: the file exists, its size and dates are real, but its bytes are in the cloud
    /// only. This is the state the badge exists for — opening one costs a download.
    case notDownloaded
    /// Bytes are on their way down right now.
    case downloading
    /// Local edits have not reached the cloud yet — either actively uploading, or queued to.
    case uploading
    /// The same file was edited in two places and the provider could not reconcile them. The one
    /// state that demands a human.
    case conflicted
    /// The provider gave up on a transfer and reported an error.
    case failed
    /// Deliberately kept out of sync by the user (`isExcludedFromSync`) — local-only on purpose,
    /// which is a fact worth showing rather than a problem to fix.
    case excluded

    /// Whether this state is worth drawing at all. Only `.upToDate` isn't: it is the default state
    /// of a working cloud folder, and saying so on every row would drown out the rows that differ.
    public var isNoteworthy: Bool {
        self != .upToDate
    }

    /// Whether this state is a transfer that will resolve on its own — as opposed to a resting
    /// state that only changes when something happens to the file.
    ///
    /// The distinction is load-bearing rather than cosmetic: a resting state is announced by the
    /// filesystem (a file is evicted, a file is materialized) and a watcher is enough to catch it,
    /// while a transfer *ends* without an event of its own, so whoever shows one has to look again
    /// to find out it stopped. `CloudSyncStatusProvider.scheduleFollowUp` is that looking, and this
    /// is what tells it when to bother.
    public var isTransfer: Bool {
        self == .downloading || self == .uploading
    }
}

/// The system's own three downloading states, keyed by the exact strings it reports.
///
/// **The raw values were probed off a live iCloud file, not taken from memory** (the pass-1 `git`
/// and pass-3 tags lesson): a file evicted with `brctl evict` really does report
/// `NSURLUbiquitousItemDownloadingStatusNotDownloaded`. Keeping the mapping here — rather than
/// letting the app pass Foundation's `URLUbiquitousItemDownloadingStatus` straight through — is what
/// makes it testable without a cloud file to hand, and pins the spellings so a typo cannot silently
/// turn every row into "unknown".
public enum CloudDownloadingStatus: String, Sendable, Hashable, CaseIterable {
    /// The newest version is local.
    case current = "NSURLUbiquitousItemDownloadingStatusCurrent"
    /// A local version exists but a newer one is in the cloud. Apple deprecated this in favour of
    /// `.current`, and it is treated as "the bytes are here" — which is what a file manager's reader
    /// wants to know, and the only thing this status still reliably means.
    case downloaded = "NSURLUbiquitousItemDownloadingStatusDownloaded"
    /// A placeholder — no bytes locally.
    case notDownloaded = "NSURLUbiquitousItemDownloadingStatusNotDownloaded"
}

/// Why a provider says a transfer has not gone through, keyed by the Cocoa error codes it reports.
///
/// **This type exists because "there is an error" turned out not to mean "something is wrong".**
/// Probed against a live iCloud file, `NSUbiquitousFileUbiquityServerNotAvailable` (4355, *"Couldn't
/// access your iCloud account"*) is attached to **every** ordinary pending upload — from the instant
/// there is something to push until it lands. Three samples, all of them healthy syncs that completed
/// in seconds: a Finder-tag write, a one-line content edit, and a 60 MB file where the error was
/// already there in the first sample, *before* `isUploading` had even flipped true. Reading its
/// presence as a failure meant the red `xmark.icloud` was painted over the whole of every upload —
/// which is what a user reported seeing on every tag they applied, and why `status` no longer asks
/// merely *whether* there is an error.
///
/// So the mapping is here, in the core, rather than the app matching `NSError` codes inline: it is
/// the same "the core decides what the system's raw values mean" split `CloudDownloadingStatus`
/// draws, and it makes the distinction testable without an iCloud account, a network, or a file.
public enum CloudTransferError: Sendable, Hashable, CaseIterable {
    /// The provider could not reach its server on the last attempt. **Not a verdict** — see
    /// `isVerdict`.
    case serverUnavailable
    /// The account is out of space, so the upload will not happen until a human does something.
    case quotaExceeded
    /// The bytes are on no device the provider can reach, so the download cannot be satisfied.
    case itemUnavailable
    /// Anything else, including any error from a domain other than Cocoa's. Unrecognised is treated
    /// as real: the states worth suppressing are the ones proven to be noise, and this one isn't.
    case other

    /// Classify an error the system reported. The domain is checked because these codes are only
    /// meaningful in Cocoa's — code 4355 in some provider's own domain means something else entirely.
    public init(domain: String, code: Int) {
        guard domain == NSCocoaErrorDomain else {
            self = .other
            return
        }
        switch CocoaError.Code(rawValue: code) {
        case .ubiquitousFileUbiquityServerNotAvailable: self = .serverUnavailable
        case .ubiquitousFileNotUploadedDueToQuota: self = .quotaExceeded
        case .ubiquitousFileUnavailable: self = .itemUnavailable
        default: self = .other
        }
    }

    /// Whether this error is a verdict about the file, or merely a note about the attempt in flight.
    ///
    /// `.serverUnavailable` is the note, and the only one: the transfer states already say the true
    /// and useful thing about a file whose server cannot be reached — it is **waiting to upload** —
    /// and that stays true whether the provider is quietly retrying or the Mac is on a plane. A file
    /// that is going to arrive as soon as there is a network has not failed at anything, so it gets
    /// the blue arrow that says so and not a red cross that says it needs help.
    ///
    /// The others are answers about the file itself, and outrank whatever transfer state the provider
    /// happens to also be reporting.
    public var isVerdict: Bool {
        self != .serverUnavailable
    }
}

/// One row's ubiquity attributes, as the system reports them.
///
/// The app reads them (`CloudSyncStatusProvider`) and this decides what they mean — the same
/// core-decides-meaning / app-does-I/O split as `GitStatusParser` against `git status --porcelain`.
/// Every field is a plain value, so the whole truth table below is testable without iCloud, a
/// network, or a file.
public struct CloudItemAttributes: Sendable, Hashable {
    /// Whether the system calls this a cloud item at all. **This, and only this, is what makes a row
    /// a cloud row** — see `status`, where it is the first question asked and the one that earns its
    /// own note.
    public var isUbiquitous: Bool
    public var downloadingStatus: CloudDownloadingStatus?
    public var isDownloading: Bool
    public var isUploading: Bool
    /// Whether local changes have reached the cloud. Note the default: **`true`**, i.e. "nothing is
    /// pending". An attribute the system declines to answer must not be read as an upload in
    /// progress — that would badge every row of a provider that doesn't report it.
    public var isUploaded: Bool
    public var hasUnresolvedConflicts: Bool
    /// The errors the provider reports, **classified rather than counted** — the presence of one says
    /// nothing on its own, because iCloud attaches `.serverUnavailable` to every healthy pending
    /// upload. `CloudTransferError` is where that discovery is written down.
    public var downloadingError: CloudTransferError?
    public var uploadingError: CloudTransferError?
    public var isExcludedFromSync: Bool

    public init(
        isUbiquitous: Bool = false,
        downloadingStatus: CloudDownloadingStatus? = nil,
        isDownloading: Bool = false,
        isUploading: Bool = false,
        isUploaded: Bool = true,
        hasUnresolvedConflicts: Bool = false,
        downloadingError: CloudTransferError? = nil,
        uploadingError: CloudTransferError? = nil,
        isExcludedFromSync: Bool = false
    ) {
        self.isUbiquitous = isUbiquitous
        self.downloadingStatus = downloadingStatus
        self.isDownloading = isDownloading
        self.isUploading = isUploading
        self.isUploaded = isUploaded
        self.hasUnresolvedConflicts = hasUnresolvedConflicts
        self.downloadingError = downloadingError
        self.uploadingError = uploadingError
        self.isExcludedFromSync = isExcludedFromSync
    }

    /// The one status a row shows, or `nil` for a file that is not in the cloud at all.
    ///
    /// **`isUbiquitous` is the only honest discriminator, and the probe proved it.** A `.DS_Store`
    /// sitting *inside* iCloud Drive reports `isUbiquitous == false` and yet answers `.current` for
    /// its downloading status — so a reading that keyed off the status would badge a local-only file
    /// as a synced cloud file. Outside a cloud container every attribute comes back `nil` instead,
    /// which the reader turns into the `false` default here.
    ///
    /// **The order is a precedence, and it is not the order the attributes are documented in:**
    ///
    /// - Errors and conflicts first — they are verdicts about the file, and they outrank whatever
    ///   transfer state the provider happens to also be reporting. **But only the errors that really
    ///   are verdicts**, which is not all of them: iCloud reports "server not available" throughout
    ///   every perfectly healthy upload, so asking whether an error *exists* red-crossed every file
    ///   the user touched. `CloudTransferError.isVerdict` is the sieve, and the story is on it.
    /// - `.excluded` before the transfer states, because a file the user excluded is never going to
    ///   upload, and `isUploaded` is `false` on one forever. Asking about uploads first would badge
    ///   it as eternally pending.
    /// - **`isDownloading` before the downloading *status*, because the status lies during a
    ///   download.** This is the finding that made the probe worth running: sampling a real
    ///   `brctl download` showed `isDownloading == true` while the status still read
    ///   `NotDownloaded`, flipping to `.current` only ~0.7 s later. Consulting the status first would
    ///   paint "in the cloud" over a file actively arriving.
    /// - `isUploading || !isUploaded` last of the transfer states: the same probe showed
    ///   `isUploading` staying `false` for the whole of a 60 MB upload while `isUploaded` was
    ///   `false` throughout — so the *pending* flag, not the *active* one, is what actually reports
    ///   an upload, and both mean one thing to someone browsing a folder.
    public var status: CloudSyncStatus? {
        guard isUbiquitous else { return nil }
        if downloadingError?.isVerdict == true || uploadingError?.isVerdict == true { return .failed }
        if hasUnresolvedConflicts { return .conflicted }
        if isExcludedFromSync { return .excluded }
        if isDownloading { return .downloading }
        if downloadingStatus == .notDownloaded { return .notDownloaded }
        if isUploading || !isUploaded { return .uploading }
        return .upToDate
    }
}
