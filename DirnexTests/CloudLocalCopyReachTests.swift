import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Where Download Now, Remove Download and Show in Finder are offered, and what they say afterwards.
///
/// The answers come from the real `validateMenuItem` and the real right-click decision rather than
/// from a restatement of the rule — a validator carrying its own copy of a rule is how a working
/// command ends up grayed out (docs/NOTES.md ▸ AppKit). The panes are headless and the actions are
/// never driven: both reach `fileproviderd`, and no provider can be a test dependency. The system
/// calls themselves were verified live (docs/NOTES.md).
///
/// Every row here is **synthetic** — a path under `~/Library/CloudStorage` that does not exist —
/// which is the claim being made: whether a row qualifies is decided without touching the disk.
@Suite("Cloud local copy: reach")
@MainActor
struct CloudLocalCopyReachTests {
    // MARK: - Fixtures

    private static let cloudFolder = VFSPath.local(
        NSHomeDirectory() + "/Library/CloudStorage/DirnexProbe-\(UUID().uuidString)"
    )

    private static func entry(
        _ name: String,
        in directory: VFSPath = cloudFolder,
        kind: FileEntry.Kind = .file,
        dataless: Bool = false
    ) -> FileEntry {
        FileEntry(
            path: directory.appending(name),
            name: name,
            kind: kind,
            byteSize: 1,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o644,
            inode: 0,
            isDataless: dataless
        )
    }

    /// A pane at `directory` listing exactly `entry`, so the cursor stands on it.
    private static func pane(at directory: VFSPath = cloudFolder, listing entry: FileEntry) -> PanelViewController {
        let pane = PanelViewController(
            backend: LocalBackend(),
            restoration: nil,
            defaultPath: directory,
            restorationKey: nil
        )
        pane.panel = Panel(
            model: DirectoryModel(listing: DirectoryListing(path: directory, entries: [entry]))
        )
        return pane
    }

    private static func enabled(_ action: Selector, in pane: PanelViewController) -> Bool {
        pane.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }

    private static let download = #selector(PanelViewController.downloadNow(_:))
    private static let remove = #selector(PanelViewController.removeDownload(_:))
    private static let reveal = #selector(PanelViewController.showInFinder(_:))

    // MARK: - Which command a row offers

    @Test("a downloaded cloud file offers Remove Download, not Download Now")
    func downloadedFile() {
        let pane = Self.pane(listing: Self.entry("here.txt"))
        #expect(!Self.enabled(Self.download, in: pane))
        #expect(Self.enabled(Self.remove, in: pane))
        #expect(Self.enabled(Self.reveal, in: pane))
        #expect(
            pane.whereItLivesCommandIDs() == [
                "file.showInFinder",
                "file.downloadNow",
                "file.removeDownload"
            ]
        )
    }

    @Test("a placeholder offers Download Now, not Remove Download")
    func placeholder() {
        let pane = Self.pane(listing: Self.entry("away.raw", dataless: true))
        #expect(Self.enabled(Self.download, in: pane))
        #expect(!Self.enabled(Self.remove, in: pane))
    }

    @Test("a cloud folder offers both, since what is inside it is a walk away")
    func folder() {
        let pane = Self.pane(listing: Self.entry("Photos", kind: .directory))
        #expect(Self.enabled(Self.download, in: pane))
        #expect(Self.enabled(Self.remove, in: pane))
    }

    /// The narrowness control: without it, "offer the cloud pair" passes this suite by offering it
    /// on every file there is.
    @Test("an ordinary file offers neither, and the right-click leaves the pair out")
    func ordinaryFile() {
        let plain = VFSPath.local(NSTemporaryDirectory() + "dirnex-probe-\(UUID().uuidString)")
        let pane = Self.pane(at: plain, listing: Self.entry("notes.txt", in: plain))
        #expect(!Self.enabled(Self.download, in: pane))
        #expect(!Self.enabled(Self.remove, in: pane))
        #expect(Self.enabled(Self.reveal, in: pane))
        #expect(pane.whereItLivesCommandIDs() == ["file.showInFinder"])
    }

    @Test(
        "a directory read as a cloud directory makes its rows cloud items — for that directory only"
    )
    func cloudDirectoryReading() {
        // iCloud's Desktop and Documents: outside both provider roots, so only the read says so.
        let desktop = VFSPath.local(NSHomeDirectory() + "/Desktop-probe-\(UUID().uuidString)")
        let pane = Self.pane(at: desktop, listing: Self.entry("draft.pages", in: desktop))
        let tab = pane.tabs[pane.activeTabIndex]

        tab.cloudDirectoryReading = (path: desktop, isCloud: true)
        #expect(Self.enabled(Self.remove, in: pane))

        // A read still in flight, and one left behind by another directory, both say nothing.
        tab.cloudDirectoryReading = (path: desktop, isCloud: nil)
        #expect(!Self.enabled(Self.remove, in: pane))
        tab.cloudDirectoryReading = (path: Self.cloudFolder, isCloud: true)
        #expect(!Self.enabled(Self.remove, in: pane))
    }

    @Test("a row that is not on this disk offers none of the three")
    func notOnThisDisk() {
        let archive = VFSPath(backend: .archive(forArchiveAt: "/tmp/probe.zip"), path: "/")
        let pane = Self.pane(
            at: archive,
            listing: Self.entry("inner.txt", in: archive, dataless: true)
        )
        #expect(!Self.enabled(Self.download, in: pane))
        #expect(!Self.enabled(Self.remove, in: pane))
        #expect(!Self.enabled(Self.reveal, in: pane))
        #expect(pane.whereItLivesCommandIDs().isEmpty)
    }

    @Test("an ordinary directory is read as not a cloud directory, off the main thread")
    func noteCloudDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-cloud-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = VFSPath.local(directory.path)
        let pane = Self.pane(at: path, listing: Self.entry("a.txt", in: path))

        pane.noteCloudDirectory()
        let tab = pane.tabs[pane.activeTabIndex]
        #expect(tab.cloudDirectoryReading?.path == path)
        let deadline = Date().addingTimeInterval(30)
        while tab.cloudDirectoryReading?.isCloud == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tab.cloudDirectoryReading?.isCloud == false)
    }

    @Test("the registry commands send the pane's selectors")
    func binding() {
        #expect(CommandBinding.selector(for: "file.downloadNow") == Self.download)
        #expect(CommandBinding.selector(for: "file.removeDownload") == Self.remove)
        #expect(CommandBinding.selector(for: "file.showInFinder") == Self.reveal)
    }

    // MARK: - What it says afterwards

    /// Asserted on counts and names rather than wording: the test host inherits the developer's
    /// `AppleLanguages` pin (docs/NOTES.md ▸ Localization).
    @Test("the status line counts what was asked for, and each idle case says something different")
    func statusLine() throws {
        let downloading = try #require(
            PanelViewController.cloudLocalCopyStatus(
                for: CloudLocalCopyReport(action: .download, accepted: 17)
            )
        )
        #expect(downloading.contains("17"))
        let removed = try #require(
            PanelViewController.cloudLocalCopyStatus(
                for: CloudLocalCopyReport(action: .removeDownload, accepted: 17)
            )
        )
        #expect(removed.contains("17"))
        #expect(removed != downloading)

        let notCloud = PanelViewController.cloudLocalCopyStatus(
            for: CloudLocalCopyReport(action: .removeDownload, notCloudItems: 2)
        )
        let alreadyHere = PanelViewController.cloudLocalCopyStatus(
            for: CloudLocalCopyReport(action: .download)
        )
        let nothingHere = PanelViewController.idleCloudLocalCopyStatus(
            for: .removeDownload,
            hasCloudItems: true
        )
        #expect(notCloud != nil && alreadyHere != nil)
        #expect(Set([notCloud, alreadyHere, nothingHere]).count == 3)

        // A run that only met refusals leaves the saying to the alert.
        let refused = CloudLocalCopyReport(
            action: .removeDownload,
            failures: [.init(path: .local("/a"), refusal: .inUse)]
        )
        #expect(PanelViewController.cloudLocalCopyStatus(for: refused) == nil)
    }

    @Test("one refusal is named with its reason; many are listed, then counted")
    func refusalAlert() {
        let one = CloudLocalCopyReport(
            action: .removeDownload,
            failures: [.init(path: .local("/x/Report.pdf"), refusal: .inUse)]
        )
        #expect(PanelViewController.cloudLocalCopyFailureTitle(for: one).contains("Report.pdf"))
        #expect(
            PanelViewController.cloudLocalCopyFailureDetail(for: one) == PanelViewController.sentence(
                for: .inUse
            )
        )

        let failures = (1...8).map {
            CloudLocalCopyReport.Failure(path: .local("/x/f\($0).raw"), refusal: .notYetUploaded)
        }
        let many = CloudLocalCopyReport(action: .removeDownload, failures: failures)
        #expect(PanelViewController.cloudLocalCopyFailureTitle(for: many).contains("8"))
        let lines = PanelViewController.cloudLocalCopyFailureDetail(for: many).split(separator: "\n")
        #expect(lines.count == 7)
        #expect(lines.first?.contains("f1.raw") == true)
        #expect(lines.last?.contains("2") == true)
        #expect(!lines.contains { $0.contains("f7.raw") })

        let other = PanelViewController.sentence(for: .other("The provider’s own words."))
        #expect(other == "The provider’s own words.")
    }
}
