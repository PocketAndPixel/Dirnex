import Foundation
import Testing

@testable import DirnexCore

/// Which rows a Quick View slideshow stops on, where it goes next, and its interval (PLAN.md §M39 ▸
/// Slice 16).
@Suite("Slideshow")
struct SlideshowTests {
    private func entry(
        _ name: String,
        kind: FileEntry.Kind = .file,
        target: FileEntry.Kind? = nil
    ) -> FileEntry {
        FileEntry(
            path: .local("/photos/\(name)"),
            name: name,
            kind: kind,
            byteSize: 1,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o644,
            inode: 1,
            symlinkTargetKind: target
        )
    }

    private func entries(_ names: String...) -> [FileEntry] {
        names.map { entry($0) }
    }

    // MARK: - Which rows

    @Test("a picture is a slide whatever its extension's case, RAW, SVG and GoPro RAW included")
    func picturesAreSlides() {
        let names = "a.jpg B.JPG c.heic d.png e.webp f.gif g.svg h.NEF i.dng j.GPR k.tiff l.avif"
        for name in names.split(separator: " ").map(String.init) {
            #expect(Slideshow.isSlide(entry(name)), "\(name)")
        }
    }

    @Test("a document, a video, a PDF and a name with no extension are passed over")
    func otherFilesAreNot() {
        let names = "notes.txt clip.mov film.mp4 scan.pdf README archive.zip .jpg"
        for name in names.split(separator: " ").map(String.init) {
            #expect(!Slideshow.isSlide(entry(name)), "\(name)")
        }
    }

    /// A folder can be called anything, and a link is only a slide when it leads to a file: the
    /// preview of a link to a folder is not a picture.
    @Test(
        "a folder named like a picture is passed over, a link is a slide only when it leads to a file"
    )
    func foldersAndLinks() {
        #expect(!Slideshow.isSlide(entry("Holiday.jpg", kind: .directory)))
        #expect(Slideshow.isSlide(entry("cover.jpg", kind: .symlink, target: .file)))
        #expect(!Slideshow.isSlide(entry("album.jpg", kind: .symlink, target: .directory)))
        #expect(!Slideshow.isSlide(entry("broken.jpg", kind: .symlink)))
        #expect(!Slideshow.isSlide(entry("pipe.jpg", kind: .other)))
    }

    // MARK: - Where it opens

    @Test("it opens on the cursor's own picture, so the one on screen gets its full turn")
    func opensOnTheCursorsPicture() {
        let rows = entries("a.jpg", "b.jpg", "c.jpg")
        #expect(Slideshow.firstSlide(from: 1, in: rows) == 1)
    }

    @Test("from a document it opens on the next picture, wrapping past the end")
    func opensOnTheNextPicture() {
        let rows = entries("a.jpg", "notes.txt", "b.png", "readme.md")
        #expect(Slideshow.firstSlide(from: 1, in: rows) == 2)
        #expect(Slideshow.firstSlide(from: 3, in: rows) == 0)
    }

    @Test("from the parent row it opens on the first picture")
    func opensFromTheParentRow() {
        let rows = entries("notes.txt", "a.jpg", "b.jpg")
        #expect(Slideshow.firstSlide(from: nil, in: rows) == 1)
    }

    @Test("with no picture, or no rows, there is nothing to open on")
    func nothingToOpenOn() {
        #expect(Slideshow.firstSlide(from: 0, in: entries("notes.txt", "clip.mov")) == nil)
        #expect(Slideshow.firstSlide(from: nil, in: []) == nil)
        #expect(Slideshow.firstSlide(from: 0, in: []) == nil)
    }

    // MARK: - Where it goes next

    @Test("each step passes over everything that is not a picture")
    func stepsPassOverOtherFiles() {
        let rows = entries("a.jpg", "notes.txt", "Album", "clip.mov", "b.png")
        #expect(Slideshow.nextSlide(after: 0, in: rows) == 4)
    }

    /// Loops until stopped (Oleg's call, 2026-11-15): after the last picture comes the first, and a
    /// row of other files at either end makes no difference.
    @Test("after the last picture it wraps to the first")
    func wrapsToTheFirst() {
        let rows = entries("notes.txt", "a.jpg", "b.jpg", "readme.md")
        #expect(Slideshow.nextSlide(after: 2, in: rows) == 1)
        #expect(Slideshow.nextSlide(after: 3, in: rows) == 1)
    }

    @Test("a lone picture is its own next one, and no picture means no next one")
    func lonePictureAndNone() {
        #expect(Slideshow.nextSlide(after: 1, in: entries("notes.txt", "a.jpg")) == 1)
        #expect(Slideshow.nextSlide(after: 0, in: entries("notes.txt", "a.md")) == nil)
        #expect(Slideshow.nextSlide(after: 0, in: []) == nil)
    }

    /// A refresh can shorten the listing under a running slideshow; a cursor left past the end
    /// counts from the top rather than trapping or skipping the first picture.
    @Test("a cursor outside the rows counts from before the first")
    func cursorOutsideTheRows() {
        let rows = entries("a.jpg", "b.jpg")
        #expect(Slideshow.nextSlide(after: 7, in: rows) == 0)
        #expect(Slideshow.nextSlide(after: -3, in: rows) == 0)
    }

    // MARK: - The command

    /// Here rather than in `CommandCatalogTests`, which sits at its type-body ceiling.
    @Test("Slideshow is a conflict-free View command on ⇧⌘S, beside ⌘S, ⌃⌘S and ⌥⌘S")
    func command() {
        let slideshow = CommandCatalog.all.first { $0.id == "view.quickViewSlideshow" }
        #expect(slideshow?.category == .view)
        #expect(slideshow?.shortcut == CommandShortcut(key: "s", modifiers: [.command, .shift]))
        #expect(KeyBindings().conflicts(for: "view.quickViewSlideshow").isEmpty)
    }

    // MARK: - The interval

    @Test(
        "the interval defaults to Preview's five seconds and is held to one second through a minute"
    )
    func intervalClamp() {
        #expect(Slideshow.defaultInterval == 5)
        #expect(Slideshow.intervalRange.contains(Slideshow.defaultInterval))
        #expect(Slideshow.clampedInterval(0) == 1)
        #expect(Slideshow.clampedInterval(-4) == 1)
        #expect(Slideshow.clampedInterval(12) == 12)
        #expect(Slideshow.clampedInterval(600) == 60)
    }
}
