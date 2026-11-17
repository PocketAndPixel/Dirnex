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
/// A row asks with ``image(for:)`` when it is drawn and gets `nil` until its image is in. A pane
/// listens for ``didLoadNotification``, which carries the images that arrived, puts each in the row
/// that asked for it, and asks again for the rest of its rows on screen.
///
/// Both are about the cache being an `NSCache`, which lets go of entries while the system is under
/// memory pressure (2026-11-17). When each arrival only made every pane ask again for all its rows, a
/// row the cache had let go of got its placeholder back and another load, whose arrival asked again,
/// and so on. Seen by Oleg as thumbnails and My Drive's icon blinking several times a second: the log
/// held the same four custom-icon folders loaded about eight times a second each for 3½ minutes, at a
/// warning pressure level that lasted all night, and the same build never did it once the pressure was
/// back to normal (docs/NOTES.md ▸ Drawing rows and cells). So an arrival carries its images rather
/// than leaving them in the cache to be read back, and an image some row is still drawing is answered
/// from ``drawn`` whatever the cache has let go of, so asking again for a row on screen (on an arrival,
/// on coming to the front, on a reload) neither blanks it nor loads it again.
@MainActor
final class RowIconLoader {
    static let shared = RowIconLoader()

    /// Posted when images have arrived, at most once per ``notifyDelay``, with the images in its
    /// `userInfo` (``arrivals(in:)``), so a pane can put them in its rows whatever the cache has let go
    /// of since.
    static let didLoadNotification = Notification.Name("Dirnex.rowIconsDidLoad")

    /// Posted when the app's appearance changes, which makes every key a new one, so every pane asks
    /// again for its visible rows.
    static let keysDidChangeNotification = Notification.Name("Dirnex.rowIconKeysDidChange")

    private static let arrivalsKey = "arrivals"

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
    /// The images that arrived since the last ``didLoadNotification``, posted with the next one. The
    /// notification carries them rather than leaving the panes to read them back from the cache,
    /// which may have let them go in the 50 ms between.
    private var arrived: [Key: NSImage] = [:]
    /// Every image handed out, held weakly: one that a cell is still drawing stays here when the cache
    /// lets it go, so a row on screen asked again gets the same picture back. Emptied entries are
    /// swept when the table has doubled since the last sweep.
    private var drawn: [Key: WeakImage] = [:]
    private var sweepDrawnAt = 512
    private var notifyScheduled = false
    private var reaskScheduled = false
    private var appearanceObservation: NSKeyValueObservation?

    /// Tests only: told of every load as it starts, and of every result as it is stored.
    var didStartLoad: ((Key) -> Void)?
    var didStore: ((Key) -> Void)?
    /// Tests only: while set, nothing starts loading, so requests wait and the oldest are dropped past
    /// ``maxWaiting``, as behind a long scroll.
    var holdsLoads = false {
        didSet { if !holdsLoads { startWaiting() } }
    }

    private init() {
        // About 16 MB at the largest row's 40 px; a folder of more pictures than this reloads the
        // ones scrolled furthest away.
        cache.countLimit = 4000
    }

    /// The key `entry`'s image is kept under, for a row drawn at `pointSize` and `scale` in
    /// `appearance`.
    func key(
        for entry: FileEntry,
        kind: Kind,
        pointSize: CGFloat,
        scale: CGFloat,
        appearance: NSAppearance
    ) -> Key {
        observeAppearanceOnce()
        return Key(
            path: entry.path.path,
            modified: entry.modificationDate,
            size: entry.byteSize,
            kind: kind,
            pointSize: pointSize,
            scale: scale,
            appearance: Self.appearanceName(appearance).rawValue
        )
    }

    /// The loaded image for `key`, or `nil` while it is loading or when there is none to show, in
    /// which case the row keeps its placeholder. A miss starts the load, unless a row is still
    /// drawing the image, which is answered without one.
    func image(for key: Key) -> NSImage? {
        if let loaded = cache.object(forKey: CacheKey(key)) { return loaded.image }
        if let image = drawn[key]?.image { return image }
        enqueue(key)
        return nil
    }

    /// ``image(for:)`` for `entry`, its key made here.
    func image(
        for entry: FileEntry,
        kind: Kind,
        pointSize: CGFloat,
        scale: CGFloat,
        appearance: NSAppearance
    ) -> NSImage? {
        image(
            for: key(
                for: entry,
                kind: kind,
                pointSize: pointSize,
                scale: scale,
                appearance: appearance
            )
        )
    }

    /// The images a ``didLoadNotification`` brought, by key.
    static func arrivals(in notification: Notification) -> [Key: NSImage] {
        notification.userInfo?[arrivalsKey] as? [Key: NSImage] ?? [:]
    }

    /// Let go of `keys`, as `NSCache` does on its own under memory pressure. For tests, which have no
    /// other way to make it.
    func forget(_ keys: some Sequence<Key>) {
        for key in keys {
            cache.removeObject(forKey: CacheKey(key))
        }
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
        guard !holdsLoads else { return }
        while running.count < Self.maxRunning, let key = waiting.popLast() {
            running.insert(key)
            didStartLoad?(key)
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
        didStore?(key)
        if let loaded {
            remember(loaded, for: key)
            arrived[key] = loaded
            scheduleNotify()
        }
        startWaiting()
    }

    private func remember(_ image: NSImage, for key: Key) {
        drawn[key] = WeakImage(image: image)
        guard drawn.count >= sweepDrawnAt else { return }
        drawn = drawn.filter { $0.value.image != nil }
        sweepDrawnAt = max(512, drawn.count * 2)
    }

    private func scheduleNotify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        Task {
            try? await Task.sleep(for: Self.notifyDelay)
            notifyScheduled = false
            let arrivals = arrived
            arrived = [:]
            NotificationCenter.default.post(
                name: Self.didLoadNotification,
                object: self,
                userInfo: [Self.arrivalsKey: arrivals]
            )
        }
    }

    /// Tell the panes to ask again, after the same short delay as an arrival, so a table has taken
    /// the new appearance by the time it is asked for its own.
    private func scheduleReask() {
        guard !reaskScheduled else { return }
        reaskScheduled = true
        Task {
            try? await Task.sleep(for: Self.notifyDelay)
            reaskScheduled = false
            NotificationCenter.default.post(name: Self.keysDidChangeNotification, object: self)
        }
    }

    /// The app's appearance changed, so every key the panes ask for is a new one: tell them to ask.
    /// Observed on first use rather than at init, so nothing here needs `NSApp` before it exists.
    private func observeAppearanceOnce() {
        guard appearanceObservation == nil else { return }
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { _, _ in
            MainActor.assumeIsolated { RowIconLoader.shared.scheduleReask() }
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

/// An image some row may still be drawing, not kept alive for it.
private struct WeakImage {
    weak var image: NSImage?
}

/// What a load gave, `nil` included: a file with no thumbnail is remembered as having none.
private final class Loaded {
    let image: NSImage?

    init(_ image: NSImage?) {
        self.image = image
    }
}
