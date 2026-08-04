import Foundation

/// Executes a recursive attributes apply (PLAN.md §M14 Slice 4) — the roots the sheet was opened on
/// plus everything inside them, one ``AttributeChangePlan`` at a time.
///
/// `ChecksumRunner`'s shape exactly, and for the same reason: a plain synchronous entry point
/// returning an `OperationReport`, progress through a throttled callback, cancellation polled
/// between items, and the caller deciding where it runs. That is what lets `FileOperationQueue`
/// schedule it beside a copy with no second scheduler.
///
/// **Local only.** Mode bits, a BSD flags word and an ACL are things a real inode has; an archive
/// member and an SFTP listing have none. A non-local job comes back as a failure rather than
/// half-working.
///
/// Nothing here decides *what* to write. The patch is turned into each item's own
/// ``AttributeDiff``, ``AttributePrivilege`` says whether it needs root, ``AttributeChangePlan``
/// orders the syscalls (the immutable unlock/relock and the group/mtime repairs included), and
/// ``FileAttributeIO`` runs them — the same tested path the flat sheet uses, once per item. What is
/// new here is the walk, the order it applies in, and the cap on what it journals.
public enum AttributeApplyRunner {
    /// Run a recursive apply over `sources` and everything they contain.
    ///
    /// - `onProgress` reports items, not bytes — nothing here moves any — so the queue bar is
    ///   determinate from the walk's own count.
    /// - `isCancelled` is polled between items. A cancel leaves every item already changed exactly
    ///   as it was changed, and the report carries them, so the partial run is still one ⌘Z. That is
    ///   the honest shape for this operation: there is no half-written file to clean up, only work
    ///   done and work not done.
    public static func run(
        _ job: AttributeApplyJob,
        sources: [FileEntry],
        using backend: any VFSBackend,
        actor: UserContext = .current(),
        onProgress: @escaping @Sendable (OperationProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> OperationReport {
        let run = Run(
            job: job,
            backend: backend,
            actor: actor,
            onProgress: onProgress,
            isCancelled: isCancelled
        )
        return run.execute(sources: sources)
    }

    /// How many items a recursive apply over `sources` would visit — the number the confirmation
    /// sheet shows before anything is touched.
    ///
    /// It walks with the *same* rules the run does, which is the whole point of it living here: a
    /// count derived some other way would be a second definition of "what is in scope", free to
    /// drift from the one that actually runs. Cheap enough to ask for — a real 5 000-entry directory
    /// listed in 16 ms (probed 2026-08-01).
    public static func count(
        sources: [FileEntry],
        target: AttributeApplyScope.Target,
        using backend: any VFSBackend,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> Int {
        walk(sources: sources, target: target, using: backend, isCancelled: isCancelled).count
    }

    // MARK: - The walk

    /// Every item in scope, in the order it must be applied in.
    ///
    /// Two rules, both load-bearing and both in ``AttributeApplyScope``: symlinks are never
    /// descended into, and the result is ordered **deepest-first** — because applying to a directory
    /// before its children makes every child path fail to resolve, and having gathered the paths
    /// first does not save it.
    static func walk(
        sources: [FileEntry],
        target: AttributeApplyScope.Target,
        using backend: any VFSBackend,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> [FileEntry] {
        var found: [FileEntry] = []
        var stack: [(entry: FileEntry, isRoot: Bool)] = sources.reversed().map { ($0, true) }
        while let item = stack.popLast() {
            if isCancelled() { return ordered(found) }
            // The roots are always in scope; the target filter governs what is *inside* them.
            // A deliberate reading rather than an oversight: the filter is about the items the user
            // never saw, while a root is the thing they opened Get Info on and edited. Excluding the
            // folder whose panel they just used because they also asked for "files only" would be
            // surprising in the one direction that matters — silently not doing what the sheet said.
            if item.isRoot || AttributeApplyScope.includes(item.entry.kind, target: target) {
                found.append(item.entry)
            }
            guard AttributeApplyScope.shouldDescend(into: item.entry) else { continue }
            let children = (try? backend.listDirectory(at: item.entry.path)) ?? []
            stack.append(contentsOf: children.reversed().map { ($0, false) })
        }
        return ordered(found)
    }

    /// Put the walk in application order, and let each item appear exactly once.
    ///
    /// The duplicate is reachable from an ordinary gesture: marking a folder *and* something inside
    /// it makes the inner item both a root and a child. Applying twice is harmless — the second pass
    /// diffs against what the first wrote and finds nothing — but the run would count it twice, so
    /// the sheet's "8 items" and the report's would disagree over a selection the user made on
    /// purpose.
    private static func ordered(_ entries: [FileEntry]) -> [FileEntry] {
        // First-seen order, not a `Dictionary`'s keys: `applicationOrder` sorts *stably*, so items
        // at equal depth keep the walk's own sequence and a re-run applies in an identical order.
        var byPath: [VFSPath: FileEntry] = [:]
        var unique: [VFSPath] = []
        for entry in entries where byPath[entry.path] == nil {
            byPath[entry.path] = entry
            unique.append(entry.path)
        }
        return AttributeApplyScope.applicationOrder(of: unique).compactMap { byPath[$0] }
    }
}

// MARK: - The run

/// One recursive apply in flight: the walk's totals, the per-item loop, and the tally the report is
/// built from. A reference type like `ChecksumRunContext`, so the loop and the progress emitter share
/// one set of counters without threading `inout` accumulators through every call.
private final class Run {
    /// Emit progress at most this often. The apply is 17 µs an item (probed), so a main-actor hop per
    /// item would flood the caller with several thousand updates a second and cost far more than the
    /// work itself.
    private static let emitInterval: TimeInterval = 0.05

    private let job: AttributeApplyJob
    private let backend: any VFSBackend
    private let actor: UserContext
    private let onProgress: @Sendable (OperationProgress) -> Void
    private let isCancelled: @Sendable () -> Bool

    private var totalItems = 0
    private var visitedItems = 0
    private var changedCount = 0
    private var journaled: [UndoRecord.AttributeBatchEntry] = []
    private var overJournalLimit = false
    private var failures: [OperationItemFailure] = []
    private var wasCancelled = false
    private var currentItem: VFSPath?
    private var lastEmit = Date.distantPast

    init(
        job: AttributeApplyJob,
        backend: any VFSBackend,
        actor: UserContext,
        onProgress: @escaping @Sendable (OperationProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        self.job = job
        self.backend = backend
        self.actor = actor
        self.onProgress = onProgress
        self.isCancelled = isCancelled
    }

    func execute(sources: [FileEntry]) -> OperationReport {
        guard sources.allSatisfy({ $0.path.backend == .local }) else {
            for source in sources where source.path.backend != .local {
                failures.append(.init(
                    path: source.path,
                    error: .unsupported(.attributesNeedLocalItem(name: source.name))
                ))
            }
            return report()
        }
        guard !job.isEmpty else { return report() }

        let items = AttributeApplyRunner.walk(
            sources: sources, target: job.target, using: backend, isCancelled: isCancelled
        )
        totalItems = items.count
        emit(force: true)

        for item in items {
            if isCancelled() {
                wasCancelled = true
                break
            }
            currentItem = item.path
            apply(to: item)
            visitedItems += 1
            emit(force: false)
        }
        emit(force: true)
        return report()
    }

    // MARK: - One item

    /// Read this item's current state, diff the patch against it, and write only what differs.
    ///
    /// An item that needs root is a **failure, not an abort**: a recursion crosses items the user
    /// may not own, and stopping the whole run at the first one would leave the tree half-changed
    /// with no way to say where it got to. Collect it, name it, carry on — the queue's own default
    /// for a per-item error, and the report lists them at the end.
    private func apply(to item: FileEntry) {
        do {
            let reading = try FileAttributeIO.read(at: item.path)
            let current = reading.attributes
            let diff = job.patch.diff(against: current)

            // The ACL is adjusted to this item's kind *before* anything is compared, so a file that
            // would receive a directory's list unchanged counts as "already matching" whenever the
            // adjusted list is what it already has — no write, no journal entry, no undo step.
            let desiredACL = job.accessControlList?.adjusted(for: item.kind)
            let existingACL = desiredACL == nil
                ? nil
                : try? AccessControlListIO.read(at: item.path, actsOnLink: reading.isSymlink)
            let aclChanges = desiredACL != nil && desiredACL != existingACL

            guard !diff.isEmpty || aclChanges else { return }

            let reasons = AttributePrivilege.reasons(
                for: diff, current: current, actor: actor, changesAccessControlList: aclChanges
            )
            if reasons.first != nil {
                failures.append(.init(
                    path: item.path,
                    error: .unsupported(.attributeChangeNeedsAdministrator(name: item.name))
                ))
                return
            }

            let plan = AttributeChangePlan(
                diff: diff,
                current: current,
                actsOnLink: reading.isSymlink,
                accessControlList: aclChanges ? desiredACL : nil
            )
            try FileAttributeIO.apply(plan, to: item.path)
            changedCount += 1
            record(item: item, reading: reading, diff: diff, oldACL: existingACL, newACL: desiredACL)
        } catch let error as VFSError {
            failures.append(.init(path: item.path, error: error))
        } catch {
            failures.append(.init(path: item.path, error: .io(path: item.path, code: 0)))
        }
    }

    /// Journal one changed item — until the cap, after which the run stops collecting and drops what
    /// it has.
    ///
    /// Dropping rather than truncating is the decision ``AttributeApplyJob/journalLimit`` argues:
    /// undoing an arbitrary slice of a tree leaves it in a state nobody can reason about, so over the
    /// limit there is no record at all. Releasing the array as soon as the limit is crossed also
    /// keeps a 200 000-item run from carrying 47 MB of undo material it will never use.
    private func record(
        item: FileEntry,
        reading: FileAttributeIO.Reading,
        diff: AttributeDiff,
        oldACL: AccessControlList?,
        newACL: AccessControlList?
    ) {
        guard !overJournalLimit else { return }
        guard journaled.count < job.journalLimit else {
            overJournalLimit = true
            journaled = []
            return
        }
        let lists: (old: AccessControlList, new: AccessControlList)? =
            if let newACL { (old: oldACL ?? AccessControlList(), new: newACL) } else { nil }
        journaled.append(.init(
            path: item.path,
            actsOnLink: reading.isSymlink,
            old: reading.attributes,
            new: job.patch.apply(to: reading.attributes),
            accessControlLists: lists
        ))
    }

    // MARK: - Progress and report

    private func emit(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastEmit) >= Self.emitInterval else { return }
        lastEmit = now
        onProgress(OperationProgress(
            totalBytes: 0,
            completedBytes: 0,
            totalItems: totalItems,
            completedItems: visitedItems,
            currentItem: currentItem
        ))
    }

    private func report() -> OperationReport {
        OperationReport(
            completedItems: changedCount,
            completedBytes: 0,
            skipped: [],
            failures: failures,
            wasCancelled: wasCancelled,
            outcomes: [],
            attributeApply: AttributeApplyOutcome(
                changed: journaled,
                changedCount: changedCount,
                visitedCount: visitedItems,
                isUndoable: !overJournalLimit
            )
        )
    }
}
