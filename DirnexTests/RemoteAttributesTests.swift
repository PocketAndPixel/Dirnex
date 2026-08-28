import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Get Info on a row that is not on this Mac (PLAN.md §M24 Slice 7).
///
/// Both halves under test are deliberately *pure*: which panel a selection deserves, and which rows
/// that panel will draw. Neither presents anything, which is the point — a test that puts a real
/// window in the test host makes it do real pane work and destabilizes its neighbours (docs/NOTES.md
/// ▸ Testing: one such test took a run from 9/9 green to 7/8).
@Suite("Remote Get Info")
@MainActor
struct RemoteAttributesTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func local(_ name: String) -> FileEntry {
        FileEntry(
            path: .local("/tmp/\(name)"),
            name: name,
            kind: .file,
            byteSize: 10,
            modificationDate: epoch,
            creationDate: epoch,
            isHidden: false,
            permissions: 0o644,
            inode: 1
        )
    }

    /// Built through the backend id's own constructor rather than a plausible-looking string: a
    /// hand-written id is one nothing can parse, and a fixture that merely *looks* real makes the
    /// test measure a fallback (docs/NOTES.md ▸ Testing, the crumb suite that read "Macintosh HD").
    private func remote(
        _ name: String,
        permissions: UInt16? = 0o644,
        owner: String? = "oleg",
        group: String? = "wheel",
        kind: FileEntry.Kind = .file,
        modified: Date? = nil,
        entityTag: String? = nil,
        symlinkDestination: String? = nil
    ) -> FileEntry {
        let backend = VFSBackendID.sftp(SFTPLocation(host: "srv", username: "oleg"))
        return FileEntry(
            path: VFSPath(backend: backend, path: "/home/oleg/\(name)"),
            name: name,
            kind: kind,
            byteSize: 10,
            modificationDate: modified ?? epoch,
            creationDate: modified ?? epoch,
            isHidden: false,
            permissions: permissions,
            ownerName: owner,
            groupName: group,
            inode: 0,
            symlinkDestination: symlinkDestination,
            entityTag: entityTag
        )
    }

    // MARK: - Which panel

    @Test("one local row opens the editing panel, several open the bulk editor")
    func localRoutesUnchanged() {
        #expect(AttributesRoute.decide(for: [local("a")]) == .single)
        #expect(AttributesRoute.decide(for: [local("a"), local("b")]) == .multiple)
    }

    @Test("one row that is not on this Mac opens the read-only panel")
    func remoteRoutesToTheReadOnlyPanel() {
        #expect(AttributesRoute.decide(for: [remote("a.txt")]) == .remote)
    }

    /// The bulk panel is an editor, so a set it cannot edit is refused rather than served short.
    /// A **mixed** set is the case the old local-only filter got quietly wrong: it dropped the
    /// remote rows and opened the editor over the rest, editing fewer items than the user marked
    /// with nothing on screen saying so.
    @Test("a marked set that is not all local is refused rather than served short")
    func mixedAndRemoteSetsAreRefused() {
        #expect(AttributesRoute.decide(for: [remote("a"), remote("b")]) == .bulkUnavailable)
        #expect(AttributesRoute.decide(for: [local("a"), remote("b")]) == .bulkUnavailable)
        #expect(AttributesRoute.decide(for: [remote("b"), local("a")]) == .bulkUnavailable)
    }

    /// An archive member is not on this Mac either, and takes the same route as a server's row.
    @Test("an archive member routes to the read-only panel too")
    func archiveMemberRoutesRemote() {
        let entry = FileEntry(
            path: VFSPath(backend: .archive(forArchiveAt: "/tmp/t.zip"), path: "/a.txt"),
            name: "a.txt",
            kind: .file,
            byteSize: 3,
            modificationDate: epoch,
            creationDate: epoch,
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
        #expect(AttributesRoute.decide(for: [entry]) == .remote)
    }

    // MARK: - Which rows reach the decision at all

    /// The route tests above call `AttributesRoute` directly, so on their own they would stay green
    /// with the `backend == .local` filter put back into ``PanelViewController/attributesTargets()``
    /// — the feature dead and every test passing. These drive the real gathering instead, which is
    /// where that filter lived.
    @Test("a row that is not on this Mac is a target rather than being filtered away")
    func remoteRowIsATarget() {
        let row = remote("a.txt")
        let (pane, host) = hostedPane(showing: [row], at: row.path.parent ?? .local("/tmp"))
        defer { _ = host }
        pane.panel.moveCursor(to: 0)

        #expect(pane.attributesTargets().map(\.name) == ["a.txt"])
        #expect(pane.canShowAttributes)
    }

    /// Marks over cursor, unchanged — and a mixed set now arrives whole rather than silently
    /// shedding its remote half on the way in.
    @Test("a marked set arrives whole, local and remote rows alike")
    func markedSetArrivesWhole() {
        let rows = [local("here.txt"), remote("there.txt")]
        let (pane, host) = hostedPane(showing: rows, at: .local("/tmp"))
        defer { _ = host }
        pane.panel.toggleMark(at: 0)
        pane.panel.toggleMark(at: 1)

        #expect(Set(pane.attributesTargets().map(\.name)) == ["here.txt", "there.txt"])
        #expect(AttributesRoute.decide(for: pane.attributesTargets()) == .bulkUnavailable)
    }

    /// The one row still excluded. `ICloudDrive` draws an **app's** name over its `Documents`
    /// folder, so a panel opened on it would describe a folder under a name that is not the
    /// folder's — which is what ``FileEntry/nameMatchesPath`` exists to say.
    @Test("a row whose name is not its path's is never a target")
    func mismatchedNameIsNotATarget() {
        let library = FileEntry(
            path: .local("/Users/x/Library/Mobile Documents/com~apple~Pages/Documents"),
            name: "Pages",
            kind: .directory,
            byteSize: 0,
            modificationDate: epoch,
            creationDate: epoch,
            isHidden: false,
            permissions: 0o755,
            inode: 2
        )
        let (pane, host) = hostedPane(showing: [library], at: .local("/tmp"))
        defer { _ = host }
        pane.panel.moveCursor(to: 0)

        #expect(pane.attributesTargets().isEmpty)
        #expect(!pane.canShowAttributes)
    }

    // MARK: - Which rows

    @Test("a row that reports everything draws every field")
    func fullyReportedRowDrawsEverything() {
        let fields = RemoteAttributesController.fields(for: remote("a.txt"))
        #expect(fields == [.location, .modified, .permissions, .owner, .group])
    }

    /// The heart of the slice. An S3 object reports no mode, no owner and no group, so the panel
    /// states none — where before the listing invented `0o644` and this panel would have drawn it
    /// as the server's own word.
    @Test("a row reporting no mode, owner or group draws none of those rows")
    func unreportedFieldsAreAbsent() {
        let fields = RemoteAttributesController.fields(
            for: remote("obj", permissions: nil, owner: nil, group: nil)
        )
        #expect(fields == [.location, .modified])
        #expect(!fields.contains(.permissions))
    }

    /// `unknownDate` is a real answer from several backends — an S3 folder is a common prefix rather
    /// than an object, so it has no `LastModified` at all — and must draw no date rather than a
    /// formatted year 1.
    @Test("a row with no modification date draws no Modified row")
    func unknownDateDrawsNoRow() {
        let fields = RemoteAttributesController.fields(
            for: remote(
                "f",
                permissions: nil,
                owner: nil,
                group: nil,
                modified: FileEntry.unknownDate
            )
        )
        #expect(fields == [.location])
    }

    @Test("an entity tag is drawn only when the listing carried one")
    func entityTagIsConditional() {
        #expect(!RemoteAttributesController.fields(for: remote("a")).contains(.entityTag))
        let tagged = remote("a", entityTag: "\"abc123\"")
        #expect(RemoteAttributesController.fields(for: tagged).contains(.entityTag))
    }

    @Test("a symlink draws where it points")
    func symlinkDrawsItsTarget() {
        let link = remote("latest", kind: .symlink, symlinkDestination: "notes.txt")
        #expect(RemoteAttributesController.fields(for: link).contains(.pointsTo))
        #expect(!RemoteAttributesController.fields(for: remote("a")).contains(.pointsTo))
    }

    /// A separator is drawn where the group changes, so the grouping has to survive a field in the
    /// middle going missing — which is the ordinary case here, not the exotic one.
    @Test("field groups stay ordered and non-decreasing however many fields are absent")
    func groupsStayOrdered() {
        for entry in [
            remote("a"),
            remote("b", permissions: nil, owner: nil, group: nil),
            remote("c", owner: nil, group: nil, entityTag: "\"t\""),
            remote("d", permissions: nil, modified: FileEntry.unknownDate)
        ] {
            let groups = RemoteAttributesController.fields(for: entry).map(\.group)
            #expect(groups == groups.sorted())
        }
    }

    // MARK: - The panel builds

    /// Everything above is a decision; this is the one test that actually constructs the view.
    ///
    /// No window is presented — `loadViewIfNeeded()` runs `loadView`, so every constraint, the notes
    /// and the footer are exercised without putting a real window in the test host, which is what
    /// destabilizes neighbouring suites (docs/NOTES.md ▸ Testing). The shapes chosen are the ones
    /// where a row is *missing*, since an absent field is the case a layout is most likely to have
    /// assumed away.
    @Test("the panel builds for every shape of row, including one that reports almost nothing")
    func panelBuildsForEveryShape() {
        for entry in [
            remote("full.txt"),
            remote("bare", permissions: nil, owner: nil, group: nil, modified: FileEntry.unknownDate),
            remote("obj", permissions: nil, owner: nil, group: nil, entityTag: "\"abc\""),
            remote("latest", kind: .symlink, symlinkDestination: "notes.txt"),
            remote("dir", kind: .directory)
        ] {
            let controller = RemoteAttributesController(entry: entry, backend: LocalBackend())
            controller.loadViewIfNeeded()
            #expect(controller.view.subviews.isEmpty == false)
        }
    }

    /// The narrowness control for the whole panel: the location is the one fact every row has, so
    /// no entry may ever produce an empty panel.
    @Test("every row draws at least where it is")
    func everyRowDrawsItsLocation() {
        for entry in [
            remote("a"),
            remote("b", permissions: nil, owner: nil, group: nil, modified: FileEntry.unknownDate),
            local("c")
        ] {
            #expect(RemoteAttributesController.fields(for: entry).first == .location)
        }
    }
}
