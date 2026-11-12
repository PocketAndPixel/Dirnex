import AppKit
import DirnexCore

/// Whether an edited member changed inside its archive since the edit began, and what the archive's
/// question says about it (PLAN.md §M37 Slice 4).
///
/// Until this, a save back rewrote the archive with the copy whatever had happened to the archive
/// meanwhile, so another app's change to the same member was replaced without a word. Now each
/// member whose archive moved since its base was read is read again, and the question says what that
/// found, as the server prompt does: one changed member is offered Merge… first, and a set with
/// changed members is offered Skip Changed Files. A member with no base, such as one opened before
/// this slice or by a gesture that wrote its copy first, keeps the question it always had.
extension BrowserWindowController {
    // MARK: - The check

    /// What the archive holds of each member of `group`, against the base kept for its copy. Reads
    /// the members only where the archive moved, all in one extraction.
    ///
    /// With the passphrase this window was given, and no prompt: the watcher raised this, not the
    /// user, so an encrypted archive nobody unlocked reads as a member that could not be checked.
    func checkArchiveMembers(_ group: ArchiveWriteBackGroup) async -> [ArchiveMemberVerdict] {
        let members = group.items.map {
            ArchiveMemberCheck.Member(
                innerPath: $0.innerPath,
                base: archivePreviewCache.memberBase(ofCopy: $0.edit.temporaryURL)
            )
        }
        let check = archiveMemberCheck(
            for: group.archivePath,
            passphrase: archivePassphrases.passphrase(forArchiveAt: group.archivePath)
        )
        return await BlockingWork.run { check.verdicts(for: members) }
    }

    /// The check over the archive at `archivePath`, extracting with `passphrase` and the code page
    /// the focused pane was told the names are in.
    func archiveMemberCheck(
        for archivePath: String,
        passphrase: ArchivePassphrase?
    ) -> ArchiveMemberCheck {
        Self.archiveMemberCheck(
            for: archivePath,
            passphrase: passphrase,
            nameEncoding: focusedPanel.declaredNameEncoding(forArchiveAt: archivePath)
        )
    }

    /// The check over the archive at `archivePath`, extracting through `ArchiveExtractor`, which
    /// is what F4 extracted the copy with. `static` so a test can run it over a real archive.
    nonisolated static func archiveMemberCheck(
        for archivePath: String,
        passphrase: ArchivePassphrase?,
        nameEncoding encoding: ArchiveNameEncoding?
    ) -> ArchiveMemberCheck {
        ArchiveMemberCheck(archivePath: archivePath) { innerPaths in
            let extraction = try ArchiveExtractor.extract(
                innerPaths: innerPaths,
                fromArchiveAt: archivePath,
                passphrase: passphrase,
                nameEncoding: encoding
            )
            return ArchiveMemberCheck.Placed(
                directory: extraction.directory,
                files: extraction.extractedPaths.map { URL(fileURLWithPath: $0) }
            )
        }
    }

    // MARK: - Whether Merge… is offered

    /// The base a merge of `group`'s one member starts from, or `nil` when Merge… cannot work.
    func archiveMergeBase(
        _ group: ArchiveWriteBackGroup,
        verdicts: [ArchiveMemberVerdict]
    ) async -> URL? {
        guard group.items.count == 1, let item = group.items.first else { return nil }
        return await Self.archiveMergeBase(
            archivePreviewCache.memberBase(ofCopy: item.edit.temporaryURL)?.base,
            yours: item.edit.temporaryURL,
            verdict: verdicts.first
        )
    }

    /// `base`, when Merge… can work from it: the member changed inside the archive, it is small
    /// enough for the window to read, and `base` and the copy at `yours` both read as text. The
    /// archive's version is read again when Merge… is pressed, and checked then. `static` so the
    /// decision is assertable with no window.
    static func archiveMergeBase(
        _ base: URL?,
        yours: URL,
        verdict: ArchiveMemberVerdict?
    ) async -> URL? {
        guard let base, case let .different(byteSize) = verdict, mergeReads(byteSize: byteSize)
        else { return nil }
        let readable = await BlockingWork.run {
            (try? ComparedDocument.read(contentsOf: base)) != nil
                && (try? ComparedDocument.read(contentsOf: yours)) != nil
        }
        return readable ? base : nil
    }

    // MARK: - The question

    /// The question's buttons in the order it draws them: the server prompt's, so Merge… is first
    /// where it is offered, Skip Changed Files appears where some members are clean and some are
    /// not, and Keep Editing is always last.
    static func archivePromptAnswers(
        verdicts: [ArchiveMemberVerdict],
        offersMerge: Bool
    ) -> [WriteBackAnswer] {
        let contested = verdicts.count(where: \.isConcern)
        return promptAnswers(
            offersSkip: contested > 0 && contested < verdicts.count,
            offersMerge: offersMerge
        )
    }

    /// Each answer's button in the archive's question.
    static func archiveButtonTitle(for answer: WriteBackAnswer) -> String {
        switch answer {
        case .merge:
            mergeButtonTitle
        case .all:
            String(
                localized: "Save Back",
                comment: "Button that writes an edited member back into its archive."
            )
        case .clean:
            skipChangedFilesTitle
        case .none:
            String(
                localized: "Keep Editing",
                comment: """
                Button that declines writing an edited member back, leaving the editor open so the \
                user can save again later.
                """
            )
        }
    }

    /// What saving back will do, with what the check found in front of it and what Merge… does
    /// after it. With nothing found, the body is the one the question always had.
    static func archiveWriteBackBody(
        _ group: ArchiveWriteBackGroup,
        verdicts: [ArchiveMemberVerdict],
        undoable: Bool,
        offersMerge: Bool
    ) -> String {
        let body = archiveWriteBackBody(group, undoable: undoable)
        guard let concern = archiveConcern(group, verdicts: verdicts) else { return body }
        let concerned = "\(concern) \(body)"
        return offersMerge ? archiveMergeOfferBody(concerned) : concerned
    }

    /// The sentence saying what the check found, or `nil` when it found nothing to say.
    ///
    /// One member is named, the way the title names it. A set says how many and names the first
    /// few, as the server batch does.
    static func archiveConcern(
        _ group: ArchiveWriteBackGroup,
        verdicts: [ArchiveMemberVerdict]
    ) -> String? {
        let contested = zip(group.items, verdicts).filter { $0.1.isConcern }
        guard let first = contested.first else { return nil }
        guard group.items.count > 1 else {
            let name = first.0.edit.name
            guard case .different = first.1 else {
                return String(
                    localized: """
                    The archive has changed since you opened this file, and Dirnex couldn’t read \
                    the file in it to tell whether it changed too.
                    """,
                    comment: """
                    Archive write-back prompt, before the usual body, when the archive changed and \
                    the edited member could not be read from it again.
                    """
                )
            }
            return String(
                localized: """
                “\(name)” has also changed inside the archive since you opened it, so saving your \
                copy back replaces that change.
                """,
                comment: """
                Archive write-back prompt, before the usual body, when the edited member changed \
                inside the archive since it was opened; %@ is the file's name.
                """
            )
        }
        guard contested.count < group.items.count else {
            return String(
                localized: """
                Dirnex couldn’t confirm that any of these files is still in the archive as you \
                opened it: something may have changed them, or the check couldn’t be made.
                """,
                comment: """
                Archive write-back prompt over several members, before the usual body, when every \
                one of them changed inside the archive or could not be read from it again.
                """
            )
        }
        let count = contested.count
        let names = contested.prefix(3).map(\.0.edit.name).joined(separator: ", ")
        return String(
            localized: """
            \(count) of them have changed inside the archive since you opened them, or couldn’t \
            be checked (\(names)). The rest are as you left them.
            """,
            comment: """
            Archive write-back prompt over several members, before the usual body, naming how many \
            changed inside the archive or could not be read from it; %1$lld is the count, %2$@ the \
            first few names.
            """
        )
    }

    /// A prompt's body with the sentence saying what Merge… does after it.
    static func archiveMergeOfferBody(_ body: String) -> String {
        String(
            localized: """
            \(body) Merge… reads the archive’s version beside yours, so both edits can be kept.
            """,
            comment: """
            Archive write-back prompt body when a merge is offered; %@ is the prompt's own body, \
            which says the member changed inside the archive.
            """
        )
    }
}

extension PendingArchiveWriteBack {
    /// The member's path inside the archive: its folder there and the copy's name.
    var innerPath: String {
        innerDirectory == "/" ? "/\(edit.name)" : "\(innerDirectory)/\(edit.name)"
    }
}

extension ArchiveWriteBackPlan {
    /// `group` without the members the check found something to say about: what Skip Changed Files
    /// writes back. The others stay watched, so each one's next save asks again on its own.
    static func uncontested(
        _ group: ArchiveWriteBackGroup,
        verdicts: [ArchiveMemberVerdict]
    ) -> ArchiveWriteBackGroup {
        ArchiveWriteBackGroup(
            archivePath: group.archivePath,
            items: zip(group.items, verdicts).filter { !$0.1.isConcern }.map(\.0)
        )
    }
}
