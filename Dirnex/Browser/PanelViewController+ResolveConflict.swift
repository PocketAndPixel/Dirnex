import AppKit
import DirnexCore

/// The conflicted file Resolve Conflict… acts on, and where it sits in its repository.
struct ConflictTarget: Sendable, Equatable {
    let entry: FileEntry
    let repositoryRoot: VFSPath
    /// Relative to `repositoryRoot`, as git names it.
    let relativePath: String
}

/// The versions of a conflicted file read for its merge, and the file Save writes as it was before
/// they were read.
struct ConflictDocuments: Sendable {
    let operation: GitOperation
    /// An empty document when both sides added the file.
    let base: ComparedDocument
    let hasBase: Bool
    let yours: ComparedDocument
    let theirs: ComparedDocument
    let target: ComparedFileSave.Target
}

/// Why a conflicted file's merge did not open.
enum ConflictReadFailure: Error, Equatable {
    case git(GitConflictReader.Failure)
    case text(CompareReadFailure)
}

/// Resolve Conflict… on a file git has badged U (PLAN.md §M34 Slice 5): the merge window, opened
/// on the three versions git holds of it, saving over the conflicted file in the working tree.
///
/// The versions come out of git through `GitConflictReader`, each as a checkout would write it,
/// and nothing Dirnex runs writes to the repository. Save writes the working-tree file and nothing
/// else, so the U badge stays until the user stages the file with `git add`, which is how git
/// itself is told a conflict is resolved. The save goes into the undo store and this pane's
/// journal as the compare window's does, so ⌘Z puts the conflicted file back.
///
/// What has no one file to merge is refused by name before a byte is read: a side that deleted the
/// file, a name only one side has, a link or a submodule, and a version too large for the window.
extension PanelViewController {
    /// The one file Resolve Conflict… acts on, or `nil` when the selection is not one.
    var conflictTarget: ConflictTarget? {
        Self.conflictTarget(in: selectionTargets(), snapshot: gitSnapshot)
    }

    /// The target among `targets` when there is exactly one, it is not a folder, and `snapshot`
    /// badges it U. A folder's U is the roll-up of a conflict somewhere inside it, which has no
    /// three versions of its own.
    nonisolated static func conflictTarget(
        in targets: [FileEntry],
        snapshot: GitStatusSnapshot?
    ) -> ConflictTarget? {
        guard targets.count == 1, let entry = targets.first, !entry.isDirectory, let snapshot,
              let relativePath = snapshot.relativePath(for: entry.path), !relativePath.isEmpty,
              snapshot.status(forRelativePath: relativePath) == .conflicted else { return nil }
        return ConflictTarget(
            entry: entry,
            repositoryRoot: snapshot.repositoryRoot,
            relativePath: relativePath
        )
    }

    /// Resolve Conflict…: read the versions off the main thread and open the merge window on them,
    /// or say why not. A merge window already open on the file comes forward instead.
    @objc func resolveConflict(_ sender: Any?) {
        guard let target = conflictTarget else { return NSSound.beep() }
        if let open = MergeWindowController.open.first(where: {
            $0.input.target.path == target.entry.path.path
        }) {
            open.showWindow(nil)
            return
        }
        Task {
            let read = await BlockingWork.run { Self.readConflict(target) }
            switch read {
            case let .success(documents):
                MergeWindowController.present(
                    Self.mergeInput(for: target, documents),
                    saving: MergeSaving(undo: compareSaving.undo, journal: compareSaving.journal)
                )
            case let .failure(failure):
                presentCompareFailure(
                    message: Self.resolveFailureTitle(target.entry.name),
                    detail: Self.resolveFailureDetail(failure)
                )
            }
        }
    }

    /// The versions of `target` from git, decoded as text, and its working-tree file as it was
    /// just before they were read, which the window's save is checked against. Blocking; call it
    /// off the main thread.
    nonisolated static func readConflict(
        _ target: ConflictTarget,
        transport: some GitTransport = GitProcessTransport()
    ) -> Result<ConflictDocuments, ConflictReadFailure> {
        let path = target.entry.path.path
        let saveTarget = ComparedFileSave.Target.reading(path)
        let versions: GitConflictVersions
        do {
            versions = try GitConflictReader.read(
                target.relativePath,
                inRepositoryAt: target.repositoryRoot.path,
                byteLimit: ByteComparator.prescanByteLimit,
                transport: transport,
                exists: { FileManager.default.fileExists(atPath: $0) }
            )
        } catch {
            return .failure(.git(error))
        }
        do {
            return try .success(ConflictDocuments(
                operation: versions.operation,
                base: ComparedDocument.decode(versions.base ?? Data()),
                hasBase: versions.base != nil,
                yours: ComparedDocument.decode(versions.ours),
                theirs: ComparedDocument.decode(versions.theirs),
                target: saveTarget
            ))
        } catch {
            return .failure(.text(CompareReadFailure(name: target.entry.name, reason: error)))
        }
    }

    /// What the merge window is opened on: each version named for what it is in the operation in
    /// progress, and the result saved over the working-tree file.
    nonisolated static func mergeInput(for target: ConflictTarget, _ documents: ConflictDocuments) -> MergeInput {
        let name = target.entry.name
        let opening = documents.yours.text(ofFirstLines: SyntaxLanguage.contentsLineLimit)
        return MergeInput(
            name: name,
            base: MergeVersion(
                detail: documents.hasBase ? conflictBaseDetail : conflictNoBaseDetail,
                document: documents.base
            ),
            yours: MergeVersion(
                detail: conflictYoursDetail(documents.operation),
                document: documents.yours
            ),
            theirs: MergeVersion(
                detail: conflictTheirsDetail(documents.operation),
                document: documents.theirs
            ),
            target: documents.target,
            resultDetail: conflictResultDetail,
            language: SyntaxLanguage.forFile(named: name, text: opening)
        )
    }
}
