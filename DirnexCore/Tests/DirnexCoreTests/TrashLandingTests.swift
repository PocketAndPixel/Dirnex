import Foundation
import Testing

@testable import DirnexCore

/// The two pure decisions a Trash move makes before it touches anything (PLAN.md §M26).
///
/// Every expected value here was read off `FileManager.trashItem` itself against the five live
/// provider domains on 2026-08-31, not derived — a Trash holding items Dirnex named one way and
/// Finder another is a surface the user reads, so agreeing with the platform *is* the requirement.
@Suite("Trash landing")
struct TrashLandingTests {
    // MARK: - What it is called when it lands

    /// The measured shape, and not the obvious one: the whole original name survives, extension
    /// included, and only the **last** path extension is re-appended after the stamp.
    @Test("a collision keeps the whole name and re-appends only the last extension")
    func collisionNameMatchesTheMeasuredFormat() {
        #expect(TrashLanding.collisionName(for: "m26-collide.txt", stamp: "01-14-42-179")
            == "m26-collide.txt 01-14-42-179.txt")
        #expect(TrashLanding.collisionName(for: "m26-collide.tar.gz", stamp: "01-14-42-527")
            == "m26-collide.tar.gz 01-14-42-527.gz")
    }

    /// A name with no extension gains no trailing dot — the case a naive
    /// `"\(base) \(stamp).\(ext)"` gets wrong by leaving one, which is a different file name.
    @Test("a name with no extension gains no trailing dot")
    func collisionNameWithoutAnExtension() {
        #expect(TrashLanding.collisionName(for: "m26-collide-noext", stamp: "01-14-42-346")
            == "m26-collide-noext 01-14-42-346")
        #expect(TrashLanding.collisionName(for: "m26-collide-dir", stamp: "01-14-42-699")
            == "m26-collide-dir 01-14-42-699")
    }

    /// A dotfile's leading dot is not an extension, so it must not be moved to the end — a
    /// `.gitignore` renamed to `.gitignore 01-14-42-179.gitignore` would be a different file.
    @Test("a dotfile keeps its leading dot and gains no extension")
    func collisionNameForADotfile() {
        #expect(TrashLanding.collisionName(for: ".gitignore", stamp: "01-14-42-179")
            == ".gitignore 01-14-42-179")
    }

    /// 24-hour, zero-padded, milliseconds — pinned against a fixed instant in a fixed zone so a
    /// developer in a 12-hour region cannot make it pass locally and stamp `01-14-42-179 AM`
    /// elsewhere. The formatter is `en_US_POSIX` for exactly that reason.
    @Test("the stamp is 24-hour HH-MM-SS-mmm regardless of the reader's region")
    func stampFormat() throws {
        let zone = try #require(TimeZone(identifier: "Europe/Kyiv"))
        // 20:04:05.017Z, which is 23:04 in Kyiv (UTC+3) — an hour a 12-hour formatter would
        // render as `11`, so the assertion fails rather than passes if the locale ever drifts.
        let date = Date(timeIntervalSince1970: 1_788_206_645.017)
        #expect(TrashLanding.stamp(for: date, timeZone: zone) == "23-04-05-017")
    }

    // MARK: - Which route

    /// The attribute is the gate, and it answers `true` for all five providers.
    @Test("an item the system calls ubiquitous takes the provider route")
    func ubiquitousItemIsAProviderItem() {
        #expect(TrashLanding.isProviderItem(
            isUbiquitous: true, path: "/Users/x/Library/CloudStorage/Box-Box/a.txt",
            home: "/Users/x"
        ))
    }

    /// A successful `false`/`nil` is authoritative — this is Google Drive in *mirror* mode, whose
    /// `<mount>/My Drive` is a symlink out to `~/My Drive`, so the file is an ordinary local one
    /// that `trashItem` handles perfectly. Reading the path prefix here instead would take Finder's
    /// Put Back away from it for no reason.
    @Test("an item under a provider root that the system does not call ubiquitous stays ordinary")
    func mirrorModeDriveStaysOrdinary() {
        #expect(!TrashLanding.isProviderItem(
            isUbiquitous: false,
            path: "/Users/x/Library/CloudStorage/GoogleDrive-a@b.com/My Drive/a.txt",
            home: "/Users/x"
        ))
    }

    /// The insurance clause, reached only when the read itself gave no answer: an item nobody can
    /// classify takes the route that works rather than the one that is refused.
    @Test("an unclassifiable item under a provider root takes the provider route")
    func unreadableAttributeFallsBackToThePath() {
        #expect(TrashLanding.isProviderItem(
            isUbiquitous: nil,
            path: "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/a.txt",
            home: "/Users/x"
        ))
        #expect(TrashLanding.isProviderItem(
            isUbiquitous: nil,
            path: "/Users/x/Library/CloudStorage/OneDrive-Personal/Documents/a.txt",
            home: "/Users/x"
        ))
    }

    /// The narrowness control for that clause: an unclassifiable item that is *not* under a provider
    /// root must still be ordinary, or "route the ones that are refused" quietly becomes "route
    /// everything" and every delete in the app loses Put Back.
    @Test("an unclassifiable item elsewhere stays ordinary")
    func unreadableAttributeElsewhereStaysOrdinary() {
        #expect(!TrashLanding.isProviderItem(
            isUbiquitous: nil, path: "/Users/x/Documents/a.txt", home: "/Users/x"
        ))
        // A sibling of the provider roots, not a child of one.
        #expect(!TrashLanding.isProviderItem(
            isUbiquitous: nil, path: "/Users/x/Library/CloudStorageNotes/a.txt", home: "/Users/x"
        ))
    }
}
