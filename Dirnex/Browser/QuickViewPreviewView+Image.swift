import AppKit
import UniformTypeIdentifiers

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
        Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: url, options: .mappedIfSafe)
            }.value
            guard let self, token == loadToken else { return }
            view.image = data.flatMap(NSImage.init(data:))
        }
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
