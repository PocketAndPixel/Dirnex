import AppKit
import DirnexCore
import QuickLookThumbnailing

/// The row icons that need a read of the item (2026-11-11): a folder's own icon and a Quick Look
/// picture of a file's content. Both are loaded off the main thread, kept, and handed out by key.
///
/// Off the main thread because a folder's own icon is not cheap the first time. Measured in a fresh
/// process: Home's 26 folders took 40 ms in `NSWorkspace.icon(forFile:)` and 199 ms more on first
/// draw, 77 ms of it for Music alone, which on the main thread would be a hitch on every first visit.
/// So the icon is fetched *and drawn* into a bitmap on a background thread, which came out byte for
/// byte what a main-thread draw gives (15 of 15, apps and special folders included), and the row
/// shows its placeholder until then. Quick Look's own `.icon` representation was tried for this and
/// is worse: 308 ms against 56 ms for the same 15 items, and three applications drawn differently.
///
/// A row asks with ``image(for:kind:pointSize:scale:appearance:)`` on every render and gets `nil`
/// until its image is in; a pane listens for ``didLoadNotification`` and re-asks for its visible rows.
@MainActor
final class RowIconLoader {
    static let shared = RowIconLoader()

    /// Posted when images have arrived, at most once per ``notifyDelay``, so every pane re-asks for
    /// its visible rows; also when the app's appearance changes, which makes every key a new one.
    static let didLoadNotification = Notification.Name("Dirnex.rowIconsDidLoad")

    enum Kind: Hashable {
        /// The item's own icon, as `NSWorkspace.icon(forFile:)` draws it.
        case item
        /// A Quick Look thumbnail of the content.
        case thumbnail
    }

    /// One image: the item as it was listed, at one size, in one appearance. The date and size are
    /// in it so that an edited picture or a replaced application loads afresh on the next listing.
    /// The appearance is in it because an application's icon has a dark variant on macOS 26 (Xcode
    /// and Preview drew differently in `darkAqua` and `aqua`; folders did not).
    struct Key: Hashable {
        let path: String
        let modified: Date
        let size: Int64
        let kind: Kind
        let pointSize: CGFloat
        let scale: CGFloat
        let appearance: String
    }

    /// How many loads run at once. Quick Look queues inside as well; this keeps a fast scroll through
    /// a big folder from handing it thousands of requests for rows that are already gone.
    private static let maxRunning = 6
    /// How many waiting loads are kept. The newest run first, since they are the rows on screen now;
    /// past this the oldest are dropped, and a row scrolled back into view simply asks again.
    private static let maxWaiting = 256
    private static let notifyDelay: Duration = .milliseconds(50)

    private let cache = NSCache<CacheKey, Loaded>()
    private var waiting: [Key] = []
    private var running: Set<Key> = []
    private var notifyScheduled = false
    private var appearanceObservation: NSKeyValueObservation?

    private init() {
        // About 16 MB at the largest row's 40 px; a folder of more pictures than this reloads the
        // ones scrolled furthest away.
        cache.countLimit = 4000
    }

    /// The loaded image for `entry`, or `nil` while it is loading or when there is none to show, in
    /// which case the row keeps its placeholder. A miss starts the load.
    func image(
        for entry: FileEntry,
        kind: Kind,
        pointSize: CGFloat,
        scale: CGFloat,
        appearance: NSAppearance
    ) -> NSImage? {
        observeAppearanceOnce()
        let key = Key(
            path: entry.path.path,
            modified: entry.modificationDate,
            size: entry.byteSize,
            kind: kind,
            pointSize: pointSize,
            scale: scale,
            appearance: Self.appearanceName(appearance).rawValue
        )
        if let loaded = cache.object(forKey: CacheKey(key)) { return loaded.image }
        enqueue(key)
        return nil
    }

    // MARK: - Loading

    private func enqueue(_ key: Key) {
        guard !running.contains(key) else { return }
        // Re-asked: to the top, since it is on screen now.
        waiting.removeAll { $0 == key }
        waiting.append(key)
        if waiting.count > Self.maxWaiting { waiting.removeFirst(waiting.count - Self.maxWaiting) }
        startWaiting()
    }

    private func startWaiting() {
        while running.count < Self.maxRunning, let key = waiting.popLast() {
            running.insert(key)
            Task {
                let image = await Self.load(key)
                finish(key, image: image)
            }
        }
    }

    private func finish(_ key: Key, image: CGImage?) {
        running.remove(key)
        let loaded = image.map {
            NSImage(
                cgImage: $0,
                size: NSSize(
                    width: CGFloat($0.width) / key.scale,
                    height: CGFloat($0.height) / key.scale
                )
            )
        }
        // A miss is kept too, so a file Quick Look has nothing for is not asked again on every render.
        cache.setObject(Loaded(loaded), forKey: CacheKey(key))
        if loaded != nil { scheduleNotify() }
        startWaiting()
    }

    private func scheduleNotify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        Task {
            try? await Task.sleep(for: Self.notifyDelay)
            notifyScheduled = false
            NotificationCenter.default.post(name: Self.didLoadNotification, object: self)
        }
    }

    /// The app's appearance changed, so every key the panes ask for is a new one: tell them to ask.
    /// Observed on first use rather than at init, so nothing here needs `NSApp` before it exists.
    private func observeAppearanceOnce() {
        guard appearanceObservation == nil else { return }
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { _, _ in
            MainActor.assumeIsolated { RowIconLoader.shared.scheduleNotify() }
        }
    }

    private nonisolated static func load(_ key: Key) async -> CGImage? {
        switch key.kind {
        case .item:
            await Task.detached(priority: .userInitiated) { drawItemIcon(key) }.value
        case .thumbnail:
            await thumbnail(key)
        }
    }

    private nonisolated static func thumbnail(_ key: Key) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: key.path),
            size: CGSize(width: key.pointSize, height: key.pointSize),
            scale: key.scale,
            representationTypes: .thumbnail
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }

    /// `NSWorkspace.icon(forFile:)` drawn into a bitmap of the row's size, in the row's appearance.
    private nonisolated static func drawItemIcon(_ key: Key) -> CGImage? {
        let pixels = Int((key.pointSize * key.scale).rounded())
        guard pixels > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixels,
                  height: pixels,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: key.path)
        let appearance = NSAppearance(named: NSAppearance.Name(key.appearance)) ?? NSAppearance(
            named: .aqua
        )
        appearance?.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()
        }
        return context.makeImage()
    }

    /// The named appearance `appearance` draws as, which is what an icon's variant follows.
    private static func appearanceName(_ appearance: NSAppearance) -> NSAppearance.Name {
        appearance.bestMatch(from: [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua
        ]) ?? .aqua
    }
}

/// `NSCache` wants an object for a key.
private final class CacheKey: NSObject {
    let key: RowIconLoader.Key

    init(_ key: RowIconLoader.Key) {
        self.key = key
    }

    override var hash: Int { key.hashValue }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? CacheKey)?.key == key
    }
}

/// What a load gave, `nil` included: a file with no thumbnail is remembered as having none.
private final class Loaded {
    let image: NSImage?

    init(_ image: NSImage?) {
        self.image = image
    }
}
