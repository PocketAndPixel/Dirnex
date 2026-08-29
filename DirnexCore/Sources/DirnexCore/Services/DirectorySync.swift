import Foundation

// Total Commander's Synchronize Directories, headless (PLAN.md §M5 "Synchronize directories:
// two-panel diff view (left-only / right-only / differs / same), by size+date or content hash;
// selective sync actions through the queue").
//
// This is the pure *comparison* half: given two directory roots (each on some `VFSBackend`),
// it walks both trees in lock-step and produces one `SyncEntry` per differing or one-sided
// item — the rows the diff view renders. It also derives the *default* per-row action for a
// chosen sync direction; the app lets the user override those, then turns the surviving
// actions into copy/delete jobs on the M2 queue.
//
// Nothing here mutates the filesystem, so it is unit-tested against fixture trees without a
// live queue. Metadata (size + modification date) comes straight from the `listDirectory`
// snapshot; exact content equality is delegated to an injected comparator (defaulting to
// `ByteComparator.localFilesEqual`) so the engine needs no file-read primitive of its own.

// MARK: - Status

/// Where one item stands between the two trees — the classification a diff row shows.
public enum SyncStatus: Sendable, Equatable {
    /// Present only under the left root (whole subtree, if a directory).
    case leftOnly
    /// Present only under the right root.
    case rightOnly
    /// On both sides, not equal, and the left copy's mtime is newer (beyond tolerance).
    case leftNewer
    /// On both sides, not equal, and the right copy's mtime is newer.
    case rightNewer
    /// On both sides and not equal, but neither is clearly newer (equal mtimes, differing
    /// content/size) — the app can't pick a winner automatically.
    case differ
    /// On both sides and judged equal under the active comparison — nothing to do.
    case identical
    /// Same name, but a file on one side and a directory on the other — a structural clash
    /// that always needs an explicit decision.
    case typeMismatch
}

// MARK: - Direction & action

/// The overall reconciliation the user picked in the toolbar.
public enum SyncDirection: Sendable, Equatable {
    /// Make the right tree match the left: copy left-only and changed items rightward,
    /// delete right-only items. A destructive mirror.
    case leftToRight
    /// Make the left tree match the right (the mirror image of `leftToRight`).
    case rightToLeft
    /// Union both trees, newer copy wins each way, nothing is deleted; genuine conflicts are
    /// flagged rather than resolved.
    case bidirectional
}

/// The concrete operation proposed for one row, which the app maps onto a queue job.
public enum SyncAction: Sendable, Equatable {
    /// Leave both sides as they are.
    case none
    /// Copy the left item over to the right (creating or overwriting).
    case copyToRight
    /// Copy the right item over to the left.
    case copyToLeft
    /// Remove the left item.
    case deleteLeft
    /// Remove the right item.
    case deleteRight
    /// No safe automatic choice — both sides changed, or a file/directory type clash. The
    /// app surfaces these for a manual decision and never runs them unattended.
    case conflict
}

// MARK: - Entry

/// One row of the comparison: a relative path and the two sides' stat snapshots (either may
/// be absent), plus the derived status. Identity is the relative path, so a list view diffs
/// rows cleanly across a re-scan.
public struct SyncEntry: Sendable, Equatable, Identifiable {
    /// Path relative to both roots, `/`-joined, e.g. `"photos/trip.jpg"`. Never empty.
    public let relativePath: String
    /// The final path component — what the row labels.
    public let name: String
    /// The left tree's entry, or `nil` when the item is absent on the left.
    public let left: FileEntry?
    /// The right tree's entry, or `nil` when absent on the right.
    public let right: FileEntry?
    public let status: SyncStatus

    public init(
        relativePath: String,
        name: String,
        left: FileEntry?,
        right: FileEntry?,
        status: SyncStatus
    ) {
        self.relativePath = relativePath
        self.name = name
        self.left = left
        self.right = right
        self.status = status
    }

    public var id: String { relativePath }

    /// True when the item is a directory on whichever side(s) it exists.
    public var isDirectory: Bool {
        (left?.isDirectory ?? false) || (right?.isDirectory ?? false)
    }

    /// The default action for this row under `direction` — the pre-checked choice the user
    /// can override before applying.
    public func defaultAction(for direction: SyncDirection) -> SyncAction {
        DirectorySync.defaultAction(for: status, direction: direction)
    }

    /// The override actions the user may pick for this row (see `DirectorySync.availableActions`).
    public var availableActions: [SyncAction] {
        DirectorySync.availableActions(for: status)
    }
}

// MARK: - Engine

public enum DirectorySync {
    /// A pair of directories that both exist, queued for descent, plus the relative prefix
    /// their children share. The scan's explicit work stack holds these (an iterative walk so
    /// arbitrarily deep trees can't blow the call stack, matching `DirectorySizer`).
    private struct DirectoryPair {
        let left: VFSPath
        let right: VFSPath
        let prefix: String
    }

    /// The default mtime slack, in seconds. Two seconds covers FAT/exFAT's coarse timestamp
    /// resolution so a round-tripped file isn't reported as "changed" (TC uses the same).
    public static let defaultTolerance: TimeInterval = 2

    /// Compare the trees rooted at `left` and `right`, returning one `SyncEntry` per item that
    /// differs or exists on only one side, sorted by relative path.
    ///
    /// Directories present on *both* sides are descended into but produce no row of their own;
    /// a directory present on only one side yields a single row for the whole subtree (the app
    /// copies or deletes it wholesale). Items judged identical are omitted unless
    /// `includingIdentical` is set (the diff view can show a "same" filter).
    ///
    /// Listing errors are *not* swallowed: a directory that can't be read throws rather than
    /// being treated as empty — silently doing so could delete the other side's matching files
    /// in a mirror. Pass `isCancelled` to abort a large scan.
    ///
    /// - Parameter contentsEqual: the exact-equality test used in `.content` mode; defaults to
    ///   a chunked local byte comparison. Injected so the engine stays free of a read primitive
    ///   and tests can drive content mode deterministically.
    ///
    ///   That default **refuses an evicted cloud placeholder**, so a `.content` scan over a folder
    ///   holding one throws rather than materializing it: a tree sweep is not a file the user
    ///   pointed at, and reading through it would quietly download their whole cloud drive
    ///   (docs/NOTES.md). The scan stops naming the first such file, which is the same shape as a
    ///   directory that can't be listed — the user switches to `.sizeAndDate`, or downloads the
    ///   folder first. A caller that has already obtained consent injects a closure passing
    ///   `allowDataless: true`.
    public static func compare(
        left: VFSPath,
        right: VFSPath,
        leftBackend: some VFSBackend,
        rightBackend: some VFSBackend,
        comparison: SyncComparison = .sizeAndDate,
        tolerance: TimeInterval = defaultTolerance,
        includingIdentical: Bool = false,
        isCancelled: () -> Bool = { false },
        contentsEqual: (VFSPath, VFSPath) throws -> Bool = { try ByteComparator.localFilesEqual(
            $0,
            $1
        ) }
    ) throws -> [SyncEntry] {
        var results: [SyncEntry] = []
        // Whether either side's stamp may be believed is a fact about the **pair**, derived here
        // rather than asked of the caller: `compare` already holds both roots, so there is no
        // parameter for anybody to get wrong and no second spelling of the rule the sheet applies
        // when it withdraws `.sizeAndDate` (``SyncComparison/believesModificationDates(between:and:)``).
        let believesClock = comparison.believesModificationDates(
            between: left.backend,
            and: right.backend
        )
        // Asked once per side, before anything is walked: a backend with a subtree shortcut answers
        // the whole tree in one request and the walk below is served from that instead of listing a
        // directory at a time. A backend without one answers `nil` and nothing changes (``SyncSide``).
        let leftSide = try SyncSide.gather(under: left, using: leftBackend, isCancelled: isCancelled)
        let rightSide = try SyncSide.gather(
            under: right,
            using: rightBackend,
            isCancelled: isCancelled
        )
        // Work stack of directory pairs that both exist, plus their shared relative prefix.
        var stack = [DirectoryPair(left: left, right: right, prefix: "")]

        while let node = stack.popLast() {
            if isCancelled() { throw CancellationError() }
            let leftByName = try leftSide.children(
                at: node.left,
                relative: node.prefix,
                using: leftBackend
            )
            let rightByName = try rightSide.children(
                at: node.right,
                relative: node.prefix,
                using: rightBackend
            )

            for name in Set(leftByName.keys).union(rightByName.keys) {
                let relative = node.prefix.isEmpty ? name : node.prefix + "/" + name
                try classify(
                    name: name,
                    relative: relative,
                    leftEntry: leftByName[name],
                    rightEntry: rightByName[name],
                    comparison: comparison,
                    tolerance: tolerance,
                    believesClock: believesClock,
                    includingIdentical: includingIdentical,
                    contentsEqual: contentsEqual,
                    into: &results,
                    stack: &stack
                )
            }
        }

        results.sort { $0.relativePath < $1.relativePath }
        return results
    }

    /// The *actionable* choices a user may assign to one row, overriding the direction's default —
    /// the menu the diff view offers on a right-click ("flip this row the other way", "delete it
    /// instead of copying"). Each is a real operation the apply path can run, so `.none` (skip is
    /// the checkbox's job) and `.conflict` (a non-action) are deliberately absent.
    ///
    /// - A both-sides difference (`leftNewer`/`rightNewer`/`differ`) can be copied *either* way —
    ///   this is the "flip one row against the global direction" case, and it also lets the user
    ///   resolve a bidirectional `differ` conflict by hand. Deleting a file that exists on both
    ///   sides is never offered — that isn't a sync action.
    /// - A one-sided item can be propagated to the other side *or* deleted from the side it's on.
    /// - `identical` has nothing to do, and a `typeMismatch` (file-vs-directory) has no safe
    ///   automatic resolution — both return an empty list, so the diff view shows no override menu.
    public static func availableActions(for status: SyncStatus) -> [SyncAction] {
        switch status {
        case .identical, .typeMismatch: return []
        case .leftOnly: return [.copyToRight, .deleteLeft]
        case .rightOnly: return [.copyToLeft, .deleteRight]
        case .leftNewer, .rightNewer, .differ: return [.copyToRight, .copyToLeft]
        }
    }

    /// The pre-selected action for a row of the given `status` under `direction`.
    public static func defaultAction(for status: SyncStatus, direction: SyncDirection) -> SyncAction {
        // A file-vs-directory clash is never resolved automatically, whatever the direction.
        if status == .typeMismatch { return .conflict }
        switch direction {
        case .leftToRight: return mirrorAction(for: status, copy: .copyToRight, prune: .deleteRight)
        case .rightToLeft: return mirrorAction(for: status, copy: .copyToLeft, prune: .deleteLeft)
        case .bidirectional: return bidirectionalAction(for: status)
        }
    }

    // MARK: - Classification

    // swiftlint:disable:next function_parameter_count
    private static func classify(
        name: String,
        relative: String,
        leftEntry: FileEntry?,
        rightEntry: FileEntry?,
        comparison: SyncComparison,
        tolerance: TimeInterval,
        believesClock: Bool,
        includingIdentical: Bool,
        contentsEqual: (VFSPath, VFSPath) throws -> Bool,
        into results: inout [SyncEntry],
        stack: inout [DirectoryPair]
    ) throws {
        switch (leftEntry, rightEntry) {
        case let (leftEntry?, rightEntry?):
            if leftEntry.isDirectory, rightEntry.isDirectory {
                // Both directories: descend, emit no row for the container itself.
                stack.append(
                    DirectoryPair(left: leftEntry.path, right: rightEntry.path, prefix: relative)
                )
            } else if leftEntry.isDirectory != rightEntry.isDirectory {
                append(
                    name,
                    relative,
                    leftEntry,
                    rightEntry,
                    .typeMismatch,
                    includingIdentical,
                    &results
                )
            } else {
                let status = try fileStatus(
                    leftEntry, rightEntry,
                    comparison: comparison, tolerance: tolerance,
                    believesClock: believesClock, contentsEqual: contentsEqual
                )
                append(name, relative, leftEntry, rightEntry, status, includingIdentical, &results)
            }
        case let (leftEntry?, nil):
            append(name, relative, leftEntry, nil, .leftOnly, includingIdentical, &results)
        case let (nil, rightEntry?):
            append(name, relative, nil, rightEntry, .rightOnly, includingIdentical, &results)
        case (nil, nil):
            break // unreachable: the name came from a union of the two child sets
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func append(
        _ name: String,
        _ relative: String,
        _ left: FileEntry?,
        _ right: FileEntry?,
        _ status: SyncStatus,
        _ includingIdentical: Bool,
        _ results: inout [SyncEntry]
    ) {
        guard status != .identical || includingIdentical else { return }
        results.append(
            SyncEntry(relativePath: relative, name: name, left: left, right: right, status: status)
        )
    }

    // One argument past SwiftLint's ceiling, and it is `believesClock` — the pair's answer to
    // whether either listing's stamp may be read, which the doc comment below argues for.
    // swiftlint:disable function_parameter_count

    /// Classify two same-named non-directory items (files, symlinks, specials).
    ///
    /// Internal rather than private so ``recompare(_:between:and:comparison:tolerance:includingIdentical:contentsEqual:)``
    /// in the companion file can re-answer a row without walking anything — Swift's `private` does
    /// not cross files, and two spellings of what a comparison *means* is the one thing the second
    /// phase must not introduce.
    ///
    /// `believesClock` is the pair's answer, not the comparison's: see
    /// ``SyncComparison/believesModificationDates(between:and:)``.
    static func fileStatus(
        _ left: FileEntry,
        _ right: FileEntry,
        comparison: SyncComparison,
        tolerance: TimeInterval,
        believesClock: Bool,
        contentsEqual: (VFSPath, VFSPath) throws -> Bool
    ) throws -> SyncStatus {
        let equal: Bool
        switch comparison {
        case .size:
            equal = left.byteSize == right.byteSize
        case .sizeAndDate:
            equal = sizeAndDateAgree(left, right, tolerance: tolerance)
        case .content:
            // Only the pairs whose bytes decide it are read — the same rule
            // ``contentCandidates(in:)`` selects by, so what the gesture fetched and what the scan
            // reads are one definition rather than two. Everything else falls back to metadata, and
            // to *size alone* where the clock cannot be believed: over a coarse listing a symlink
            // pair would otherwise report a difference on every scan.
            if contentReadsBytes(left, right) {
                equal = try contentsEqual(left.path, right.path)
            } else if believesClock {
                equal = sizeAndDateAgree(left, right, tolerance: tolerance)
            } else {
                equal = left.byteSize == right.byteSize
            }
        }
        if equal { return .identical }
        // A comparison that cannot believe the clock must not rank with it either: `.differ` is
        // "these are not the same and nothing here can say which came later", which the mirror
        // directions still act on and the bidirectional one correctly refuses to guess at.
        guard believesClock else { return .differ }
        return newerSide(left, right, tolerance: tolerance)
    }

    // swiftlint:enable function_parameter_count

    /// The metadata equality both date-aware comparisons rest on.
    private static func sizeAndDateAgree(
        _ left: FileEntry,
        _ right: FileEntry,
        tolerance: TimeInterval
    ) -> Bool {
        left.byteSize == right.byteSize
            && abs(left.modificationDate.timeIntervalSince(right.modificationDate)) <= tolerance
    }

    /// For two items known to differ, which side is newer (or neither, within tolerance).
    private static func newerSide(_ left: FileEntry, _ right: FileEntry, tolerance: TimeInterval) -> SyncStatus {
        let delta = left.modificationDate.timeIntervalSince(right.modificationDate)
        if delta > tolerance { return .leftNewer }
        if delta < -tolerance { return .rightNewer }
        return .differ
    }

    // MARK: - Action derivation

    /// One-directional mirror toward the copy destination: an item present only at the source
    /// is copied over, any content difference is overwritten from the source (even when the
    /// destination is newer — a mirror is authoritative), and an item present only at the
    /// destination is `prune`d so the trees end up identical.
    ///
    /// `copy` is the copy that moves source→destination (`.copyToRight` for a left→right
    /// mirror); `prune` deletes on the destination side (`.deleteRight`). Source and
    /// destination-only are read off the copy direction.
    private static func mirrorAction(
        for status: SyncStatus,
        copy: SyncAction,
        prune: SyncAction
    ) -> SyncAction {
        let sourceIsLeft = copy == .copyToRight
        switch status {
        case .identical: return .none
        case .leftOnly: return sourceIsLeft ? copy : prune
        case .rightOnly: return sourceIsLeft ? prune : copy
        case .leftNewer, .rightNewer, .differ: return copy
        case .typeMismatch: return .conflict
        }
    }

    private static func bidirectionalAction(for status: SyncStatus) -> SyncAction {
        switch status {
        case .identical: return .none
        case .leftOnly, .leftNewer: return .copyToRight
        case .rightOnly, .rightNewer: return .copyToLeft
        case .differ, .typeMismatch: return .conflict
        }
    }
}
