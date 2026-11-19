import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Quick View's movie and sound backend (PLAN.md §M42 ▸ Slice 1): `QuickViewMediaView`, for any file
/// whose type is audiovisual content and which AVFoundation opens.
///
/// **Opening the file decides, not its type.** Measured 2026-11-19 over a sample of every common
/// container: `public.avi` is among `AVURLAsset.audiovisualTypes()` and an AVI holding H.264 is refused
/// all the same, while Matroska and WebM are not on that list at all. So the type only says which files
/// are worth trying, and what AVFoundation refuses goes on to Quick Look exactly as it did before.
extension QuickViewPreviewView {
    /// Whether `url` is a movie or a sound, so it is offered to the player before Quick Look.
    static func isMedia(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .audiovisualContent) ?? false
    }

    /// Where a file goes that none of the in-process backends before it claimed: the player for a
    /// movie or a sound, and Quick Look for everything else. Also where the text backend sends a file
    /// it read and found not to be text, which is how a `.ts` transport stream reaches the player after
    /// the TypeScript sniff (`isMistypedSource`) has turned it away.
    func showBinary(_ url: URL?) {
        guard let url, Self.isMedia(url) else {
            showQuickLook(url)
            return
        }
        showMedia(url)
    }

    /// Show `url` in the player, standing the others down, or in Quick Look when AVFoundation will not
    /// open it.
    ///
    /// A cloud placeholder goes to Quick Look unopened: opening it reads it, and reading it downloads
    /// it because the cursor passed over the row (`isGoProRAW` keeps the same rule).
    func showMedia(_ url: URL) {
        guard !Self.isPlaceholder(url) else {
            standDownMedia()
            showQuickLook(url)
            return
        }
        let view = ensureMediaView()
        // Paused rather than let go: the file before stays on screen until this one is open, as a
        // picture does, and only the sound has to stop at once.
        view.player.pause()
        standDownPDF()
        standDownQuickLook()
        standDownImage()
        standDownText()
        standDownWeb()
        view.isHidden = false
        loadToken += 1
        let token = loadToken
        flipGate.isLoading = true
        let asset = AVURLAsset(url: url)
        Task { [weak self] in
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard let self, token == loadToken else { return }
            if playable {
                view.show(AVPlayerItem(asset: asset))
            } else {
                standDownMedia()
                showQuickLook(url)
            }
            contentDidLoad()
        }
    }

    /// Stand the player down unless `url` is a file it will be asked to show, which is called from
    /// `show` for every file: the one funnel, so no backend has to remember the player, and a sound
    /// never goes on under the next file whatever draws it.
    ///
    /// A movie or a sound that the TypeScript sniff takes first stands it down too. That file reaches
    /// the player again only if its bytes are not text, through `showBinary`.
    func standDownMedia(unlessShowing url: URL?) {
        if let url, Self.isMedia(url), !Self.isMistypedSource(url) { return }
        standDownMedia()
    }

    func standDownMedia() {
        mediaView?.isHidden = true
        mediaView?.stop()
    }

    private func ensureMediaView() -> QuickViewMediaView {
        if let mediaView { return mediaView }
        let view = QuickViewMediaView()
        pin(view, inside: content)
        mediaView = view
        return view
    }
}
