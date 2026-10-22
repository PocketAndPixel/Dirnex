import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// How Compare By Contents reaches Dirnex's own window (PLAN.md §M31 Slice 4). Which tool is chosen
/// is `CompareTool`'s and tested in the core; these pin what the app does around it: that the
/// window names a file where it lives rather than the copy that was read, that a file it cannot
/// read is named in the alert, that the Synchronize sheet's row action now fetches a server's file
/// first, and where the conflict dialog offers a comparison at all.
///
/// Assertions on alert wording look for the file's *name* rather than a sentence, because the app
/// test target inherits the developer's own `AppleLanguages` pin (docs/NOTES.md ▸ Localization).
@Suite("Compare wiring")
@MainActor
struct CompareWiringTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-compare-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("each side is named and colored after where the file lives, not the copy that was read")
    func sourcesAreNamedByOrigin() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("download-1.tmp")
        try Data("let a = 1\n".utf8).write(to: copy)
        let plain = directory.appendingPathComponent("plain.txt")
        try Data("one\n".utf8).write(to: plain)

        let server = VFSPath(backend: Handoff.remoteID, path: "/srv/app/main.swift")
        let result = CompareOpener.sources(
            CompareFile(path: .local(copy.path), origin: server),
            detail: "host:/srv/app/main.swift",
            CompareFile(path: .local(plain.path), origin: .local(plain.path)),
            detail: plain.path
        )
        let (left, right) = try result.get()
        #expect(left.name == "main.swift")
        #expect(left.detail == "host:/srv/app/main.swift")
        #expect(left.language == .swift, "named by the server's name, so colored as Swift")
        #expect(left.text.text == "let a = 1\n")
        #expect(right.name == "plain.txt")
        #expect(right.language == nil)
    }

    @Test("a binary file is refused by name, and the alert says which one")
    func binaryIsRefusedByName() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = directory.appendingPathComponent("notes.txt")
        try Data("words\n".utf8).write(to: text)
        let binary = directory.appendingPathComponent("image.bin")
        try Data([0x89, 0x50, 0x00, 0x01, 0x02]).write(to: binary)

        let result = CompareOpener.sources(
            CompareFile(path: .local(text.path), origin: .local(text.path)),
            detail: "",
            CompareFile(path: .local(binary.path), origin: .local(binary.path)),
            detail: ""
        )
        guard case let .failure(failure) = result else {
            Issue.record("a NUL byte with no byte-order mark is not text")
            return
        }
        #expect(failure == CompareReadFailure(name: "image.bin", reason: .binary))
        #expect(CompareOpener.failureDetail(failure).contains("image.bin"))
    }

    @Test("a file that cannot be opened is unreadable, and named")
    func missingIsUnreadable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("gone.txt")
        let result = CompareOpener.sources(
            CompareFile(path: .local(missing.path), origin: .local(missing.path)),
            detail: "",
            CompareFile(path: .local(missing.path), origin: .local(missing.path)),
            detail: ""
        )
        guard case let .failure(failure) = result else {
            Issue.record("a file that is not there cannot be read")
            return
        }
        #expect(failure.reason == .unreadable)
        #expect(CompareOpener.failureDetail(failure).contains("gone.txt"))
    }

    @Test("a file over the limit is refused with the limit, in the size format the app uses")
    func tooLargeStatesTheLimit() {
        let limit = ByteComparator.prescanByteLimit
        let failure = CompareReadFailure(
            name: "huge.log",
            reason: .tooLarge(byteSize: limit + 1, limit: limit)
        )
        #expect(CompareOpener.failureDetail(failure).contains(FileFormatting.byteString(limit)))
    }

    /// The Synchronize sheet used to hand a row's own paths to the diff tool, so a server pair
    /// reached FileMerge as two paths on a server. Now it goes through ⌥F3's funnel, and the server
    /// row is fetched before anything opens. The answer is withheld, so nothing opens here.
    @Test("the Synchronize sheet's Compare fetches a server's file before comparing")
    func syncCompareFetchesFirst() async throws {
        let (pane, host) = hostedPane()
        host.materializeReport = nil
        let sheet = pane.makeSyncController(
            leftDir: .local("/tmp/left"),
            rightDir: VFSPath(backend: Handoff.remoteID, path: "/srv"),
            directions: [.leftToRight]
        )
        let local = Handoff.local("/tmp/left/a.txt")
        let remote = Handoff.remote("/srv/a.txt")
        sheet.onCompare?(local, remote)
        try await settleUntil { !host.materializedEntries.isEmpty }
        #expect(host.materializedEntries.flatMap(\.self).map(\.path) == [remote.path])
    }

    /// Seen live in Slice 5: Copy Path's bare server path put a server file and a local one side by
    /// side as if both were local.
    @Test("a server file's header names the server, a local or archive file's is Copy Path's text")
    func headerNamesTheServer() {
        let (pane, host) = hostedPane()
        let server = VFSBackendID.sftp(SFTPLocation(host: "nas", port: 2222, username: "oleg"))
        let member = VFSPath(backend: .archive(forArchiveAt: "/tmp/pair.zip"), path: "/docs/a.md")
        withExtendedLifetime(host) {
            #expect(
                pane.compareDetail(for: VFSPath(backend: server, path: "/srv/a.txt")) == "oleg@nas:/srv/a.txt"
            )
            #expect(pane.compareDetail(for: .local("/tmp/a.txt")) == "/tmp/a.txt")
            #expect(pane.compareDetail(for: member) == "/tmp/pair.zip/docs/a.md")
        }
    }

    @Test("the conflict dialog compares two local files with their bytes here, and nothing else")
    func conflictComparesOnlyLocalFiles() {
        func context(_ source: FileEntry, _ existing: FileEntry) -> ConflictContext {
            ConflictContext(kind: .copy, source: source, existing: existing)
        }
        let local = Handoff.local("/tmp/in/a.txt")
        let there = Handoff.local("/tmp/out/a.txt")
        #expect(ConflictComparisonView.canCompare(context(local, there)))
        #expect(!ConflictComparisonView.canCompare(context(Handoff.remote("/srv/a.txt"), there)))
        #expect(
            !ConflictComparisonView.canCompare(
                context(local, Handoff.local("/tmp/out/a", kind: .directory))
            )
        )
        let evicted = Handoff.entry(.local("/tmp/in/b.txt"), isDataless: true)
        #expect(!ConflictComparisonView.canCompare(context(evicted, there)))
    }

    @Test(
        "the conflict dialog's Compare button is there only when it can compare, and runs its action"
    )
    func conflictButton() throws {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        let files = ConflictContext(
            kind: .copy,
            source: Handoff.local("/tmp/in/a.txt"),
            existing: Handoff.local("/tmp/out/a.txt")
        )
        let view = ConflictComparisonView(
            context: files,
            sourceThumbnail: image,
            existingThumbnail: image,
            compareTitle: "Compare"
        )
        var compared = 0
        view.onCompare = { compared += 1 }
        let button = try #require(view.compareButton)
        button.performClick(nil)
        #expect(compared == 1)

        let folders = ConflictContext(
            kind: .copy,
            source: Handoff.local("/tmp/in/a", kind: .directory),
            existing: Handoff.local("/tmp/out/a", kind: .directory)
        )
        let withoutButton = ConflictComparisonView(
            context: folders,
            sourceThumbnail: image,
            existingThumbnail: image,
            compareTitle: "Compare"
        )
        #expect(withoutButton.compareButton == nil)
        #expect(
            withoutButton.frame.height < view.frame.height,
            "no room is kept for a missing button"
        )
    }

    /// The Synchronize window is app-modal and opens comparisons; a plain window opened from it
    /// takes no click until it closes (probed for Slice 4).
    @Test("the compare window takes events while another window is modal")
    func windowWorksWhenModal() {
        let side = CompareSource(name: "a", detail: "", text: ComparedText(text: ""), language: nil)
        let controller = CompareWindowController(left: side, right: side)
        #expect(controller.window?.worksWhenModal == true)
    }

    /// The key-window delegate methods live in `+Keys`, a file away from the conformance, and AppKit
    /// only calls them if they are visible to the Objective-C runtime.
    @Test("the window's delegate answers the key-window callbacks that install the key monitor")
    func keyCallbacksReachTheRuntime() {
        let side = CompareSource(name: "a", detail: "", text: ComparedText(text: ""), language: nil)
        let controller = CompareWindowController(left: side, right: side)
        #expect(controller.window?.delegate === controller)
        #expect(controller.responds(to: #selector(NSWindowDelegate.windowDidBecomeKey(_:))))
        #expect(controller.responds(to: #selector(NSWindowDelegate.windowDidResignKey(_:))))
    }
}
