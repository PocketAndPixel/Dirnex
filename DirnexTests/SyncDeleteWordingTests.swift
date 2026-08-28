import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// What a sync tells the user its deletions will do, now that the two sides can disagree about it
/// (PLAN.md §M25 Slice 5c).
///
/// The sentence is the subject rather than the deleting: it is what somebody reads *while deciding*,
/// and until the gate widened it promised the Trash unconditionally — true while both sides were on
/// this disk and a straight lie about a server, where no backend implements `trashItem` and the
/// files are gone.
@Suite("Sync: what the delete confirmation says")
@MainActor
struct SyncDeleteWordingTests {
    private static let local = VFSPath.local("/Users/oleg/docs/old.txt")
    private static let remote = VFSPath(
        backend: .sftp(SFTPLocation(host: "example.test", username: "oleg")),
        path: "/srv/backup/old.txt"
    )
    private static let insideArchive = VFSPath(
        backend: .archive(forArchiveAt: "/tmp/a.zip"),
        path: "/old.txt"
    )

    private func title(_ plan: SyncDeletePlan) -> String {
        PanelViewController.deleteConfirmationTitle(for: plan)
    }

    private func body(_ plan: SyncDeletePlan) -> String {
        PanelViewController.deleteConfirmationBody(for: plan)
    }

    /// Whether the *running* app resolves to English. The app test target inherits whichever
    /// `AppleLanguages` the developer has Dirnex pinned to (docs/NOTES.md ▸ Localization), so an
    /// assertion over English wording is true only here — while the structural claims below hold in
    /// all fourteen and are what this suite really rests on.
    private var readsEnglish: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true
    }

    /// Unchanged, and deliberately so: a purely local sync keeps the sentence it always had, down to
    /// the catalog key, so fourteen translations survive a change that is not about them.
    @Test("a local run still promises the Trash and says it can be undone")
    func localRunPromisesTheTrash() {
        let plan = SyncDeletePlan(toTrash: [Self.local])
        #expect(body(plan) == String(
            localized: "You can restore them from the Trash later.",
            comment: "Sync delete confirmation body."
        ))
        if readsEnglish {
            #expect(title(plan).contains("Trash"))
        }
    }

    /// The bug this slice exists for. Nothing in the sentence may promise a Trash, and the body has
    /// to say the deletion cannot be taken back.
    @Test("a run entirely on a server never promises a Trash")
    func remoteRunPromisesNoTrash() {
        let plan = SyncDeletePlan(permanent: [Self.remote])
        let trashRun = SyncDeletePlan(toTrash: [Self.local])
        // The claim that holds in every language: this is not the sentence a Trash-bound run shows.
        #expect(title(plan) != title(trashRun))
        #expect(body(plan) != body(trashRun))
        if readsEnglish {
            #expect(!title(plan).contains("Trash"))
            #expect(title(plan).contains("permanently"))
            #expect(body(plan).contains("for good"))
            #expect(!body(plan).contains("restore"))
        }
    }

    /// The ordinary shape once the gate is widened — a local pane against an account — and the one a
    /// single sentence cannot describe: half of these come back and half do not.
    @Test("a mixed run names both halves and counts them separately")
    func mixedRunNamesBothHalves() {
        let plan = SyncDeletePlan(toTrash: [Self.local], permanent: [Self.remote])
        let body = body(plan)
        // Both halves are present, whatever they say: a mixed run is the one shape a single
        // sentence cannot describe, since half of these come back and half do not.
        #expect(body.contains(self.body(SyncDeletePlan(permanent: [Self.remote]))))
        #expect(body != self.body(SyncDeletePlan(toTrash: [Self.local])))
        #expect(title(plan).contains("2"))
        if readsEnglish {
            #expect(body.contains("Trash"))
            #expect(body.contains("for good"))
            // Each sentence carries exactly one count, which is what keeps every plural variation
            // expressible without the `substitutions` machinery (docs/NOTES.md ▸ Localization).
            #expect(body.contains("1 item"))
        }
    }

    /// An item nothing is going to touch must be named and must not be counted as deleted.
    @Test("items that cannot be deleted are named and left out of the count")
    func unsupportedItemsAreNamedNotCounted() {
        let plan = SyncDeletePlan(toTrash: [Self.local], unsupported: [Self.insideArchive])
        // One deleted item, not two — the skipped one is named in the body and counted nowhere.
        #expect(title(plan).contains("1"))
        #expect(body(plan) != body(SyncDeletePlan(toTrash: [Self.local])))
        if readsEnglish {
            #expect(body(plan).contains("left alone"))
        }
    }

    /// A read-only side cannot be pruned, and the run must not claim otherwise.
    @Test("a plan of nothing but unsupported items deletes nothing")
    func unsupportedOnlyPlanIsEmpty() {
        #expect(SyncDeletePlan(unsupported: [Self.insideArchive]).isEmpty)
    }

    // MARK: - The set the sentence counts is the set the run deletes

    private static func entry(_ path: VFSPath) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: .file,
            byteSize: 0,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
    }

    private static func decision(
        left: VFSPath?,
        right: VFSPath?,
        action: SyncAction
    ) -> SyncDirectoriesController.Decision {
        SyncDirectoriesController.Decision(
            entry: SyncEntry(
                relativePath: "old.txt",
                name: "old.txt",
                left: left.map(entry),
                right: right.map(entry),
                status: .differ
            ),
            action: action
        )
    }

    /// One derivation, read by the confirmation and by the run, so the sentence cannot count a set
    /// the deletion does not use.
    @Test("delete targets take each side's own path, and copies contribute none")
    func deleteTargetsPickTheRightSide() {
        let targets = PanelViewController.deleteTargets(in: [
            Self.decision(left: Self.local, right: Self.remote, action: .deleteLeft),
            Self.decision(left: Self.local, right: Self.remote, action: .deleteRight),
            Self.decision(left: Self.local, right: Self.remote, action: .copyToRight),
            Self.decision(left: Self.local, right: Self.remote, action: .conflict),
            Self.decision(left: Self.local, right: Self.remote, action: .none)
        ])
        #expect(targets == [Self.local, Self.remote])
    }

    @Test("a one-sided row contributes nothing when the missing side is the one being deleted")
    func aMissingSideContributesNothing() {
        let targets = PanelViewController.deleteTargets(in: [
            Self.decision(left: nil, right: Self.remote, action: .deleteLeft)
        ])
        #expect(targets.isEmpty)
    }
}
