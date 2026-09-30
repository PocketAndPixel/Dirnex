import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Which panes can rename, and — the half that was actually at risk — that F2/⇧F2 and their menu
/// items agree about it (PLAN.md §M21 Slice 10).
///
/// The rule had two spellings and they disagreed in **both** directions at once. The flows guarded on
/// `backend.capabilities`, which on the pane's routing `CompositeBackend` is always the *local*
/// backend's set, while `validateMenuItem` asked `capabilities(for: panel.path)` — the set of whoever
/// owns the current location. So on a connected bucket File ▸ Rename… was gray while F2 opened the
/// inline editor and renamed the object perfectly (found live 2026-08-14 against a real account, on a
/// bucket that already held a file renamed through the UI); and in the merged iCloud listing the item
/// was *enabled* over a flow that returned in silence, because those rows are ordinary local files
/// wearing the local capability set inside a listing with no directory of its own.
///
/// Both halves are pinned here, because a fix to either alone leaves the other spelling free to drift
/// back — the size-bar and `canGoToParent` lesson (docs/NOTES.md ▸ AppKit). What makes it evidence
/// rather than a restatement is that the menu answers come from the **real** `validateMenuItem` and
/// the refusals from the **real** `beginRename` / `beginMultiRename`, driven against a pane holding a
/// listing, rather than from a second copy of `canRenameHere`'s own expression.
///
/// ⇧F2's *flow* is the one thing here that is asserted structurally rather than driven, and the
/// reason belongs with the suite: `beginMultiRename` ends in `presentAsMovableWindow`, so a pane that
/// wrongly gets past the guard presents an app-modal window from a headless suite. Measured against a
/// deliberately reverted `beginMultiRename`, that did not fail the run — it **wedged** it, the test
/// host never exiting and `xcodebuild` needing to be killed at ten minutes. A control that hangs
/// instead of failing is worse than none, since it reads as infrastructure rather than as the
/// regression it is. What covers it instead is that the two flows now share the *same* guard
/// expression, plus `menuItemsAgree` over ⇧F2's own validator.
///
/// The panes are otherwise headless — both predicates read only the model and the backend — with the
/// one deliberate exception documented on `theKeyRefusesWhereTheItemIsGray`.
///
/// **The two keys stopped answering the same question on 2026-09-10**, which is why `Case` carries
/// two booleans. F2 gained a second route — a member of a writable archive renames by rewriting the
/// container — while ⇧F2's apply loop still renames each target with `backend.moveItem`, which an
/// archive answers `.unsupported` to. Pointing both at the wider gate would have enabled the batch
/// tool over a flow that fails once per item, so the asymmetry is deliberate and is pinned here:
/// this table is the only thing that would notice it being "tidied" back into one answer.

/// At file scope so the parameterized `arguments:` can read them: the suite is `@MainActor`, and a
/// static on it is main-actor-isolated where the argument list is evaluated.
private enum Remote {
    static let sftp = SFTPLocation(host: "example.com", port: 22, username: "oleg")
    static let ftp = FTPLocation(host: "example.com", username: "oleg")
    static let bucket = S3Location(
        host: "s3.eu-central-1.amazonaws.com",
        bucket: "photos",
        region: "eu-central-1",
        accessKeyID: "AKIAEXAMPLE"
    )
}

/// One row of the reach table, named rather than a tuple so the two fields cannot be read in the
/// wrong order.
private struct Case {
    let name: String
    let path: VFSPath
    /// Whether **F2** can rename the cursor row — `canRenameCursorRow`, and the item File ▸ Rename…
    /// grays itself off.
    let canRename: Bool
    /// Whether **⇧F2** can, which is no longer the same question: a member of a writable archive is
    /// renamed by rewriting the container, and the batch tool still renames each target with
    /// `backend.moveItem`, which an archive refuses. Defaults to `canRename`, so only the row where
    /// the two genuinely differ has to say so.
    let canMultiRename: Bool
    /// Applied to the routing backend before the pane is built — `nil` for a location that needs no
    /// connection (local, virtual) or is deliberately left unconnected.
    let connect: ((CompositeBackend) -> Void)?
    /// The single row the pane's listing holds. `nil` puts an ordinary file in it, named after
    /// itself; a case supplies one only when the *row* is what it is about.
    let row: FileEntry?

    init(
        _ name: String,
        _ path: VFSPath,
        canRename: Bool,
        canMultiRename: Bool? = nil,
        connect: ((CompositeBackend) -> Void)? = nil,
        row: FileEntry? = nil
    ) {
        self.canMultiRename = canMultiRename ?? canRename
        self.name = name
        self.path = path
        self.canRename = canRename
        self.connect = connect
        self.row = row
    }
}

@MainActor
@Suite("Rename's reach")
struct RenameReachTests {
    // MARK: - Fixtures

    private static func entry(_ name: String, on backend: VFSBackendID) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: backend, path: "/dir/\(name)"),
            name: name,
            kind: .file,
            byteSize: 10,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
    }

    /// A pane on `path`, routing through a real `CompositeBackend` — which is the whole point:
    /// `LocalBackend` answers its own capabilities for every path, so a pane built on one cannot
    /// tell the two spellings apart and would pass this suite however far they had drifted.
    ///
    /// The listing puts the cursor on a real entry, which both menu items need beyond the
    /// capability: rename is single-item on the cursor, the batch tool needs a non-empty selection.
    private static func pane(for testCase: Case) -> PanelViewController {
        let composite = CompositeBackend(local: LocalBackend())
        // Registering a connection touches no network — it installs the backend so the pane can
        // route to it (`CompositeBackendTests`).
        testCase.connect?(composite)
        let pane = PanelViewController(
            backend: composite,
            restoration: nil,
            defaultPath: testCase.path,
            restorationKey: nil
        )
        pane.panel = Panel(model: DirectoryModel(listing: DirectoryListing(
            path: testCase.path,
            entries: [testCase.row ?? entry("notes.txt", on: testCase.path.backend)]
        )))
        return pane
    }

    /// The merged iCloud listing's app-library row: an app's name over its `Documents` folder, which
    /// `ICloudDrive.libraryRow(for:stat:)` calls the one place in the codebase where a row's name and
    /// its path disagree.
    fileprivate static let iCloudLibraryRow = FileEntry(
        path: .local(NSHomeDirectory() + "/Library/Mobile Documents/com~apple~Pages/Documents"),
        name: "Pages",
        kind: .directory,
        byteSize: 0,
        modificationDate: Date(timeIntervalSince1970: 0),
        creationDate: Date(timeIntervalSince1970: 0),
        isHidden: false,
        permissions: 0o755,
        inode: 0
    )

    /// An ordinary local file, for the rows a synthesized listing draws beside that one.
    fileprivate static let looseFile = FileEntry(
        path: .local(NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/notes.txt"),
        name: "notes.txt",
        kind: .file,
        byteSize: 10,
        modificationDate: Date(timeIntervalSince1970: 0),
        creationDate: Date(timeIntervalSince1970: 0),
        isHidden: false,
        permissions: 0o644,
        inode: 0
    )

    /// The same file, in the home trash — where the capability, not the listing, refuses it.
    fileprivate static let trashedFile = FileEntry(
        path: .local(NSHomeDirectory() + "/.Trash/notes.txt"),
        name: "notes.txt",
        kind: .file,
        byteSize: 10,
        modificationDate: Date(timeIntervalSince1970: 0),
        creationDate: Date(timeIntervalSince1970: 0),
        isHidden: false,
        permissions: 0o644,
        inode: 0
    )

    private static func menuItem(_ action: Selector) -> NSMenuItem {
        let item = NSMenuItem()
        item.action = action
        return item
    }

    // MARK: - The table

    /// Every location a pane can stand in, and whether renaming is offered there.
    ///
    /// The two rows this milestone changed sit beside the ones that must not move, deliberately: a
    /// capability widened too far is how this goes wrong in the other direction, and the archive /
    /// search / Trash rows are what keep "anything not local" from passing.
    private static let cases: [Case] = [
        Case("a folder on this Mac", .local("/Users/tester/Documents"), canRename: true),
        // The bug. A bucket renames an object with a server-side copy and a delete.
        Case(
            "a connected bucket",
            VFSPath(backend: .s3(Remote.bucket), path: "/dir"),
            canRename: true,
            connect: { $0.connectS3(location: Remote.bucket, secretAccessKey: "secret") }
        ),
        Case(
            "a connected SFTP account",
            VFSPath(backend: .sftp(Remote.sftp), path: "/home/oleg/dir"),
            canRename: true,
            connect: {
                $0.connectSFTP(location: Remote.sftp, authentication: .key(identityFile: "/tmp/k"))
            }
        ),
        Case(
            "a connected FTP account",
            VFSPath(backend: .ftp(Remote.ftp), path: "/pub/dir"),
            canRename: true,
            connect: { $0.connectFTP(location: Remote.ftp, authentication: .anonymous) }
        ),
        // No credential, so there is nothing to rename *with*: gray it rather than offer a write
        // that cannot be performed, exactly as the other remote writes degrade.
        Case(
            "a bucket with no live connection",
            VFSPath(backend: .s3(Remote.bucket), path: "/dir"),
            canRename: false
        ),
        // A bucket is not renameable at any level, which `S3AccountBackendTests` pins at the
        // backend and this pins at the pane.
        Case(
            "an account pane, whose rows are buckets",
            VFSPath(backend: .s3Account(Remote.bucket.account), path: "/"),
            canRename: false,
            connect: {
                $0.connectS3Account(account: Remote.bucket.account, secretAccessKey: "secret")
            }
        ),
        // The one row in this app whose name is not its file's: an app library in the merged iCloud
        // listing draws "Pages" over a folder called `Documents`. The capability says yes — it is an
        // ordinary local folder — so `nameMatchesPath` is the whole of the refusal, and it is the
        // only thing the old `!isVirtualDirectory` gate was right about.
        Case(
            "an app library row in the merged iCloud listing",
            VFSPath(backend: .icloud, path: "/"),
            canRename: false,
            row: iCloudLibraryRow
        ),
        // Everything standing beside it. These four were refused for a property of their
        // *container* until 2026-08-22; each is an ordinary file in an ordinary directory, and the
        // rename lands in that directory rather than in the synthetic one.
        Case(
            "a loose file in the merged iCloud listing",
            VFSPath(backend: .icloud, path: "/"),
            canRename: true,
            row: looseFile
        ),
        Case(
            "a search-results listing",
            VFSPath(backend: .search, path: "/Results"),
            canRename: true,
            row: looseFile
        ),
        // Not a virtual-listing refusal at all: a trash withdraws `.rename`, because Put Back is
        // keyed on the name in the trash and renaming a trashed item orphans its `.DS_Store`
        // record. The same answer for a pane standing in `~/.Trash` itself, below.
        Case(
            "the merged Trash",
            VFSPath(backend: .trash, path: "/Trash"),
            canRename: false,
            row: trashedFile
        ),
        Case(
            "a pane standing inside ~/.Trash",
            .local(NSHomeDirectory() + "/.Trash"),
            canRename: false,
            row: trashedFile
        ),
        // F2 renames a member by rewriting the container (`ArchiveWriter.rename`), which is why
        // this row moved; ⇧F2 renames each target with `backend.moveItem`, which an archive
        // refuses, so it stays gray. The one place the two answers differ, and it is deliberate —
        // see `renameRoute(for:)`.
        Case(
            "a browsed archive",
            VFSPath(backend: .archive(forArchiveAt: "/Users/tester/pkg.zip"), path: "/inner"),
            canRename: true,
            canMultiRename: false
        )
    ]

    // MARK: - The predicate

    @Test("renaming is offered exactly where the backend can do it in a real directory")
    func reach() {
        for testCase in Self.cases {
            let pane = Self.pane(for: testCase)
            #expect(pane.canRenameCursorRow == testCase.canRename, "F2 in \(testCase.name)")
            #expect(
                pane.canRenameHere == testCase.canMultiRename, "⇧F2 in \(testCase.name)"
            )
        }
    }

    // MARK: - The menu items agree with it

    /// The **real** validator, driven against a pane whose cursor stands on an entry. Both selectors,
    /// because they are two menu items over one rule and the fix is that they read one property —
    /// asserting only F2's would leave ⇧F2 free to keep its own copy.
    @Test("File ▸ Rename… and Multi-Rename are enabled exactly there")
    func menuItemsAgree() {
        for testCase in Self.cases {
            let pane = Self.pane(for: testCase)
            let rename = pane.validateMenuItem(
                Self.menuItem(#selector(PanelViewController.renameSelection(_:)))
            )
            let multi = pane.validateMenuItem(
                Self.menuItem(#selector(PanelViewController.multiRenameSelection(_:)))
            )
            #expect(rename == testCase.canRename, "File ▸ Rename… in \(testCase.name)")
            #expect(multi == testCase.canMultiRename, "Multi-Rename in \(testCase.name)")
        }
    }

    // MARK: - And so does the key

    /// The half a validator test cannot reach, and the half that was wrong on S3: the flow behind the
    /// key must refuse wherever the item is gray. `renamingEntryID` is the observable, because
    /// `beginRename` sets it the moment it commits to the edit and before every view call.
    ///
    /// **The view has to be loaded, or this assertion is inert.** `tableView` is a stored property, so
    /// an unloaded pane has one — with no columns, since `configureTable` runs in `loadView`. A pane
    /// that has wrongly got past the capability guard then returns at `nameColumnDisplayIndex` instead,
    /// leaving `renamingEntryID` nil and the test green (measured: the whole suite passes against a
    /// deliberately reverted `beginRename` without this line). Loading gives the table its Name column,
    /// so the only thing left that can stop the edit is the guard under test.
    ///
    /// Only the refusals are driven. A flow that proceeds swaps an editable field into a live table,
    /// which needs a window to hold first responder; that direction is covered by the menu items above,
    /// and live.
    @Test("F2 refuses wherever its menu item is gray")
    func theKeyRefusesWhereTheItemIsGray() {
        for testCase in Self.cases where !testCase.canRename {
            let pane = Self.pane(for: testCase)
            pane.loadViewIfNeeded()
            pane.beginRename()
            #expect(pane.renamingEntryID == nil, "F2 in \(testCase.name)")
        }
    }
}
