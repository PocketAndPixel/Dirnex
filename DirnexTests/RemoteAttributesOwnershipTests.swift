import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// What both owner-and-group suites build their panels from.
@MainActor
enum RemoteOwnershipPanelFixture {
    static let backendID = VFSBackendID.sftp(SFTPLocation(host: "srv", username: "oleg"))
    static let member = RemoteAccountIdentity(
        user: RemotePrincipal(name: "oleg", id: 501),
        groups: [RemotePrincipal(name: "staff", id: 20), RemotePrincipal(name: "admin", id: 80)]
    )
    static let root = RemoteAccountIdentity(
        user: RemotePrincipal(name: "root", id: 0),
        groups: [RemotePrincipal(name: "root", id: 0)]
    )

    static func entry(
        permissions: UInt16 = 0o644,
        owner: String? = "oleg",
        group: String? = "staff",
        on backend: VFSBackendID? = nil
    ) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: backend ?? backendID, path: "/home/oleg/report.txt"),
            name: "report.txt",
            kind: .file,
            byteSize: 10,
            modificationDate: Date(timeIntervalSince1970: 1_000_000),
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: permissions,
            ownerName: owner,
            groupName: group,
            inode: 1
        )
    }

    static func panel(
        _ entry: FileEntry,
        identity: RemoteAccountIdentity?
    ) -> (RemoteAttributesController, WritingBackend) {
        let backend = WritingBackend(id: entry.path.backend, offers: .sftp)
        let controller = RemoteAttributesController(
            entry: entry,
            backend: backend,
            editability: RemoteAttributeEditability.decide(
                for: entry,
                capabilities: backend.editableMetadata(at: entry.path),
                identity: identity
            ),
            identity: identity
        )
        controller.loadViewIfNeeded()
        return (controller, backend)
    }

    /// Every piece of text the panel draws, the notes included.
    static func texts(in controller: RemoteAttributesController) -> [String] {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        return all(controller.view).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    /// Poll rather than spinning the run loop (docs/NOTES.md ▸ Testing).
    static func settle(until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(predicate())
    }
}

/// Owner and group in a remote Get Info (PLAN.md §M38 Slice 2).
///
/// The rules behind these controls are the core's, and tested there. What is pinned here is what
/// nothing else can see: which control each account gets, what it starts on, and that Save sends
/// the steps those controls spell.
@Suite("Remote Get Info ▸ owner and group")
@MainActor
struct RemoteAttributesOwnershipTests {
    private typealias Fixture = RemoteOwnershipPanelFixture
    private let member = Fixture.member
    private let root = Fixture.root

    private func entry(
        permissions: UInt16 = 0o644,
        owner: String? = "oleg",
        group: String? = "staff"
    ) -> FileEntry {
        Fixture.entry(permissions: permissions, owner: owner, group: group)
    }

    private func panel(
        _ entry: FileEntry,
        identity: RemoteAccountIdentity?
    ) -> (RemoteAttributesController, WritingBackend) {
        Fixture.panel(entry, identity: identity)
    }

    private func settle(until predicate: () -> Bool) async throws {
        try await Fixture.settle(until: predicate)
    }

    // MARK: - Which control

    @Test("an account that owns the item picks among its own groups")
    func memberGetsThePopup() throws {
        let (controller, _) = panel(entry(), identity: member)
        let popup = try #require(controller.groupPopup)
        #expect(popup.itemTitles == ["staff", "admin"])
        #expect(popup.titleOfSelectedItem == "staff")
        #expect(controller.ownerField == nil)
        #expect(controller.groupField == nil)
        // The narrowness half: opening the panel is not a change.
        #expect(controller.pendingChange.isEmpty)
        #expect(Fixture.texts(in: controller).contains("oleg"))
    }

    @Test("an item in a group the account is not in still shows that group")
    func strangerGroupIsShown() throws {
        let (controller, _) = panel(entry(group: "wheel"), identity: member)
        let popup = try #require(controller.groupPopup)
        #expect(popup.itemTitles == ["wheel", "staff", "admin"])
        #expect(popup.titleOfSelectedItem == "wheel")
        #expect(controller.pendingChange.isEmpty)
    }

    @Test("a listing's number selects the group it stands for")
    func numericListingSelectsTheGroup() throws {
        // A search hit comes from `ls -ldn`, which prints numbers where the pane's listing has names.
        let (controller, _) = panel(entry(owner: "501", group: "80"), identity: member)
        let popup = try #require(controller.groupPopup)
        #expect(popup.titleOfSelectedItem == "admin")
        #expect(controller.pendingChange.isEmpty)
    }

    @Test("two groups with one name are offered once, and picking it sends that name")
    func sharedNameIsOfferedOnce() throws {
        // A directory service can give two numbers one name, and `chown` is handed the name.
        let identity = RemoteAccountIdentity(
            user: RemotePrincipal(name: "oleg", id: 501),
            groups: [
                RemotePrincipal(name: "staff", id: 20),
                RemotePrincipal(name: "team", id: 300),
                RemotePrincipal(name: "team", id: 301)
            ]
        )
        let (controller, _) = panel(entry(), identity: identity)
        let popup = try #require(controller.groupPopup)
        #expect(popup.itemTitles == ["staff", "team"])
        #expect(popup.titleOfSelectedItem == "staff")
        popup.selectItem(withTitle: "team")
        #expect(controller.editedGroup?.name == "team")
    }

    @Test("root gets a field for each, starting on what the item has")
    func rootTypesNames() throws {
        let (controller, _) = panel(entry(), identity: root)
        #expect(try #require(controller.ownerField).stringValue == "oleg")
        #expect(try #require(controller.groupField).stringValue == "staff")
        #expect(controller.groupPopup == nil)
        #expect(controller.pendingChange.isEmpty)
    }

    @Test("an item the account does not own stays text")
    func strangerItemIsReadOnly() {
        let (controller, _) = panel(entry(owner: "root", group: "wheel"), identity: member)
        #expect(controller.ownerField == nil)
        #expect(controller.groupField == nil)
        #expect(controller.groupPopup == nil)
        let shown = Fixture.texts(in: controller)
        #expect(shown.contains("root"))
        #expect(shown.contains("wheel"))
    }

    // MARK: - What Save sends

    @Test("picking another group sends one chown, and lights Save")
    func pickingAGroupSendsIt() async throws {
        let (controller, backend) = panel(entry(), identity: member)
        backend.landed = entry(group: "admin")
        let popup = try #require(controller.groupPopup)
        popup.selectItem(withTitle: "admin")
        controller.editChanged(nil)
        #expect(controller.saveButton?.isEnabled == true)

        var applied = 0
        controller.onApplied = { applied += 1 }
        controller.save(nil)
        // Held still while the round trip is out, or a second Save could be sent over the first.
        #expect(popup.isEnabled == false)
        try await settle { applied == 1 }

        #expect(backend.sent == [[.setOwnership(owner: nil, group: "admin")]])
        #expect(controller.lastVerdict?.isComplete == true)
    }

    @Test("a set-id item's mode is sent again, after the group")
    func setIDModeFollowsTheGroup() async throws {
        let (controller, backend) = panel(entry(permissions: 0o6755), identity: member)
        backend.landed = entry(permissions: 0o6755, group: "admin")
        try #require(controller.groupPopup).selectItem(withTitle: "admin")
        controller.editChanged(nil)

        var applied = 0
        controller.onApplied = { applied += 1 }
        controller.save(nil)
        try await settle { applied == 1 }

        #expect(backend.sent == [[
            .setOwnership(owner: nil, group: "admin"),
            .setMode(POSIXPermissions(rawValue: 0o6755))
        ]])
    }

    @Test("what root types is what is sent, without the spaces around it")
    func typedNamesAreSent() async throws {
        let (controller, backend) = panel(entry(), identity: root)
        backend.landed = entry(owner: "daemon", group: "wheel")
        try #require(controller.ownerField).stringValue = "  daemon "
        try #require(controller.groupField).stringValue = "wheel"
        controller.editChanged(nil)
        #expect(controller.saveButton?.isEnabled == true)

        var applied = 0
        controller.onApplied = { applied += 1 }
        controller.save(nil)
        try await settle { applied == 1 }

        #expect(backend.sent == [[.setOwnership(owner: "daemon", group: "wheel")]])
    }

    @Test("a cleared field asks for nothing, and Save stays dark")
    func clearedFieldSendsNothing() throws {
        let (controller, _) = panel(entry(), identity: root)
        try #require(controller.ownerField).stringValue = "   "
        controller.editChanged(nil)
        #expect(controller.pendingChange.isEmpty)
        #expect(controller.saveButton?.isEnabled == false)
    }

    @Test("typing the name the item already has is not a change")
    func sameNameIsNoChange() throws {
        let (controller, _) = panel(entry(), identity: root)
        try #require(controller.groupField).stringValue = "staff"
        controller.editChanged(nil)
        #expect(controller.pendingChange.isEmpty)
    }

    @Test("the panel redraws from the server's answer, and the popup starts over from it")
    func redrawsFromTheAnswer() async throws {
        let (controller, backend) = panel(entry(), identity: member)
        backend.landed = entry(group: "admin")
        backend.refusals = [.ownershipRefused("")]
        try #require(controller.groupPopup).selectItem(withTitle: "admin")
        controller.editChanged(nil)

        var applied = 0
        controller.onApplied = { applied += 1 }
        controller.save(nil)
        try await settle { applied == 1 }

        // A new popup, on the group the server says the item has now, with nothing left to send.
        let popup = try #require(controller.groupPopup)
        #expect(popup.titleOfSelectedItem == "admin")
        #expect(popup.isEnabled)
        #expect(controller.pendingChange.isEmpty)
    }
}

/// What the owner and group half of the panel says, and how the pane wires it (PLAN.md §M38 Slice 2).
@Suite("Remote Get Info ▸ owner and group ▸ reporting")
@MainActor
struct RemoteAttributesOwnershipReportingTests {
    private typealias Fixture = RemoteOwnershipPanelFixture
    private let member = Fixture.member
    private let backendID = Fixture.backendID

    private func entry(
        permissions: UInt16 = 0o644,
        owner: String? = "oleg",
        group: String? = "staff",
        on backend: VFSBackendID? = nil
    ) -> FileEntry {
        Fixture.entry(permissions: permissions, owner: owner, group: group, on: backend)
    }

    private func panel(
        _ entry: FileEntry,
        identity: RemoteAccountIdentity?
    ) -> (RemoteAttributesController, WritingBackend) {
        Fixture.panel(entry, identity: identity)
    }

    private func notes(in controller: RemoteAttributesController) -> [String] {
        Fixture.texts(in: controller)
    }

    private func settle(until predicate: () -> Bool) async throws {
        try await Fixture.settle(until: predicate)
    }

    @Test("a refused group is named, in the server's own words, and the mode is left out of it")
    func refusalQuotesTheServer() async throws {
        let words = "chown: you are not a member of group admin"
        let (controller, backend) = panel(entry(permissions: 0o6755), identity: member)
        backend.landed = entry(permissions: 0o6755)
        backend.refusals = [.ownershipRefused(words)]
        try #require(controller.groupPopup).selectItem(withTitle: "admin")
        controller.editChanged(nil)

        var applied = 0
        controller.onApplied = { applied += 1 }
        controller.save(nil)
        try await settle { applied == 1 }

        let verdict = try #require(controller.lastVerdict)
        #expect(verdict.refused == [.group])
        let message = RemoteAttributesController.partialMessage(for: verdict)
        #expect(message.contains(words))
        #expect(message.hasPrefix(try #require(
            RemoteAttributesController.ownershipDetail([.group])
        )))
        #expect(RemoteAttributesController.partialDetail([.group]) != RemoteAttributesController
            .partialDetail([.permissions]))
    }

    @Test("each combination of owner and group says something different")
    func ownershipWording() {
        let owner = RemoteAttributesController.ownershipDetail([.owner])
        let group = RemoteAttributesController.ownershipDetail([.group])
        let both = RemoteAttributesController.ownershipDetail([.owner, .group])
        #expect(owner != nil && group != nil && both != nil)
        #expect(Set([owner, group, both]).count == 3)
        #expect(RemoteAttributesController.ownershipDetail([.permissions]) == nil)
    }

    @Test("a mode and a group refused together are both named")
    func bothDetailsAppear() throws {
        let detail = RemoteAttributesController.partialDetail([.group, .permissions])
        #expect(detail.contains(try #require(RemoteAttributesController.ownershipDetail([.group]))))
        #expect(detail.contains(RemoteAttributesController.partialDetail([.permissions])))
    }

    @Test("an SFTP account with no answer says why its owner and group are text")
    func noCommandSaysWhy() {
        let (controller, _) = panel(entry(), identity: nil)
        #expect(controller.groupPopup == nil)
        #expect(notes(in: controller).contains(RemoteAttributesController.noCommandNote))
    }

    @Test("the note is not there once the account has answered")
    func answeredAccountHasNoNote() {
        let (controller, _) = panel(entry(), identity: member)
        #expect(!notes(in: controller).contains(RemoteAttributesController.noCommandNote))
    }

    @Test("FTP, which has no commands to run, is not told it could not run one")
    func ftpHasNoNote() {
        let ftp = VFSBackendID.ftp(FTPLocation(host: "srv", username: "oleg"))
        let (controller, _) = panel(entry(on: ftp), identity: nil)
        #expect(!notes(in: controller).contains(RemoteAttributesController.noCommandNote))
    }

    @Test("a listing with no owner or group has nothing to explain")
    func noRowsNoNote() {
        let (controller, _) = panel(entry(owner: nil, group: nil), identity: nil)
        #expect(!notes(in: controller).contains(RemoteAttributesController.noCommandNote))
    }

    // MARK: - The pane's half

    private func pane(over composite: CompositeBackend) -> PanelViewController {
        PanelViewController(
            backend: composite,
            restoration: nil,
            defaultPath: .local("/tmp"),
            restorationKey: nil
        )
    }

    @Test("the pane hands the account to the panel it builds")
    func paneWiresTheIdentity() {
        let composite = CompositeBackend(local: LocalBackend())
        composite.connectSFTP(
            location: SFTPLocation(host: "srv", username: "oleg"),
            authentication: .key(identityFile: "/dev/null")
        )
        let pane = pane(over: composite)

        let controller = pane.remoteAttributesController(for: entry(), identity: member)
        #expect(controller.identity == member)
        #expect(controller.editability.allows(.group))
        // The narrowness half, on the same pane.
        #expect(!pane.remoteEditability(for: entry()).allows(.group))
    }

    @Test("a path on no connection has nobody to ask, and no exception to raise")
    func unconnectedPathAnswersNil() throws {
        let composite = CompositeBackend(local: LocalBackend())
        let path = VFSPath(backend: backendID, path: "/home/oleg/report.txt")
        #expect(try composite.accountIdentity(at: path, isCancelled: { false }) == nil)
    }
}
