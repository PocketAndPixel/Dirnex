import AppKit
import CoreImage
import DirnexCore
import UniformTypeIdentifiers

/// Core Image's RAW pipeline, which is how a camera RAW file reaches the image backend.
///
/// A RAW file cannot go through `NSImage(data:)` at all, and the way it fails is quiet: a NEF is a
/// TIFF container, so ImageIO handed bare *bytes* — with no file name to identify them by — reads it
/// as `public.tiff` and returns the embedded **160×120** thumbnail as the primary image. At that
/// thumbnail's 300 dpi it is 38 pt across, and `scaleProportionallyDown` never upscales, so the
/// preview drew a postage stamp in the middle of the surface with nothing logged (reported
/// 2026-08-14). Renaming the same file to `.dat` collapses *every* route to 160×120, which is what
/// proves the file name is the whole mechanism.
///
/// Measured against `CGImageSourceCreateImageAtIndex` over ARW/CR2/NEF/RW2/DNG (PLAN.md §M21): the
/// two renderings are the same to **0.02–0.10** levels out of 255 at 1:1, centre and edge, with
/// identical variance-of-Laplacian — they run the same demosaic — while Core Image is **3–4×**
/// faster (99–170 ms against 370–509 ms) because it is GPU-backed. What decides it is orientation:
/// `CreateImageAtIndex` ignores the EXIF tag and lays a portrait photograph on its side, where this
/// applies it. The remaining ImageIO spelling that *does* transform,
/// `CGImageSourceCreateThumbnailAtIndex`, was measured to diverge from a true demosaic on one of the
/// five files (8.69 levels, with *higher* apparent detail — the shape of a camera's own sharpened
/// preview), so it is not the safe uniform answer it looks like.
enum RAWImageDecoder {
    /// `CIContext` is `Sendable` and documented thread-safe, so one instance serves every decode and
    /// is reachable from the detached task that runs them. It cannot live on `QuickViewPreviewView`:
    /// a `static` on a `@MainActor` type is main-actor isolated, and the decode is not.
    static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Decode `url` at full resolution with its EXIF orientation applied, or `nil` if Core Image has
    /// no support for this file — RAW support is per *camera model*, not merely per format, so a
    /// very recent body legitimately lands here and the caller falls back.
    ///
    /// The output is 8-bit Display P3. Tagging it explicitly is the point: Core Image's default is
    /// *untagged* `DeviceRGB`, which leaves the preview's colour to whatever the display assumes.
    /// 16-bit was measured and rejected — 2× the memory (152–183 MB for one photograph) and ~2.5×
    /// the time, for precision an 8-bit screen cannot show.
    ///
    /// It renders into a bitmap of our own rather than calling `createCGImage`, and that is the whole
    /// reason this runs off the main actor at all: `createCGImage` returns a **lazy** image in
    /// **0 ms** and defers the entire demosaic to whoever first draws it — which is the main thread,
    /// for 223–241 ms, on a preview that appears when the cursor moves. `render(_:toBitmap:)` does
    /// the work here, in the detached task (99–120 ms), and the finished bitmap also draws cheaper
    /// afterwards (7–9 ms against 18 ms). A test cannot catch the lazy version by reading the image's
    /// size — the extent is correct either way, which is exactly how it passed first time.
    static func decode(_ url: URL) -> CGImage? {
        guard let filter = CIRAWFilter(imageURL: url),
              let output = filter.outputImage,
              let space = CGColorSpace(name: CGColorSpace.displayP3)
        else { return nil }
        let extent = output.extent
        guard !extent.isInfinite, !extent.isEmpty,
              let bitmap = CGContext(
                  data: nil,
                  width: Int(extent.width),
                  height: Int(extent.height),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let pixels = bitmap.data
        else { return nil }
        context.render(
            output,
            toBitmap: pixels,
            rowBytes: bitmap.bytesPerRow,
            bounds: extent,
            format: .RGBA8,
            colorSpace: space
        )
        return bitmap.makeImage()
    }
}

/// Quick View's image backend: which files it takes, and how their bytes reach it.
///
/// Split out of the class body when the web backend landed and pushed it past SwiftLint's
/// `type_body_length` (PLAN.md §M16) — and it belongs out here anyway, beside `+Text` and `+HTML`,
/// so each in-process backend states its own reason for existing next to its own code.
extension QuickViewPreviewView {
    /// Show `url` in the plain `NSImageView` backend, standing the others down.
    ///
    /// Images bypass Quick Look deliberately (PLAN.md §M11). `QLPreviewView` renders in *another
    /// process*, so translating the layer that hosts it costs a round trip per frame — measured as
    /// a visibly juddering two-finger swipe, on exactly the content people swipe through most.
    /// An `NSImageView` is in-process, like the `PDFView` beside it, and the swipe runs at full rate.
    ///
    /// The bytes are read off the main actor so a large photo does not stall the flip; `Data` is
    /// `Sendable` where `NSImage` is not, which is why the image itself is built back here.
    func showImage(_ url: URL) {
        let view = ensureImageView()
        standDownPDF()
        standDownQuickLook()
        standDownText()
        standDownWeb()
        view.isHidden = false
        loadToken += 1
        let token = loadToken
        let isRAW = Self.isRAW(url)
        flipGate.isLoading = true
        Task { [weak self] in
            let image = await Self.loadImage(at: url, isRAW: isRAW)
            guard let self, token == loadToken else { return }
            view.image = image
            // Announce even when `image` is nil: a file that fails to decode has still finished
            // loading, and a page turn waiting on it would otherwise sit out its whole bound.
            contentDidLoad()
        }
    }

    /// Decode `url` off the main actor and build the `NSImage` back on it.
    ///
    /// The two routes are not interchangeable and neither covers the other's files: Core Image
    /// handles camera RAW only, and `NSImage(data:)` — which is right for everything else, honours
    /// EXIF orientation, and needs no change — cannot read a RAW at all (▸ `RAWImageDecoder`). A RAW
    /// whose camera model Core Image does not know falls back rather than showing nothing: the
    /// embedded preview is small, but it is the picture.
    private static func loadImage(at url: URL, isRAW: Bool) async -> NSImage? {
        if isRAW, let decoded = await BlockingWork.run({ RAWImageDecoder.decode(url) }) {
            return NSImage(
                cgImage: decoded,
                size: NSSize(width: decoded.width, height: decoded.height)
            )
        }
        let data = await BlockingWork.run {
            try? Data(contentsOf: url, options: .mappedIfSafe)
        }
        return data.flatMap(NSImage.init(data:))
    }

    func standDownImage() {
        imageView?.isHidden = true
        imageView?.image = nil
    }

    /// Whether `url` is an image, so it routes to the in-process `NSImageView`. Content type first
    /// (an odd extension still classifies), extension as the fallback.
    static func isImage(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// Whether `url` is a camera RAW, so it decodes through Core Image rather than `NSImage(data:)`.
    /// Same shape as `isImage` above — content type first, extension as the fallback — and every RAW
    /// type the system declares conforms to `.image` as well, so this narrows that route and never
    /// widens it.
    ///
    /// Keying on the `.rawImage` conformance rather than a list of extensions is what makes it cover
    /// the formats without naming them: of 24 RAW extensions checked, 21 resolve to a declared UTI
    /// and all 21 are among the 30 RAW types ImageIO knows. The three that do not — `x3f`, `gpr`,
    /// `kdc` — get placeholder `dyn.…` types that conform to nothing, so they already fail `isImage`
    /// and route to Quick Look; this leaves them exactly where they were.
    static func isRAW(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .rawImage)
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) ?? false
    }

    /// Build the image backend on first use. `scaleProportionallyDown` matches Quick Look: fit a
    /// large photo to the surface, but never blow a small one up past its own size.
    func ensureImageView() -> NSImageView {
        if let imageView { return imageView }
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.animates = true
        // An `NSImageView`'s intrinsic content size is its *image*, and it defends that size at
        // priority 750 — so a wide photo pushes the whole constraint chain outwards and resizes the
        // **window**. A 8629 px panorama grew it past the edge of the display, cutting off the
        // function bar, with every frame in the preview itself still provably correct. The surface
        // is sized by its anchors alone; the image inside is a passenger.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            view.setContentCompressionResistancePriority(.init(1), for: axis)
            view.setContentHuggingPriority(.init(1), for: axis)
        }
        pin(view, inside: content)
        imageView = view
        return view
    }
}
