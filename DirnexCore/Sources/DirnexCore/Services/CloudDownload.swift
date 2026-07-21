import Foundation

/// Where an iCloud item's bytes are, as one value a row can render and an open can wait on
/// (PLAN.md §M9 "download on open": *evicted → downloading → ready*).
///
/// The machine is pure: the app performs the syscall (`startDownloadingUbiquitousItem`) and
/// re-reads the ubiquitous resource keys, and hands each reading in here. That split is the
/// house rule — non-hermetic I/O in the app, the decision about what it means in the core,
/// tested against readings a fake produces.
public enum CloudDownloadPhase: Sendable, Hashable {
    /// The bytes are here. Opening the item is an ordinary file read.
    case ready
    /// A placeholder: real name, real size, no bytes. Opening must download first.
    case evicted
    /// A download is running. `fraction` is `nil` until the provider reports one — an
    /// indeterminate spinner is the honest rendering of "started, no numbers yet".
    case downloading(fraction: Double?)
    /// The download was asked for and did not start, or stopped without arriving.
    case failed(reason: CloudDownloadFailure)

    /// Whether this phase is still expected to change on its own, i.e. whether a waiter
    /// should keep polling. `ready` and `failed` are the two terminal answers.
    public var isSettled: Bool {
        switch self {
        case .ready, .failed: true
        case .evicted, .downloading: false
        }
    }
}

/// Why a download stopped short. Kept separate from `VFSError` because none of these are a
/// failure of *our* operation — they describe the cloud provider's answer, which the UI
/// reports as a state of the file rather than as an error we caused.
public enum CloudDownloadFailure: Sendable, Hashable {
    /// The provider reported an error against the item itself (offline, quota, missing).
    case provider(String)
    /// Asked to download, and the item neither started nor arrived within the deadline.
    case stalled
}

/// One reading of an item's iCloud state, as the app got it from `URLResourceValues`.
///
/// Deliberately a flat snapshot of the four keys rather than a `URL`: it is what makes the
/// machine testable without an iCloud account, and it forces the app side to be explicit
/// about which keys it actually read.
public struct CloudItemReading: Sendable, Hashable {
    /// `SF_DATALESS` — the bytes are not on disk. The ground truth; the downloading-status
    /// key can lag it, but this flag cannot lie about whether a read would block.
    public let isDataless: Bool
    /// `NSURLUbiquitousItemDownloadingStatusKey`, parsed. `nil` for a non-ubiquitous item.
    public let status: CloudDownloadStatus?
    /// `NSURLUbiquitousItemIsDownloadingKey`.
    public let isDownloading: Bool
    /// The provider's error for this item, if any (`…DownloadingErrorKey`).
    public let downloadingError: String?

    public init(
        isDataless: Bool,
        status: CloudDownloadStatus? = nil,
        isDownloading: Bool = false,
        downloadingError: String? = nil
    ) {
        self.isDataless = isDataless
        self.status = status
        self.isDownloading = isDownloading
        self.downloadingError = downloadingError
    }
}

/// `NSURLUbiquitousItemDownloadingStatusKey`'s three values, as an enum so the raw
/// `NSURLUbiquitousItemDownloadingStatus…` strings appear exactly once in the codebase.
///
/// The values are confusingly named: `.downloaded` means "a local copy exists but the cloud
/// has a newer one", while `.current` is the fully-up-to-date state. Both have bytes on disk.
public enum CloudDownloadStatus: String, Sendable, Hashable, CaseIterable {
    case notDownloaded = "NSURLUbiquitousItemDownloadingStatusNotDownloaded"
    case downloaded = "NSURLUbiquitousItemDownloadingStatusDownloaded"
    case current = "NSURLUbiquitousItemDownloadingStatusCurrent"

    /// Whether this status means the item's bytes are readable without a download.
    public var hasLocalBytes: Bool { self != .notDownloaded }
}

/// Tracks one item from the moment an open asks for it until its bytes are here.
///
/// A value type, driven by the caller: `requestSent()` when the download syscall returned,
/// then `observe(_:at:)` for each poll. It exists to hold the one rule that is easy to get
/// wrong by hand — *a request that has not visibly started yet is not a failure* — so a
/// caller polling every 200 ms doesn't declare a stall before the provider has had a chance
/// to react.
public struct CloudDownloadTracker: Sendable, Hashable {
    /// How long after the request an item may stay untouched — neither downloading nor
    /// arrived — before the wait gives up. Generous on purpose: the provider has to reach
    /// the network, and the alternative to waiting is a viewer opening an empty file.
    public static let defaultStallTimeout: TimeInterval = 30

    public private(set) var phase: CloudDownloadPhase
    private var requestedAt: Date?
    private let stallTimeout: TimeInterval

    /// Start from what the listing already knows: an entry's `isDataless` flag.
    public init(isDataless: Bool, stallTimeout: TimeInterval = defaultStallTimeout) {
        phase = isDataless ? .evicted : .ready
        self.stallTimeout = stallTimeout
    }

    /// Whether opening this item needs a download first — the question the open path asks
    /// before it hands a path to a viewer.
    public var needsDownload: Bool { phase == .evicted }

    /// Record that the download syscall has been made. Starts the stall clock; the phase
    /// only becomes `.downloading` once a reading confirms it, so the UI never claims
    /// progress the provider has not reported.
    public mutating func requestSent(at now: Date = Date()) {
        requestedAt = now
    }

    /// Fold one reading in and return the resulting phase.
    @discardableResult
    public mutating func observe(_ reading: CloudItemReading, at now: Date = Date()) -> CloudDownloadPhase {
        if let error = reading.downloadingError {
            phase = .failed(reason: .provider(error))
            return phase
        }
        // `isDataless` is the ground truth for "would a read block": the status key has been
        // seen to still say notDownloaded on an item whose bytes have already landed.
        if !reading.isDataless || reading.status?.hasLocalBytes == true {
            phase = .ready
            return phase
        }
        if reading.isDownloading {
            phase = .downloading(fraction: nil)
            return phase
        }
        // Dataless, not downloading. Either nobody asked yet, or the ask went nowhere.
        if let requestedAt, now.timeIntervalSince(requestedAt) >= stallTimeout {
            phase = .failed(reason: .stalled)
        } else {
            phase = .evicted
        }
        return phase
    }

    /// Fold in a progress fraction reported separately (`NSMetadataQuery`'s percent key,
    /// which has no `URLResourceKey` equivalent — the URL one is unavailable on macOS).
    /// Ignored unless a download is actually running, so a stale percentage can't resurrect
    /// a finished or failed transfer.
    public mutating func observe(percentDownloaded percent: Double) {
        guard case .downloading = phase else { return }
        phase = .downloading(fraction: min(max(percent / 100, 0), 1))
    }
}
