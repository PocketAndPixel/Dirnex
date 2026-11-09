import AppKit
import DirnexCore

/// The Synchronize window's half of the sync's record (PLAN.md §M37 Slice 8): the box that asks for
/// one, what the record says about the rows on screen, and Merge… on a row changed on both sides.
///
/// The box takes effect with the Synchronize button rather than when it is clicked, as a dialog's
/// controls do, so Cancel leaves the record alone. That is what makes unticking safe: it removes the
/// kept versions, and nothing is removed until the user commits.
extension SyncDirectoriesController {
    // MARK: - The box

    /// What pressing Synchronize does with the pair's record, `nil` for nothing.
    var recordChoice: SyncRecordChoice? {
        guard let records else { return nil }
        if keepBox.state == .on { return .keep(records) }
        return rememberedAtOpen ? .forget(records) : nil
    }

    /// Whether the box says something the record does not yet, so Synchronize has work to do even
    /// with no row to run: ticking it on two folders already in sync is how a record starts.
    var boxDiffersFromRecord: Bool {
        records != nil && (keepBox.state == .on) != rememberedAtOpen
    }

    @objc func keepBoxChanged(_ sender: NSButton) {
        updateChrome()
    }

    func makeKeepBox() -> NSView {
        keepBox.title = String(
            localized: "Keep synced versions of text files for merging",
            comment: """
            Checkbox in the Synchronize window. After a sync, the text files both folders hold are \
            kept, so a file later changed on both sides can be merged.
            """
        )
        keepBox.toolTip = String(
            localized: """
            After each sync, Dirnex keeps a copy of the text files both folders hold, so a file later \
            changed on both sides can be merged. Turning this off and synchronizing removes the copies.
            """,
            comment: "Tooltip of the Synchronize window's box that keeps synced versions of text files."
        )
        keepBox.target = self
        keepBox.action = #selector(keepBoxChanged(_:))
        keepBox.state = rememberedAtOpen ? .on : .off
        keepBox.isHidden = records == nil
        keepBox.lineBreakMode = .byTruncatingTail
        keepBox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keepBox.widthAnchor.constraint(lessThanOrEqualToConstant: 680).isActive = true
        return keepBox
    }

    // MARK: - What changed

    /// Read what the record says about the rows on screen, off the main thread, and mark them.
    ///
    /// By bytes, so what it costs is a read of the rows that differ. It runs after every set of rows,
    /// since another comparison can list files the last one did not.
    func readChanges() {
        guard let records else { return }
        changesGeneration += 1
        isReadingChanges = true
        let generation = changesGeneration
        let entries = rows.map(\.entry)
        let control = scanControl
        Task {
            let answers = await BlockingWork.run { () -> [String: SyncChange] in
                guard let record = records.store.record(for: records.pair) else { return [:] }
                return (try? record.changes(of: entries, isCancelled: { control.isStopped })) ?? [:]
            }
            finishReadingChanges(answers, generation: generation)
        }
    }

    /// Take a read's answers, unless a newer read has started or the window has gone.
    func finishReadingChanges(_ answers: [String: SyncChange], generation: Int) {
        guard generation == changesGeneration, !scanControl.isStopped else { return }
        isReadingChanges = false
        applyChanges(answers)
    }

    /// Mark the rows with what the record says. A row that has become, or stopped being, changed on
    /// both sides means something else now, so it takes the direction's default, as a direction flip
    /// does. Every other row keeps what the user chose in it.
    func applyChanges(_ fresh: [String: SyncChange]) {
        let before = changes
        changes = fresh
        rows = rows.map { row in
            let path = row.entry.relativePath
            guard (before[path]?.mergeBase != nil) != (fresh[path]?.mergeBase != nil) else { return row }
            let action = defaultAction(for: row.entry)
            return Row(entry: row.entry, action: action, included: isActionable(action))
        }
        tableView.reloadData()
        updateChrome()
    }

    func isChangedOnBoth(_ entry: SyncEntry) -> Bool {
        changes[entry.relativePath]?.mergeBase != nil
    }

    /// The direction's default for `entry`, told what the record knows about it.
    func defaultAction(for entry: SyncEntry) -> SyncAction {
        DirectorySync.defaultAction(
            for: entry.status,
            direction: direction,
            change: changes[entry.relativePath]
        )
    }

    // MARK: - Merge…

    /// The merge a row offers, or `nil` when it offers none.
    ///
    /// A merge writes both files, so both sides have to take changes. A side past 64 MiB is one the
    /// merge window would refuse to read, whatever the version kept for it.
    func mergeRequest(for row: Row) -> SyncMergeRequest? {
        guard let records, directions.contains(.bidirectional),
              let left = row.entry.left, let right = row.entry.right,
              left.kind == .file, right.kind == .file,
              left.byteSize <= ByteComparator.prescanByteLimit,
              right.byteSize <= ByteComparator.prescanByteLimit,
              let base = changes[row.entry.relativePath]?.mergeBase
        else { return nil }
        return SyncMergeRequest(
            relativePath: row.entry.relativePath,
            left: left,
            right: right,
            base: base,
            records: records
        )
    }

    @objc func mergeRow(_ sender: NSMenuItem) {
        guard let data = row(at: sender.tag), let request = mergeRequest(for: data) else { return }
        onMerge?(request)
    }
}
