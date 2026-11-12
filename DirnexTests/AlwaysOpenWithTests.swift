import AppKit
import DirnexCore
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import Dirnex

/// Open With ▸ Always Open … With (2026-11-12) against this Mac's LaunchServices: which files a row
/// stands for, and the submenu built from it. Nothing here changes a default, since every change
/// raises macOS's own dialog (`OpenWithLauncher.makeDefault`); the rule for the scope is the core's
/// (`DefaultApplicationScopeTests`).
@Suite("Always Open With")
@MainActor
struct AlwaysOpenWithTests {
    private func row(at url: URL, kind: FileEntry.Kind = .file) -> FileEntry {
        FileEntry(
            path: .local(url.path),
            name: url.lastPathComponent,
            kind: kind,
            byteSize: 5,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 3
        )
    }

    /// A file in a folder of its own, removed by the caller's `defer`.
    private func file(named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-always-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func pane() -> PanelViewController {
        PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: .local(NSTemporaryDirectory()),
            restorationKey: nil
        )
    }

    @Test("a real .m4v file reaches every file of its type, named by its extension")
    func scopeOfAMovie() throws {
        let url = try file(named: "clip.m4v")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(OpenWithLauncher.defaultApplicationScope(for: [row(at: url)]) == DefaultApplicationScope(
            typeIdentifier: "com.apple.m4v-video",
            name: .fileExtension("m4v")
        ))
    }

    @Test("a real folder has no scope, so nothing offers to change what opens folders")
    func scopeOfAFolder() throws {
        let url = try file(named: "marker.txt").deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(
            OpenWithLauncher.defaultApplicationScope(for: [row(at: url, kind: .directory)]) == nil
        )
    }

    @Test("Open With ends in the submenu, which lists the same applications with today's ticked")
    func submenuForAMovie() throws {
        let url = try file(named: "clip.m4v")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rows = [row(at: url)]
        let candidates = OpenWithLauncher.candidates(for: rows)

        let items = pane().openWithMenuItems(for: rows)
        let always = try #require(items.last?.submenu)
        let scope = try #require(OpenWithLauncher.defaultApplicationScope(for: rows))
        #expect(items.last?.title == PanelViewController.alwaysOpenWithTitle(for: scope))
        #expect(items.last?.title.contains(".m4v") == true)

        let applications = always.items.filter { !$0.isSeparatorItem }.dropLast()
        let expected = [candidates.defaultApplication].compactMap(\.self) + candidates.others
        #expect(applications.map(\.title) == expected.map(\.displayName))
        let ticked = applications.filter { $0.state == .on }.map(\.title)
        #expect(ticked == [candidates.defaultApplication?.displayName].compactMap(\.self))
        // Every application carries the rows, so a change can open them in it.
        for item in applications {
            let request = try #require(item.representedObject as? DefaultApplicationRequest)
            #expect(request.rows.map(\.path) == rows.map(\.path))
            #expect(request.scope == scope)
            #expect(request.application?.displayName == item.title)
        }
        // Other… last, as in Open With itself, with the rows and no application yet.
        #expect(always.items.last?.action != nil)
        let other = try #require(always.items.last?.representedObject as? DefaultApplicationRequest)
        #expect(other.rows.map(\.path) == rows.map(\.path))
        #expect(other.scope == scope)
        #expect(other.application == nil)
    }

    @Test("a file nothing opens still offers Other…, so its first application can be chosen")
    func submenuForAnUnclaimedFile() throws {
        let url = try file(named: "x.zzzqqq")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let always = try #require(pane().openWithMenuItems(for: [row(at: url)]).last?.submenu)
        #expect(always.items.count == 1)
        #expect(always.items.first?.representedObject is DefaultApplicationRequest)
    }

    @Test("rows of two types end Open With at Other…, with no submenu")
    func noSubmenuForTwoTypes() throws {
        let movie = try file(named: "a.m4v")
        let text = try file(named: "b.txt")
        defer {
            try? FileManager.default.removeItem(at: movie.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: text.deletingLastPathComponent())
        }

        let items = pane().openWithMenuItems(for: [row(at: movie), row(at: text)])
        #expect(items.allSatisfy { $0.submenu == nil })
    }

    @Test("a type named by its description shows the system's own name for it")
    func titleByDescription() throws {
        let scope = DefaultApplicationScope(typeIdentifier: "public.jpeg", name: .typeDescription)
        let description = try #require(UTType.jpeg.localizedDescription)
        #expect(PanelViewController.alwaysOpenWithTitle(for: scope).contains(description))
    }

    // MARK: - Icons that catch up later

    /// A change made in Finder reaches macOS's icons minutes later, so coming to the front asks for
    /// them again; without it the icon read at launch stayed for the life of the process (2026-11-12).
    @Test("coming to the front forgets the type icons, so every pane asks again")
    func activationForgetsTypeIcons() async throws {
        _ = FileIconProvider.placeholder(for: .type(.plainText))
        final class Flag: @unchecked Sendable { var raised = false }
        let flag = Flag()
        let center = NotificationCenter.default
        let observer = center.addObserver(
            forName: FileIconProvider.typeIconsDidChange,
            object: nil,
            queue: .main
        ) { _ in flag.raised = true }
        defer { center.removeObserver(observer) }

        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        for _ in 0..<100 where !flag.raised {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(flag.raised)
    }

    // MARK: - macOS's answer

    /// The error Keep “VLC” answered in the live run of 2026-11-12, built the way it arrived.
    private static let keptByUser = NSError(
        domain: NSCocoaErrorDomain,
        code: NSFileReadUnknownError,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -128)]
    )

    @Test("keeping the old application in macOS's dialog is an answer, not a failure")
    func keepIsDeclined() {
        #expect(PanelViewController.isDeclined(Self.keptByUser))
        #expect(PanelViewController.isDeclined(CocoaError(.userCancelled)))
    }

    @Test("the same outer error with no cancel under it is a failure, and is shown")
    func otherErrorsAreFailures() {
        #expect(
            !PanelViewController.isDeclined(
                NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
            )
        )
        let otherUnder = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -10814)]
        )
        #expect(!PanelViewController.isDeclined(otherUnder))
    }

    /// A change opens the files in the application, as Finder's Always Open With does (Oleg,
    /// 2026-11-12); a kept application opens nothing, and a failure is said.
    @Test("a change opens the files, Keep opens nothing, and a failure is shown")
    func outcomes() {
        #expect(PanelViewController.outcome(of: nil) == .changed)
        #expect(PanelViewController.outcome(of: Self.keptByUser) == .kept)
        #expect(PanelViewController.outcome(of: CocoaError(.featureUnsupported)) == .failed)
    }
}
