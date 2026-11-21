import AppKit
import AVFoundation
import DirnexCore
import UniformTypeIdentifiers

/// Quick View's movie and sound backend (PLAN.md §M42): `QuickViewMediaView`, for any file whose type
/// is audiovisual content, or whose name is one of the containers macOS may leave untyped.
///
/// **Opening the file decides, not its type.** Measured 2026-11-19 over a sample of every common
/// container: `public.avi` is among `AVURLAsset.audiovisualTypes()` and an AVI holding H.264 is refused
/// all the same, while Matroska and WebM are not on that list at all. So the type only says which files
/// are worth trying. What AVFoundation refuses gets a card naming what it is kept in (Slice 2), where it
/// went on to Quick Look's icon before.
extension QuickViewPreviewView {
    /// Whether `url` is a movie or a sound, so it is offered to the player before Quick Look.
    ///
    /// The name counts as well as the type, for the containers AVFoundation refuses
    /// (`MediaContainer(fileExtension:)`). Their types come from whichever app declared them: on the
    /// Mac this was measured on, `org.matroska.mkv` came from VLC alone, so without VLC a `.mkv` is a
    /// dynamic type, and it would have gone through the text sniff to Quick Look without its card.
    static func isMedia(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .audiovisualContent) == true { return true }
        return MediaContainer(fileExtension: url.pathExtension) != nil
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

    /// Show `url` in the player, standing the others down, or the card when AVFoundation will not play
    /// it. It plays from its start once it is up when `autoplaysMedia` says so, and waits paused for
    /// ⌘P otherwise.
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
        view.prepareForNext()
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
        let language = view.soundLanguage
        Task { [weak self] in
            let opened = await MediaSummary.load(asset)
            var refused: Refusal?
            var sounds: QuickViewAudibleOptions?
            if opened?.isPlayable == true {
                sounds = await QuickViewAudibleOptions.load(asset)
            } else {
                refused = await Self.refusal(for: url, opened?.summary, language: language)
            }
            guard let self, token == loadToken else { return }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            switch refused {
            case let .card(content):
                view.showCard(content, icon: icon)
            case let .sampleBuffer(preparation, summary):
                view.show(
                    sampleBuffer: SampleBufferPlayer(preparation),
                    summary: summary,
                    icon: icon
                )
            case nil:
                if let opened {
                    view.show(AVPlayerItem(asset: asset), summary: opened.summary, sounds: sounds)
                }
            }
            // Asked here, once the file is up, so a change in Settings applies from the next file.
            if autoplaysMedia() { view.play() }
            contentDidLoad()
        }
    }

    /// What becomes of a file AVFoundation will not play: the core's own player for a Matroska, WebM
    /// or AVI file this Mac can decode (PLAN.md §M42 ▸ Slices 4 and 5), with what the file's own
    /// headers say it holds, and the card for everything else.
    enum Refusal {
        case sampleBuffer(SampleBufferPreparation, MediaSummary)
        case card(QuickViewMediaCard.Content)
    }

    /// What the core read of a refused file: the file itself for the containers it plays, and else the
    /// container its first bytes name.
    private enum CoreRead: Sendable {
        case matroska(MatroskaFile)
        case avi(AVIFile)
        case other(MediaContainer?)
    }

    /// The refusal for `url`, read off the main actor: its first bytes; for Matroska and WebM its head,
    /// and the first cluster when its picture is VP9; for an AVI its headers, its index and each
    /// stream's first chunk. A file the core plays opens on its sound in `language`, the app's.
    private static func refusal(
        for url: URL,
        _ summary: MediaSummary?,
        language: String?
    ) async -> Refusal {
        let core = await BlockingWork.run { () -> CoreRead in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return .other(nil) }
            defer { try? handle.close() }
            let prefix = (try? handle.read(upToCount: MediaContainer.sniffLength)) ?? Data()
            let container = MediaContainer.sniff(prefix)
            switch container {
            case .matroska, .webM:
                return (try? MatroskaFile(source: FileByteSource(url: url))).map(CoreRead.matroska)
                    ?? .other(container)
            case .avi:
                return (try? AVIFile(source: FileByteSource(url: url))).map(CoreRead.avi) ?? .other(
                    container
                )
            default:
                return .other(container)
            }
        }
        switch core {
        case let .matroska(file):
            let described = MediaSummary(matroska: file)
            if let preparation = await BlockingWork.run({
                SampleBufferPreparation.prepare(file, language: language)
            }) {
                return .sampleBuffer(preparation, described)
            }
            return .card(cardContent(for: url, sniffed: file.container, read: described))
        case let .avi(file):
            let described = MediaSummary(avi: file)
            if let preparation = await BlockingWork.run({
                SampleBufferPreparation.prepare(file, language: language)
            }) {
                return .sampleBuffer(preparation, described)
            }
            return .card(cardContent(for: url, sniffed: .avi, read: described))
        case let .other(container):
            return .card(cardContent(for: url, sniffed: container, read: summary))
        }
    }

    /// What the card says for `url`: its name, the container its first bytes name, and what it holds,
    /// as AVFoundation read it or, for Matroska, WebM and AVI, which AVFoundation refuses without a
    /// word, as the file's own headers say (PLAN.md §M42 ▸ Slices 3 and 5). A cloud placeholder never
    /// gets this far.
    ///
    /// Opening a Matroska file reads its head and nothing else: the film's tracks are in its first
    /// 6 KiB, and its cues, 10 GB further on, are left where they are.
    private static func cardContent(
        for url: URL,
        sniffed: MediaContainer?,
        read summary: MediaSummary?
    ) -> QuickViewMediaCard.Content {
        let container = sniffed ?? MediaContainer(fileExtension: url.pathExtension)
        let typeName = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            .flatMap { $0.isDynamic ? nil : $0.localizedDescription }
        return QuickViewMediaCard.Content(
            name: url.lastPathComponent,
            container: container?.displayName ?? typeName,
            summary: summary
        )
    }

    /// `caption` with the player's readout in it while a movie or a sound is up, for the header.
    func withMediaReadout(_ caption: QuickViewCaption?) -> QuickViewCaption? {
        guard var caption, let mediaView, !mediaView.isHidden else { return caption }
        caption.media = mediaView.readout
        return caption
    }

    /// ⌘P, and a click on the header's readout: play or pause, and bring a faded full-screen header back
    /// so the change can be seen.
    func toggleMediaPlayback() {
        mediaView?.togglePlayback()
        revealFloatingHeader()
    }

    /// ⌥⌘P: the next sound, with a faded full-screen header brought back to name it.
    func selectNextMediaSound() {
        mediaView?.selectNextSound()
        revealFloatingHeader()
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

    /// The player, made the first time a movie or a sound goes up. Internal, so a test can set its
    /// `soundLanguage` before the first file.
    func ensureMediaView() -> QuickViewMediaView {
        if let mediaView { return mediaView }
        let view = QuickViewMediaView()
        pin(view, inside: content)
        view.onReadoutChange = { [weak self] in self?.refreshCaption() }
        headerView?.onTogglePlayback = { [weak self] in self?.mediaView?.togglePlayback() }
        headerView?.onPickSound = { [weak self] id in self?.mediaView?.selectSound(id) }
        mediaView = view
        return view
    }
}

extension MediaSummary {
    /// Whether AVFoundation will play `asset`, and what it holds, or `nil` when it will not open it at
    /// all, which is when it reports nothing about it (PLAN.md §M42 ▸ P0).
    ///
    /// The picture's size is the first video track's, turned by its transform, so a portrait movie a
    /// phone recorded sideways reads taller than it is wide, as it plays.
    static func load(_ asset: AVURLAsset) async -> (isPlayable: Bool, summary: MediaSummary)? {
        guard let loaded = try? await asset.load(.isPlayable, .duration, .tracks) else { return nil }
        let (isPlayable, duration, tracks) = loaded
        var summary = MediaSummary(duration: duration.isNumeric ? duration.seconds : nil)
        for track in tracks {
            guard let described = try? await track.load(
                .formatDescriptions,
                .naturalSize,
                .preferredTransform
            ) else { continue }
            let (descriptions, size, transform) = described
            let names = descriptions.map { MediaCodecName.name(
                for: CMFormatDescriptionGetMediaSubType($0)
            ) }
            switch track.mediaType {
            case .video:
                summary.videoCodecs += names
                if summary.pictureSize == nil {
                    let shown = size.applying(transform)
                    summary.pictureSize = PictureSize(
                        width: Int(abs(shown.width).rounded()),
                        height: Int(abs(shown.height).rounded())
                    )
                }
            case .audio:
                summary.audioCodecs += names
            default:
                break
            }
        }
        return (isPlayable, summary)
    }
}
