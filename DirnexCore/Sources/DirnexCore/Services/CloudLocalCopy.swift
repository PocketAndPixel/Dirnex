import Foundation

/// **Download Now** and **Remove Download** — the two things any app may ask of a cloud item's local
/// copy, whichever provider holds it (docs/NOTES.md ▸ Google Drive (and every other `CloudStorage`
/// provider), "Download Now and Remove Download on any provider").
///
/// Finder's menu over a cloud file carries much more than these — Copy Dropbox link, View on Box.com,
/// Version History, Lock File — and none of the rest can be offered here. Each is declared in the
/// provider's File Provider extension, shown when a predicate over the provider's *private* item
/// metadata matches, and run through a private FileProvider API. These two are Apple's own and
/// public: `FileManager.startDownloadingUbiquitousItem` and `evictUbiquitousItem` answer for iCloud,
/// Dropbox, Box, OneDrive and a streaming Google Drive alike (measured 2026-09-12).
///
/// The decisions live here and the system calls in the app — the split `CloudDownloadTracker`
/// already draws: which rows the commands can mean anything for, what a folder means to each, and
/// what a refusal is telling the user.
public enum CloudLocalCopyAction: Sendable, Hashable, CaseIterable {
    /// Bring the bytes down. On a folder that means everything inside it, which the system call does
    /// **not** do by itself — asked about a folder it answers success and downloads nothing
    /// (measured: seventeen placeholders still placeholders after thirty seconds) — so a folder is
    /// walked and each placeholder in it is asked for.
    case download
    /// Let the provider drop the local bytes and keep the file in the cloud. On a folder the system
    /// call recurses by itself (measured), so a folder is one request.
    case removeDownload

    /// Whether this action has anything to do for `target`.
    ///
    /// A folder always qualifies for both: whether anything inside it is a placeholder is a walk
    /// away, and a menu validator cannot take one. A file qualifies for exactly one, decided by
    /// `SF_DATALESS` — the ground truth for "these bytes are not here", carried in on the listing's
    /// own `stat`.
    public func applies(to target: CloudLocalCopyTarget) -> Bool {
        switch self {
        case .download: target.isDirectory || target.isDataless
        case .removeDownload: target.isDirectory || !target.isDataless
        }
    }

    /// Whether this action has anything to do for at least one of `targets`.
    public func applies(toAnyOf targets: [CloudLocalCopyTarget]) -> Bool {
        targets.contains(where: applies(to:))
    }
}

/// One row as these two commands see it.
public struct CloudLocalCopyTarget: Sendable, Hashable {
    public let path: VFSPath
    public let isDirectory: Bool
    /// `SF_DATALESS`: a file whose bytes are not on this Mac.
    public let isDataless: Bool

    public init(path: VFSPath, isDirectory: Bool, isDataless: Bool) {
        self.path = path
        self.isDirectory = isDirectory
        self.isDataless = isDataless
    }

    /// The target `entry` stands for, or `nil` when neither command can mean anything for it.
    ///
    /// Decided from facts the pane already holds, because the question is asked by a menu validator:
    /// a resource read inside a provider domain is a round trip to `fileproviderd` (650–1000 µs, and
    /// unbounded while a domain is wedged — docs/NOTES.md), which a menu must not wait on. A row is
    /// a cloud item when any of three says so:
    ///
    /// - it is a **placeholder** — only a provider makes one;
    /// - it sits under `~/Library/CloudStorage` or `~/Library/Mobile Documents`, where every File
    ///   Provider sync client and iCloud Drive keep their items;
    /// - the caller already **knows** — `isKnownCloudItem`, a sync badge on the row or a directory
    ///   read off the main thread as a cloud directory. That is the only way iCloud's Desktop and
    ///   Documents folders qualify, since they live outside both roots.
    ///
    /// The path rule over-approximates on purpose — a mirror-mode Google Drive is reached through
    /// `<mount>/My Drive` and holds ordinary local files — because the refusal is cheap and exact:
    /// such a file answers ``CloudLocalCopyRefusal/notACloudItem`` and is counted, not reported.
    ///
    /// A symlink is never a target. `My Drive` in mirror mode is one, pointing out of every domain,
    /// and acting "through" a link would act on whatever it names.
    public init?(entry: FileEntry, isKnownCloudItem: Bool, home: String = NSHomeDirectory()) {
        guard entry.path.backend == .local else { return nil }
        switch entry.kind {
        case .file, .directory: break
        case .symlink, .other: return nil
        }
        guard entry.isDataless || isKnownCloudItem
            || Self.isInProviderStorage(entry.path.path, home: home) else { return nil }
        self.init(
            path: entry.path,
            isDirectory: entry.kind == .directory,
            isDataless: entry.isDataless
        )
    }

    /// Whether `path` is inside the two directories that hold every provider's items.
    ///
    /// Matched with the trailing separator so `CloudStorageBackup` is not `CloudStorage`, and against
    /// `home` so another account's `Library` is not this one's.
    public static func isInProviderStorage(_ path: String, home: String) -> Bool {
        ["/Library/CloudStorage/", "/Library/Mobile Documents/"].contains { path.hasPrefix(home + $0) }
    }
}

/// Why a provider turned an item away — in the words the system call's error chain carries, which
/// are the only words there are (measured shapes in docs/NOTES.md).
public enum CloudLocalCopyRefusal: Sendable, Hashable {
    /// Nothing manages this item: an ordinary file, or one under a mirror-mode Google Drive.
    /// `NSCocoaErrorDomain` 3328 over `ENOTSUP` from an eviction; `NSCocoaErrorDomain` 512 over
    /// `NSFileProviderInternalErrorDomain` 0 ("No valid file provider found") from a download.
    case notACloudItem
    /// Something has the file open — `NSCocoaErrorDomain` 255 over `EBUSY`, whose own text is
    /// "Unable to Remove Download". An open descriptor is enough; so is a mapping.
    case inUse
    /// The provider will not let go of it: not uploaded yet, carrying edits it has not synced, or
    /// set to stay on this Mac. `NSFileProviderErrorDomain` −2008 (non-evictable), −2007 (unsynced
    /// edits) and −2006 (a folder with such a child).
    case notYetUploaded
    /// Excluded from sync, so this Mac holds the only copy — `NSFileProviderErrorDomain` −2010.
    case excludedFromSync
    /// A folder being walked for placeholders could not be listed.
    case folderUnreadable
    /// Anything else, carrying the system's own sentence from the innermost error.
    case other(String)

    static let fileProviderDomain = "NSFileProviderErrorDomain"
    static let fileProviderInternalDomain = "NSFileProviderInternalErrorDomain"

    /// Classify an error thrown by `evictUbiquitousItem` or `startDownloadingUbiquitousItem`.
    ///
    /// The whole chain is read, not the outer error: the outer one is a generic Cocoa wrapper (512,
    /// "couldn't be saved", for three different refusals) and the meaning is underneath. So a bare
    /// 512 with nothing below it is *not* read as "not a cloud item" — it is ``other(_:)``.
    public init(error: any Error) {
        let chain = Self.chain(from: error as NSError)
        func contains(_ domain: String, _ codes: Set<Int>) -> Bool {
            chain.contains { $0.domain == domain && codes.contains($0.code) }
        }
        if contains(Self.fileProviderDomain, [-2006, -2007, -2008]) {
            self = .notYetUploaded
        } else if contains(Self.fileProviderDomain, [-2010]) {
            self = .excludedFromSync
        } else if contains(NSPOSIXErrorDomain, [Int(EBUSY)]) {
            self = .inUse
        } else if contains(Self.fileProviderInternalDomain, [0])
            || contains(NSCocoaErrorDomain, [CocoaError.Code.featureUnsupported.rawValue]) {
            self = .notACloudItem
        } else {
            self = .other((chain.last ?? error as NSError).localizedDescription)
        }
    }

    private static func chain(from error: NSError) -> [NSError] {
        var chain = [error]
        var current = error
        while let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError, chain.count < 16 {
            chain.append(underlying)
            current = underlying
        }
        return chain
    }
}

/// What a run did, in the terms the app reports it in.
public struct CloudLocalCopyReport: Sendable, Hashable {
    public struct Failure: Sendable, Hashable {
        public let path: VFSPath
        public let refusal: CloudLocalCopyRefusal

        public init(path: VFSPath, refusal: CloudLocalCopyRefusal) {
            self.path = path
            self.refusal = refusal
        }
    }

    public let action: CloudLocalCopyAction
    /// Requests the provider accepted: files asked to download, or items — a whole folder counts
    /// once — whose download was removed. A download request is accepted long before any byte
    /// arrives, so this counts what was *asked for*; the row badges show what landed.
    public var accepted: Int
    /// Items that turned out to be managed by nothing (``CloudLocalCopyRefusal/notACloudItem``).
    /// Counted rather than reported: the path rule that let them through over-approximates by design.
    public var notCloudItems: Int
    /// Everything a provider refused, with the path it refused.
    public var failures: [Failure]
    public var wasCancelled: Bool

    public init(
        action: CloudLocalCopyAction,
        accepted: Int = 0,
        notCloudItems: Int = 0,
        failures: [Failure] = [],
        wasCancelled: Bool = false
    ) {
        self.action = action
        self.accepted = accepted
        self.notCloudItems = notCloudItems
        self.failures = failures
        self.wasCancelled = wasCancelled
    }
}

/// Runs one action over a set of targets, with the system call handed in.
///
/// Blocking — every step is a round trip to `fileproviderd` and a folder walk is a listing per
/// folder — so the app runs it through `BlockingWork`.
public enum CloudLocalCopyRunner {
    /// The system call for one path. The app's is `startDownloadingUbiquitousItem` or
    /// `evictUbiquitousItem`; a test's records what it was asked.
    public typealias Perform = (CloudLocalCopyAction, VFSPath) throws -> Void

    public static func run(
        _ action: CloudLocalCopyAction,
        on targets: [CloudLocalCopyTarget],
        using backend: any VFSBackend,
        isCancelled: () -> Bool = { false },
        perform: Perform
    ) -> CloudLocalCopyReport {
        var report = CloudLocalCopyReport(action: action)
        for target in targets where action.applies(to: target) {
            guard !isCancelled() else {
                report.wasCancelled = true
                break
            }
            if action == .download, target.isDirectory {
                walk(
                    target.path,
                    using: backend,
                    into: &report,
                    isCancelled: isCancelled,
                    perform: perform
                )
            } else {
                attempt(action, on: target.path, into: &report, perform: perform)
            }
            if report.wasCancelled { break }
        }
        return report
    }

    /// Ask for every placeholder under `root`, at every depth.
    ///
    /// Symlinks are not followed and files that are already here are not asked about: a request for
    /// one is harmless (measured idempotent) but it is a round trip each, and a large folder that is
    /// mostly downloaded is the ordinary case. A folder that cannot be listed is reported and the
    /// walk goes on with its siblings.
    private static func walk(
        _ root: VFSPath,
        using backend: any VFSBackend,
        into report: inout CloudLocalCopyReport,
        isCancelled: () -> Bool,
        perform: Perform
    ) {
        var pending = [root]
        while let directory = pending.popLast() {
            let entries: [FileEntry]
            do {
                entries = try backend.listDirectory(at: directory)
            } catch {
                report.failures.append(.init(path: directory, refusal: .folderUnreadable))
                continue
            }
            for entry in entries {
                guard !isCancelled() else {
                    report.wasCancelled = true
                    return
                }
                switch entry.kind {
                case .directory:
                    pending.append(entry.path)
                case .file where entry.isDataless:
                    attempt(.download, on: entry.path, into: &report, perform: perform)
                case .file, .symlink, .other:
                    continue
                }
            }
        }
    }

    private static func attempt(
        _ action: CloudLocalCopyAction,
        on path: VFSPath,
        into report: inout CloudLocalCopyReport,
        perform: Perform
    ) {
        do {
            try perform(action, path)
            report.accepted += 1
        } catch {
            switch CloudLocalCopyRefusal(error: error) {
            case .notACloudItem: report.notCloudItems += 1
            case let refusal: report.failures.append(.init(path: path, refusal: refusal))
            }
        }
    }
}
