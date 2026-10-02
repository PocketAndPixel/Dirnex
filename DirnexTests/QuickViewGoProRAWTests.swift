import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Quick View's GoPro RAW route — the one image format macOS cannot decode at all.
///
/// Measured 2026-09-20 against two HERO7 files: ImageIO identifies the container as
/// `com.adobe.raw-image` and reads its whole metadata block, then answers `nil` to every call that
/// would produce pixels, and `CIRAWFilter.outputImage` is `nil` too — while a real `.dng` decodes
/// through the identical call. The payload is GoPro's VC-5 wavelet codec, and the file carries no
/// embedded preview to fall back on. So a GPR reaches the image backend through the bundled helper,
/// which converts it to a DNG the ordinary `RAWImageDecoder` then reads.
///
/// What is pinned here is the *routing* and the *bundling*. The decode needs a real GoPro file, so
/// it is verified live against `~/swtest/raw` like the RAW suite beside it.
@Suite("Quick View GoPro RAW")
@MainActor
struct QuickViewGoProRAWTests {
    /// A real GoPro file on the developer's own Mac, beside the RAW suite's.
    nonisolated static let liveGoProFile = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("swtest/raw/GOPR4581.GPR")

    // MARK: - Fixtures

    /// A little-endian TIFF header — what every DNG, and so every GPR, opens with.
    private static let tiffHeader = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])

    private static func file(named name: String, bytes: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gpr-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try bytes.write(to: url)
        return url
    }

    // MARK: - Routing

    @Test("a GoPro RAW reaches the image backend instead of Quick Look")
    func routesGoProRAWToTheImageBackend() throws {
        // Before this route existed the same file failed `isImage` and fell through to Quick Look,
        // which does not merely fail to preview it — measured, `qlmanage` sat on one for 45 s and
        // produced nothing, where an ARW and a DNG each produced a thumbnail in 0.5 s.
        let url = try Self.file(named: "GOPR4581.GPR", bytes: Self.tiffHeader)

        #expect(QuickViewPreviewView.isGoProRAW(url))
        #expect(QuickViewPreviewView.isImage(url))
    }

    @Test("the camera's own spelling and a lower-cased copy both route")
    func routesEitherSpelling() throws {
        for name in ["GOPR4581.GPR", "gopr4581.gpr"] {
            let url = try Self.file(named: name, bytes: Self.tiffHeader)
            #expect(QuickViewPreviewView.isGoProRAW(url), "\(name) should route")
        }
    }

    /// The narrowness control that matters most. `.gpr` is not GoPro's alone, and the decoder
    /// `abort()`s on input it dislikes — so a file merely *named* `.gpr` must keep whatever Quick
    /// Look does with it rather than being handed over.
    @Test("a .gpr that is not a DNG container is left to Quick Look")
    func leavesForeignGPRFilesAlone() throws {
        for (label, bytes) in [
            ("plain text", Data("G04*X1Y1D02*\n".utf8)),
            ("a JPEG", Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])),
            ("an empty file", Data())
        ] {
            let url = try Self.file(named: "drawing.gpr", bytes: bytes)
            #expect(
                !QuickViewPreviewView.isGoProRAW(url),
                "\(label) should not route as a GoPro RAW"
            )
            #expect(!QuickViewPreviewView.isImage(url), "\(label) should keep Quick Look")
        }
    }

    /// The other half of the narrowness: the header alone would claim every TIFF on the disk.
    @Test("a TIFF header under another name is not a GoPro RAW")
    func headerAloneDoesNotClaimAFile() throws {
        for name in ["scan.tiff", "photo.jpg", "notes.txt"] {
            let url = try Self.file(named: name, bytes: Self.tiffHeader)
            #expect(!QuickViewPreviewView.isGoProRAW(url), "\(name) must not take the helper route")
        }
    }

    /// A GPR must **not** take the Core Image route: it is the one RAW `CIRAWFilter` returns `nil`
    /// for, so claiming it there would route the file to a decoder that cannot read it and leave the
    /// helper unused.
    @Test("a GoPro RAW does not take the Core Image route")
    func doesNotTakeTheCoreImageRoute() throws {
        let url = try Self.file(named: "GOPR4581.GPR", bytes: Self.tiffHeader)

        #expect(!QuickViewPreviewView.isRAW(url))
    }

    /// Ordinary images must be untouched by any of this.
    @Test("ordinary images still route as before")
    func ordinaryImagesUnaffected() throws {
        for name in ["photo.jpg", "shot.png", "scan.tiff"] {
            let url = try Self.file(named: name, bytes: Self.tiffHeader)
            #expect(QuickViewPreviewView.isImage(url), "\(name) should still be an image")
        }
    }

    // MARK: - Bundling

    /// A check living in prose is not a check. The helper reaches the bundle through a Copy Files
    /// build phase, which nothing else in the suite exercises — and without it every GoPro RAW would
    /// silently show an empty preview, with no error and both linters clean.
    @Test("the build carries the decoder")
    func bundleCarriesTheHelper() throws {
        let helper = try #require(
            GPRConverter.helperURL,
            "Contents/Helpers/gpr_tools is missing — the Copy Files build phase is not running"
        )

        #expect(FileManager.default.isExecutableFile(atPath: helper.path))
    }

    // MARK: - Decoding

    /// Gated on the fixtures existing, the way every live suite here is.
    ///
    /// The claim is the one the whole feature rests on: the picture that comes back is the sensor's
    /// own 4000x3000 frame. There is no weaker version worth asserting — a GPR has no embedded
    /// thumbnail, so the failure mode is not a postage stamp but nothing at all.
    ///
    /// Skipped where the fixture is absent, CI among them. It once said so with a `#require`, which
    /// records a failure rather than a skip.
    @Test(
        "a real GoPro RAW converts and decodes at full size",
        .enabled(
            if: FileManager.default.fileExists(atPath: QuickViewGoProRAWTests.liveGoProFile.path),
            "no GOPR4581.GPR"
        )
    )
    func decodesRealGoProFiles() throws {
        let url = Self.liveGoProFile

        let converted = try #require(
            GPRConverter.shared.decodableCopy(of: url),
            "the helper should convert a real GoPro RAW"
        )
        let decoded = try #require(
            RAWImageDecoder.decode(converted),
            "the converted DNG should decode through the ordinary RAW route"
        )

        #expect(
            decoded.width * decoded.height > 1_000_000,
            "came back \(decoded.width)x\(decoded.height) — not the sensor frame"
        )
        // The second ask must be free: a conversion is ~0.2-0.5 s and writes ~23 MB, so stepping
        // back onto a file already converted has to hit the cache rather than spawn again.
        let started = Date()
        let again = GPRConverter.shared.decodableCopy(of: url)
        #expect(again == converted, "a second ask should return the cached conversion")
        #expect(Date().timeIntervalSince(started) < 0.1, "the second ask re-ran the helper")
    }
}
