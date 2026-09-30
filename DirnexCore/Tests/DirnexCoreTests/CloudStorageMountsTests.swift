import Foundation
import Testing

@testable import DirnexCore

/// Discovering the provider mounts under `~/Library/CloudStorage` (PLAN.md §M10 Phase 1).
@Suite("CloudStorageMounts")
struct CloudStorageMountsTests {
    // MARK: - Layout

    @Test("the mounts live directly under ~/Library/CloudStorage")
    func cloudStorageIsTheParent() {
        let parent = CloudStorageMounts.cloudStorage(home: "/Users/test")
        #expect(parent.path == "/Users/test/Library/CloudStorage")
    }

    // MARK: - Parsing the directory name

    @Test("a mount splits into its provider and its account at the first hyphen")
    func splitsProviderFromAccount() {
        // The real name probed on this Mac 2026-07-21.
        let (provider, account) = CloudStorageMounts.split(
            directoryName: "GoogleDrive-oleg.verhoglyad@gmail.com"
        )
        #expect(provider == "GoogleDrive")
        #expect(account == "oleg.verhoglyad@gmail.com")
    }

    @Test("an account whose email contains a hyphen keeps all of it")
    func splitsAtTheFirstHyphenNotTheLast() {
        // Splitting at the last hyphen would answer ("GoogleDrive-some", "one@gmail.com") —
        // a provider that does not exist and a truncated address.
        let (provider, account) = CloudStorageMounts.split(
            directoryName: "GoogleDrive-some-one@gmail.com"
        )
        #expect(provider == "GoogleDrive")
        #expect(account == "some-one@gmail.com")
    }

    @Test("a provider that mounts one unlabeled folder has no account")
    func unlabeledMountHasNoAccount() {
        let (provider, account) = CloudStorageMounts.split(directoryName: "Dropbox")
        #expect(provider == "Dropbox")
        #expect(account == nil)
    }

    @Test("a trailing hyphen with nothing after it is not an empty account")
    func trailingHyphenIsNotAnAccount() {
        let (provider, account) = CloudStorageMounts.split(directoryName: "Box-")
        #expect(provider == "Box")
        #expect(account == nil)
    }

    @Test("a provider whose own name contains a hyphen is matched whole, not cut at it")
    func sharedLibrariesIsNotCutInsideItsProviderName() {
        // OneDrive mounts a SharePoint document library as `OneDrive-SharedLibraries-<tenant>`,
        // so the first hyphen falls inside the provider's name. Cutting there would answer the
        // account `SharedLibraries-Contoso` — an internal English token bound for the sidebar.
        let (provider, account) = CloudStorageMounts.split(
            directoryName: "OneDrive-SharedLibraries-Contoso"
        )
        #expect(provider == "OneDrive-SharedLibraries")
        #expect(account == "Contoso")
    }

    @Test("the shorter OneDrive id does not shadow the longer one it prefixes")
    func plainOneDriveStillSplitsAtTheHyphen() {
        // The negative control for the rule above: ordering the table wrongly (or adding a bare
        // `OneDrive` entry to it) would take this branch and answer an empty account.
        let (provider, account) = CloudStorageMounts.split(directoryName: "OneDrive-Personal")
        #expect(provider == "OneDrive")
        #expect(account == "Personal")
    }

    @Test("a SharePoint library is named for the product, not for its folder")
    func sharedLibrariesIsRenamed() {
        let name = CloudStorageMounts.displayName(
            providerID: "OneDrive-SharedLibraries",
            accountLabel: "Contoso",
            isAmbiguous: false
        )
        #expect(name == "SharePoint")
    }

    @Test("a SharePoint library and the user's own OneDrive are two different rows")
    func sharePointDoesNotCollideWithOneDrive() {
        // The pair that shipped identical: both mounts split to `OneDrive`, so neither was
        // ambiguous by the count and both drew the bare provider name.
        let personal = CloudStorageMounts.split(directoryName: "OneDrive-Personal")
        let library = CloudStorageMounts.split(directoryName: "OneDrive-SharedLibraries-Contoso")
        #expect(personal.providerID != library.providerID)

        let personalName = CloudStorageMounts.displayName(
            providerID: personal.providerID,
            accountLabel: personal.accountLabel,
            isAmbiguous: false
        )
        let libraryName = CloudStorageMounts.displayName(
            providerID: library.providerID,
            accountLabel: library.accountLabel,
            isAmbiguous: false
        )
        #expect(personalName == "OneDrive")
        #expect(libraryName == "SharePoint")
    }

    // MARK: - Display names

    @Test("Google Drive is renamed from its directory spelling")
    func googleDriveIsRenamed() {
        let name = CloudStorageMounts.displayName(
            providerID: "GoogleDrive",
            accountLabel: "someone@gmail.com",
            isAmbiguous: false
        )
        #expect(name == "Google Drive")
    }

    @Test("a provider that spells its folder the way it spells itself is passed through")
    func unknownProviderKeepsItsOwnName() {
        // Not a fallback that degrades: OneDrive's folder *is* how OneDrive is written.
        let name = CloudStorageMounts.displayName(
            providerID: "OneDrive",
            accountLabel: "Personal",
            isAmbiguous: false
        )
        #expect(name == "OneDrive")
    }

    @Test(
        "a second account for the same provider puts the account first, where it survives truncation"
    )
    func ambiguousProviderLeadsWithTheAccount() {
        // Caught live: `Google Drive (someone@gmail.com)` tail-truncates in the real sidebar, so
        // two accounts rendered as the identical string "Google Drive (ol…". The account has to
        // lead or it is not a disambiguator at all.
        let name = CloudStorageMounts.displayName(
            providerID: "GoogleDrive",
            accountLabel: "someone@gmail.com",
            isAmbiguous: true
        )
        #expect(name == "someone@gmail.com — Google Drive")
    }

    @Test("two accounts of one provider differ within the first few characters of their labels")
    func ambiguousLabelsDifferEarly() {
        // The real pair on this Mac. A label whose first divergence sits past the point a narrow
        // sidebar truncates is not a label that distinguishes anything, so assert on the prefix
        // rather than just on inequality.
        let first = CloudStorageMounts.displayName(
            providerID: "GoogleDrive",
            accountLabel: "oleg.email.address@gmail.com",
            isAmbiguous: true
        )
        let second = CloudStorageMounts.displayName(
            providerID: "GoogleDrive",
            accountLabel: "oleg.verhoglyad@gmail.com",
            isAmbiguous: true
        )
        #expect(first.prefix(12) != second.prefix(12))
    }

    @Test("an ambiguous provider with no account to show falls back to the bare name")
    func ambiguousWithoutAccountStaysBare() {
        let name = CloudStorageMounts.displayName(
            providerID: "Dropbox",
            accountLabel: nil,
            isAmbiguous: true
        )
        #expect(name == "Dropbox")
    }

    // MARK: - Scanning

    @Test("each provider directory becomes one mount")
    func scanFindsEachProvider() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir("Library/CloudStorage/GoogleDrive-someone@gmail.com")
        try temp.makeDir("Library/CloudStorage/Dropbox")

        let mounts = CloudStorageMounts.mounts(home: temp.root.path)
        #expect(mounts.map(\.name) == ["Dropbox", "Google Drive"])
        let drive = try #require(mounts.first { $0.providerID == "GoogleDrive" })
        #expect(drive.accountLabel == "someone@gmail.com")
        #expect(drive.directoryName == "GoogleDrive-someone@gmail.com")
        #expect(drive.path == temp.vfsPath("Library/CloudStorage/GoogleDrive-someone@gmail.com"))
        #expect(drive.symbolName == "cloud")
    }

    @Test("two accounts of one provider are told apart by their labels")
    func twoAccountsOfOneProviderAreDisambiguated() throws {
        // The real shape on this Mac: two signed-in Google accounts, two mounts.
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir("Library/CloudStorage/GoogleDrive-a@gmail.com")
        try temp.makeDir("Library/CloudStorage/GoogleDrive-b@gmail.com")

        let mounts = CloudStorageMounts.mounts(home: temp.root.path)
        #expect(mounts.map(\.name) == ["a@gmail.com — Google Drive", "b@gmail.com — Google Drive"])
    }

    @Test("a provider's accounts stay together even when their labels sort elsewhere")
    func mountsGroupByProvider() throws {
        // Sorting on the label alone would file both Google rows under "a"/"b" and put Dropbox
        // between them.
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir("Library/CloudStorage/GoogleDrive-a@gmail.com")
        try temp.makeDir("Library/CloudStorage/GoogleDrive-z@gmail.com")
        try temp.makeDir("Library/CloudStorage/Dropbox")

        #expect(CloudStorageMounts.mounts(home: temp.root.path).map(\.providerID) == [
            "Dropbox", "GoogleDrive", "GoogleDrive"
        ])
    }

    @Test("a provider is named plainly again once its second account goes away")
    func singleAccountDropsTheLabel() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir("Library/CloudStorage/GoogleDrive-a@gmail.com")

        #expect(CloudStorageMounts.mounts(home: temp.root.path).map(\.name) == ["Google Drive"])
    }

    @Test("a mount whose roots are not provisioned yet is still a mount")
    func anEmptyMountIsStillListed() throws {
        // Probed 2026-07-21: a freshly signed-in Drive account mounts and lists empty. Filtering
        // on content would hide a working mount that is simply still being set up — and the
        // sidebar row is how the user gets to it to notice.
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir("Library/CloudStorage/GoogleDrive-someone@gmail.com")

        #expect(CloudStorageMounts.mounts(home: temp.root.path).count == 1)
    }

    @Test("Finder's own bookkeeping is not a provider")
    func dotFilesAreSkipped() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir("Library/CloudStorage/GoogleDrive-someone@gmail.com")
        try temp.writeFile("Library/CloudStorage/.DS_Store", bytes: 8)
        try temp.makeDir("Library/CloudStorage/.hidden")

        #expect(CloudStorageMounts.mounts(home: temp.root.path).map(\.providerID) == ["GoogleDrive"])
    }

    @Test("a loose file beside the mounts is not one")
    func filesAreSkipped() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir("Library/CloudStorage")
        try temp.writeFile("Library/CloudStorage/notes.txt", bytes: 4)

        #expect(CloudStorageMounts.mounts(home: temp.root.path).isEmpty)
    }

    @Test("a Mac with no sync client installed has no CloudStorage directory and no rows")
    func missingDirectoryYieldsNothing() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }

        #expect(CloudStorageMounts.mounts(home: temp.root.path).isEmpty)
    }

    // MARK: - Is a macOS grant relevant here (PLAN.md §M26 Slice 3)

    /// The three answers that decide which remedy a permission failure names. Pure string tests —
    /// nothing here touches the disk, which is what makes it free to ask on an error path.
    @Test("a path inside a provider mount is inside CloudStorage, at every depth")
    func mountPathsAreInsideCloudStorage() {
        let home = "/Users/test"
        let inside = [
            "/Users/test/Library/CloudStorage",
            "/Users/test/Library/CloudStorage/GoogleDrive-someone@gmail.com",
            "/Users/test/Library/CloudStorage/GoogleDrive-someone@gmail.com/My Drive/a/b.txt",
            "/Users/test/Library/CloudStorage/Dropbox-Home/team/report.pdf"
        ]
        for path in inside {
            #expect(CloudStorageMounts.isInsideCloudStorage(.local(path), home: home), "\(path)")
        }
    }

    /// The narrowness control, and the half the fix would be wrong without: `Mobile Documents`
    /// **is** TCC-gated, so Full Disk Access is the correct advice for an iCloud path. The two
    /// roots are twins for the trash route (``TrashLanding/providerRoots``) and opposites here.
    @Test("iCloud, ordinary local paths and a lookalike prefix are not")
    func everywhereElseIsNot() {
        let home = "/Users/test"
        let outside = [
            "/Users/test/Library/Mobile Documents/com~apple~CloudDocs/notes.txt",
            "/Users/test/Documents/report.pdf",
            "/Users/test/Library",
            // A sibling whose name merely starts the same way — `isSelfOrDescendant` compares
            // components, so this must not be swept in by a prefix match.
            "/Users/test/Library/CloudStorageBackup/old.txt",
            // Another user's mounts are not this home's.
            "/Users/other/Library/CloudStorage/Box-Box/a.txt"
        ]
        for path in outside {
            #expect(!CloudStorageMounts.isInsideCloudStorage(.local(path), home: home), "\(path)")
        }
    }

    /// A remote path that happens to *spell* the same thing is not on this Mac at all, so it can
    /// never be inside this home's CloudStorage — the backend is checked before the components.
    @Test("a remote path spelling the same components is not inside CloudStorage")
    func remoteLookalikeIsNot() {
        // Built through the type's own constructor rather than hand-spelled, so it is an id the
        // app really produces (docs/NOTES.md ▸ a fixture identifier that merely looks real).
        let path = VFSPath(
            backend: VFSBackendID.sftp(SFTPLocation(host: "srv", username: "oleg")),
            path: "/Users/test/Library/CloudStorage/Box-Box/a.txt"
        )
        #expect(!CloudStorageMounts.isInsideCloudStorage(path, home: "/Users/test"))
    }
}
