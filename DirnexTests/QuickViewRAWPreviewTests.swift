import AppKit
import DirnexCore
import Testing
import UniformTypeIdentifiers

@testable import Dirnex

/// Quick View's camera RAW route.
///
/// A RAW file previewed through `NSImage(data:)` comes back as the embedded **160×120** thumbnail —
/// a NEF is a TIFF container, and bytes with no file name attached identify as `public.tiff` — which
/// drew a 38 pt postage stamp in the middle of the surface. Nothing logged, both suites stayed
/// green, and it was reported by a user (2026-08-14).
///
/// What can be pinned headlessly is the *routing*: which files take the Core Image path, and that it
/// still narrows `isImage` rather than widening it. The decode itself needs a real RAW file and real
/// camera-model support, so it is verified live against `~/swtest/raw` rather than from a fixture —
/// no RAW small enough to check into a repo would exercise a demosaic anyway.
@Suite("Quick View RAW preview")
@MainActor
struct QuickViewRAWPreviewTests {
    // MARK: - Routing

    /// Keyed on the `.rawImage` conformance, so the formats are covered without being named.
    @Test("camera RAW files take the Core Image route")
    func routesRAWFiles() {
        for name in [
            "DSC_0001.NEF",
            "IMG_1234.CR2",
            "IMG_1234.CR3",
            "DSC00001.ARW",
            "P1000001.RW2",
            "shot.dng",
            "shot.ORF",
            "shot.raf",
            "shot.pef"
        ] {
            let url = URL(fileURLWithPath: "/does/not/exist/\(name)")
            #expect(QuickViewPreviewView.isRAW(url), "\(name) should decode through Core Image")
        }
    }

    /// The narrowness control. `isRAW` selects *within* the image backend, so anything it wrongly
    /// claims is a file Core Image cannot decode at all — it handles RAW only — and the fallback
    /// would be doing the real work while the RAW route took the blame.
    @Test("ordinary images keep the NSImage route")
    func leavesOrdinaryImagesAlone() {
        for name in [
            "photo.jpg",
            "photo.jpeg",
            "shot.png",
            "shot.heic",
            "scan.tiff",
            "clip.gif",
            "art.svg",
            "icon.webp"
        ] {
            let url = URL(fileURLWithPath: "/does/not/exist/\(name)")
            #expect(!QuickViewPreviewView.isRAW(url), "\(name) should not take the RAW route")
        }
    }

    /// `isRAW` may only ever narrow the image backend: a file it claims that `isImage` refuses would
    /// never reach `showImage` at all, so the RAW route would be dead for it.
    @Test("every RAW type is also an image type")
    func rawImpliesImage() {
        for ext in ["nef", "cr2", "cr3", "arw", "dng", "orf", "raf", "rw2", "pef", "srw"] {
            let type = try? #require(UTType(filenameExtension: ext))
            #expect(type?.conforms(to: .image) == true, ".\(ext) must also classify as an image")
        }
    }

    /// The three extensions macOS declares no type for. They conform to nothing, so they already
    /// fail `isImage` and route to Quick Look; this pins that the RAW route does not claim them and
    /// leave them somewhere Core Image cannot help.
    @Test("undeclared RAW extensions are left to Quick Look")
    func undeclaredExtensionsUnclaimed() {
        for name in ["shot.x3f", "shot.gpr", "shot.kdc"] {
            let url = URL(fileURLWithPath: "/does/not/exist/\(name)")
            #expect(!QuickViewPreviewView.isRAW(url))
            #expect(!QuickViewPreviewView.isImage(url))
        }
    }

    // MARK: - Decoding

    /// Gated on the files existing, the way every live suite here is — `xcodebuild` forwards no
    /// shell environment, so the gate is a *file* (▸ NOTES.md, Testing).
    ///
    /// Three claims. The decode must come back at the sensor's own resolution, not the embedded
    /// thumbnail's — anything under a megapixel means the preview is showing the postage stamp
    /// again. A portrait frame must come back *portrait*: `MG_3010.CR2` carries EXIF orientation 8,
    /// which `CGImageSourceCreateImageAtIndex` ignores and this route applies.
    ///
    /// And the demosaic must happen **inside this call**, because the whole reason it is called from
    /// a detached task is to keep ~230 ms off the main thread. `CIContext.createCGImage` returns a
    /// *lazy* image — correct extent, no pixels — and defers that cost to whoever first draws it,
    /// which is the main thread, on a preview that appears when the cursor moves.
    ///
    /// What separates them is the *residual* work — how long it takes to obtain the pixels **after**
    /// `decode` has returned — which is zero by construction when the render already happened and is
    /// the whole demosaic when it did not. Measured over five files: **0.0 ms** against 68–132 ms.
    /// That is a property rather than a stopwatch reading, so it does not drift with the machine.
    ///
    /// Three weaker assertions were tried against the lazy version first. Reading the dimensions
    /// passed (0.26 s for five RAW files — faster than a single decode, which is the tell); reading
    /// `dataProvider.data` passed, because it merely *forces* the render it was meant to detect; and
    /// timing `decode` itself against a 20 ms floor failed by **16 µs**, since setting a RAW filter
    /// up costs about that much on its own. A threshold that close is a coin toss, not a test.
    @Test("a real RAW decodes at full size, with orientation applied")
    func decodesRealRAWFiles() throws {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("swtest/raw")
        try #require(
            FileManager.default.fileExists(atPath: directory.path),
            "live RAW fixtures absent — skipping"
        )
        for name in ["DSC02467.ARW", "DSC_0004.NEF", "P1011960.RW2", "P1060804.dng"] {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let decoded = try #require(RAWImageDecoder.decode(url), "\(name) should decode")
            #expect(
                decoded.width * decoded.height > 1_000_000,
                "\(name) came back \(decoded.width)x\(decoded.height) — the embedded thumbnail, not the frame"
            )
            let started = Date()
            _ = decoded.dataProvider?.data
            let residual = Date().timeIntervalSince(started)
            #expect(
                residual < 0.01,
                "\(name) needed \(Int(residual * 1000)) ms for its pixels — the demosaic was deferred"
            )
        }
        let portrait = directory.appendingPathComponent("MG_3010.CR2")
        if FileManager.default.fileExists(atPath: portrait.path) {
            let decoded = try #require(RAWImageDecoder.decode(portrait))
            #expect(
                decoded.height > decoded.width,
                "orientation 8 should come back portrait, not \(decoded.width)x\(decoded.height)"
            )
        }
    }
}
