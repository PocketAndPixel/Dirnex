import Foundation
import Testing

@testable import DirnexCore

/// Download Now and Remove Download (``CloudLocalCopyAction``).
///
/// No provider can be a test dependency, so what is pinned here is every decision around the two
/// system calls: which rows qualify, what each action does with a folder, and what a refusal means.
/// The error shapes are the ones measured live against iCloud, Dropbox, Box and OneDrive on
/// 2026-09-12 (docs/NOTES.md), rebuilt by hand rather than produced by the code under test.
@Suite("Cloud local copy")
struct CloudLocalCopyTests {
    private static let home = "/Users/probe"

    private static func entry(
        _ path: String,
        kind: FileEntry.Kind = .file,
        dataless: Bool = false,
        backend: VFSBackendID = .local
    ) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: backend, path: path),
            name: (path as NSString).lastPathComponent,
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

    private static func target(_ entry: FileEntry, known: Bool = false) -> CloudLocalCopyTarget? {
        CloudLocalCopyTarget(entry: entry, isKnownCloudItem: known, home: home)
    }

    // MARK: - Which rows qualify

    @Test("items under either provider root qualify, with no I/O and no badge")
    func providerRootsQualify() {
        #expect(
            Self.target(Self.entry("/Users/probe/Library/CloudStorage/Dropbox-Home/a.txt")) != nil
        )
        #expect(
            Self.target(
                Self.entry("/Users/probe/Library/CloudStorage/Box-Box/sub", kind: .directory)
            ) != nil
        )
        #expect(
            Self.target(
                Self.entry("/Users/probe/Library/Mobile Documents/com~apple~CloudDocs/a.pdf")
            ) != nil
        )
    }

    @Test("an ordinary file qualifies only when the caller knows it is a cloud item")
    func ordinaryFileNeedsKnowledge() {
        let desktop = Self.entry("/Users/probe/Desktop/a.txt")
        #expect(Self.target(desktop) == nil)
        // iCloud's Desktop and Documents: outside both roots, so only a badge or a directory read
        // can say so.
        #expect(Self.target(desktop, known: true) != nil)
    }

    @Test("a placeholder qualifies wherever it is")
    func placeholderQualifies() {
        let target = Self.target(Self.entry("/Volumes/Elsewhere/a.raw", dataless: true))
        #expect(target?.isDataless == true)
    }

    @Test("the root match is a whole component and this account's")
    func rootMatchIsExact() {
        #expect(Self.target(Self.entry("/Users/probe/Library/CloudStorageBackup/a.txt")) == nil)
        #expect(
            Self.target(Self.entry("/Users/probe2/Library/CloudStorage/Dropbox-Home/a.txt")) == nil
        )
        #expect(Self.target(Self.entry("/Users/other/Library/Mobile Documents/x/a.txt")) == nil)
    }

    @Test("symlinks, special files and rows not on this disk never qualify")
    func nonTargets() {
        let root = "/Users/probe/Library/CloudStorage/GoogleDrive-a@b.c"
        #expect(Self.target(Self.entry("\(root)/My Drive", kind: .symlink), known: true) == nil)
        #expect(Self.target(Self.entry("\(root)/fifo", kind: .other), known: true) == nil)
        let remote = Self.entry(
            "/Users/probe/Library/CloudStorage/x/a.txt",
            dataless: true,
            backend: .archive(forArchiveAt: "/tmp/a.zip")
        )
        #expect(Self.target(remote, known: true) == nil)
    }

    // MARK: - Which action applies

    @Test("a file takes exactly one action and a folder takes both")
    func applicability() {
        let local = CloudLocalCopyTarget(path: .local("/a"), isDirectory: false, isDataless: false)
        let placeholder = CloudLocalCopyTarget(
            path: .local("/b"),
            isDirectory: false,
            isDataless: true
        )
        let folder = CloudLocalCopyTarget(path: .local("/c"), isDirectory: true, isDataless: false)

        #expect(!CloudLocalCopyAction.download.applies(to: local))
        #expect(CloudLocalCopyAction.removeDownload.applies(to: local))
        #expect(CloudLocalCopyAction.download.applies(to: placeholder))
        #expect(!CloudLocalCopyAction.removeDownload.applies(to: placeholder))
        #expect(CloudLocalCopyAction.download.applies(to: folder))
        #expect(CloudLocalCopyAction.removeDownload.applies(to: folder))

        #expect(CloudLocalCopyAction.download.applies(toAnyOf: [local, placeholder]))
        #expect(!CloudLocalCopyAction.download.applies(toAnyOf: [local]))
        #expect(!CloudLocalCopyAction.removeDownload.applies(toAnyOf: []))
    }

    // MARK: - Refusals, as measured

    private static func error(_ domain: String, _ code: Int, over underlying: NSError? = nil) -> NSError {
        NSError(
            domain: domain,
            code: code,
            userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:]
        )
    }

    @Test("the measured error chains classify as the refusals they are")
    func measuredRefusals() {
        // Evicting an ordinary file, and downloading one.
        #expect(
            CloudLocalCopyRefusal(
                error: Self.error(NSCocoaErrorDomain, 3328, over: Self.error(NSPOSIXErrorDomain, 45))
            )
                == .notACloudItem
        )
        #expect(
            CloudLocalCopyRefusal(
                error: Self.error(
                    NSCocoaErrorDomain,
                    512,
                    over: Self.error("NSFileProviderInternalErrorDomain", 0)
                )
            ) == .notACloudItem
        )
        // Evicting a OneDrive `.DS_Store`, which never uploads.
        #expect(
            CloudLocalCopyRefusal(
                error: Self.error(
                    NSCocoaErrorDomain,
                    512,
                    over: Self.error("NSFileProviderErrorDomain", -2008)
                )
            ) == .notYetUploaded
        )
        // Evicting a Dropbox file this process held open, by descriptor and by mapping alike.
        #expect(
            CloudLocalCopyRefusal(
                error: Self.error(NSCocoaErrorDomain, 255, over: Self.error(NSPOSIXErrorDomain, 16))
            )
                == .inUse
        )
        #expect(
            CloudLocalCopyRefusal(error: Self.error("NSFileProviderErrorDomain", -2010)) == .excludedFromSync
        )
        #expect(
            CloudLocalCopyRefusal(error: Self.error("NSFileProviderErrorDomain", -2007)) == .notYetUploaded
        )
    }

    @Test("a bare wrapper is not read as a verdict, and an unknown refusal keeps its own words")
    func unknownRefusals() {
        // 512 wraps three different refusals; with nothing underneath it says none of them.
        let bare = CloudLocalCopyRefusal(error: Self.error(NSCocoaErrorDomain, 512))
        #expect(bare != .notACloudItem)
        let denied = NSError(
            domain: NSCocoaErrorDomain,
            code: 257,
            userInfo: [NSLocalizedDescriptionKey: "You don’t have permission."]
        )
        #expect(CloudLocalCopyRefusal(error: denied) == .other("You don’t have permission."))
    }
}
