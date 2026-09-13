import DirnexCore
import Foundation
import Photos

/// The app's PhotoKit adapter beneath `PhotosBackend` (PLAN.md §M28 Slice 2): the four things the
/// core asks of the system Photos library, answered through the only public route to it.
///
/// It lives in the app for the reason every other transport does: PhotoKit is I/O against a system
/// daemon behind a privacy grant, which no test can stand up, while every rule above it belongs to
/// the core and is tested there against a fake. What is here is the part the probe measured
/// (docs/NOTES.md ▸ iCloud Photos).
///
/// - **It never asks for access.** Every method reads the authorization status and throws
///   ``PhotosLibraryError/notAuthorized`` when access is not granted. The one place that raises the
///   system prompt is the sidebar click (`PanelViewController.showPhotosLibrary`), so a restored tab,
///   a refresh or a search never puts a privacy dialog in front of somebody who did not ask.
/// - **It blocks.** Like the other transports it waits for PhotoKit's callbacks on a semaphore, so it
///   is only ever called off the main thread — listings and copies already run there.
struct PhotoKitLibrary: PhotosLibraryTransport {
    // MARK: - Listing

    func assets(capturedIn interval: DateInterval?) throws -> [PhotosAsset] {
        try Self.requireAccess()
        let options = Self.libraryOptions()
        if let interval {
            options.predicate = NSPredicate(
                format: "creationDate >= %@ AND creationDate < %@",
                interval.start as NSDate,
                interval.end as NSDate
            )
        }
        let fetched = PHAsset.fetchAssets(with: options)
        var assets: [PhotosAsset] = []
        assets.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in
            assets.append(
                PhotosAsset(identifier: asset.localIdentifier, captureDate: asset.creationDate)
            )
        }
        return assets
    }

    func resources(ofAssets identifiers: [String]) throws -> [String: [PhotosResource]] {
        try Self.requireAccess()
        let fetched = PHAsset.fetchAssets(
            withLocalIdentifiers: identifiers,
            options: Self.libraryOptions()
        )
        var answer: [String: [PhotosResource]] = [:]
        fetched.enumerateObjects { asset, _, _ in
            answer[asset.localIdentifier] = PHAssetResource.assetResources(for: asset).map(
                Self.describe
            )
        }
        return answer
    }

    func changeToken() -> Data? {
        guard Self.hasAccess else { return nil }
        let token = PHPhotoLibrary.shared().currentChangeToken
        return try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    // MARK: - Export

    func export(
        _ resource: PhotosResource,
        ofAsset identifier: String,
        toLocalPath localPath: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        try Self.requireAccess()
        if isCancelled() { throw CancellationError() }
        guard let original = Self.original(matching: resource, ofAsset: identifier) else {
            throw PhotosLibraryError.itemGone
        }

        let destination = URL(fileURLWithPath: localPath)
        // With the network off first. An original that is on this Mac comes back as an APFS clone of
        // the library's own file (2.66 GB in 0.70 ms, measured 2026-09-13), and one that is only in
        // iCloud is refused in milliseconds with `networkAccessRequired`, leaving nothing behind.
        if let refusal = Self.writeLocally(original, to: destination) {
            guard Self.isNetworkRequired(refusal) else { throw Self.libraryError(for: refusal) }
            try Self.download(
                original,
                to: destination,
                progress: progress,
                isCancelled: isCancelled
            )
            return
        }
        progress(Self.sizeOfFile(at: localPath))
    }

    /// Stream an original down from iCloud into `destination`.
    ///
    /// `requestData` rather than a networked `writeData`, because only the streaming form hands back
    /// something to cancel: Stop reached the request **0.61 ms** after it was asked for, with no chunk
    /// after it (measured 2026-09-13). The callbacks cannot call the caller's non-escaping `progress`
    /// and `isCancelled`, so the waiting thread polls both between slices, the shape
    /// `ProcessWaiting` has for a subprocess.
    private static func download(
        _ resource: PHAssetResource,
        to destination: URL,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destination)
        else { throw PhotosLibraryError.failed(code: Int(EIO)) }

        let stream = PhotoKitStream(writingTo: handle)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let manager = PHAssetResourceManager.default()
        let request = manager.requestData(
            for: resource,
            options: options,
            dataReceivedHandler: { data in stream.append(data) },
            completionHandler: { error in stream.finish(error) }
        )

        var reported: Int64 = 0
        var stopped = false
        while !stream.waitForCompletion(seconds: 0.1) {
            reported = stream.report(since: reported, to: progress)
            if !stopped, isCancelled() || stream.writeFailure != nil {
                stopped = true
                manager.cancelDataRequest(request)
            }
        }
        _ = stream.report(since: reported, to: progress)
        try? handle.close()

        let writeFailure = stream.writeFailure
        let requestFailure = stream.requestFailure
        guard stopped || writeFailure != nil || requestFailure != nil else { return }
        // A partial original is worse than none: it opens, and it is the wrong picture.
        try? FileManager.default.removeItem(at: destination)
        if let writeFailure { throw PhotosLibraryError.failed(code: (writeFailure as NSError).code) }
        if stopped { throw CancellationError() }
        if let requestFailure { throw libraryError(for: requestFailure) }
    }

    private static func writeLocally(_ resource: PHAssetResource, to destination: URL) -> (any Error)? {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let outcome = PhotoKitOutcome()
        PHAssetResourceManager.default().writeData(
            for: resource,
            toFile: destination,
            options: options
        ) { error in
            outcome.finish(error)
        }
        outcome.wait()
        return outcome.error
    }

    // MARK: - Mapping

    /// The library as its own Library view shows it: hidden assets out, a burst represented by its
    /// pick, shared albums and the Shared Library left out. One definition for every method, so a
    /// listing and the export that follows it cannot disagree about which assets exist.
    private static func libraryOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        options.includeAssetSourceTypes = [.typeUserLibrary]
        return options
    }

    /// Whether the library may be read — `.limited` included, which macOS reports as a full grant.
    static var hasAccess: Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: true
        default: false
        }
    }

    private static func requireAccess() throws {
        guard hasAccess else { throw PhotosLibraryError.notAuthorized }
    }

    private static func original(matching resource: PhotosResource, ofAsset identifier: String) -> PHAssetResource? {
        let fetched = PHAsset.fetchAssets(
            withLocalIdentifiers: [identifier],
            options: libraryOptions()
        )
        guard let asset = fetched.firstObject else { return nil }
        return PHAssetResource.assetResources(for: asset).first { describe($0) == resource }
    }

    private static func describe(_ resource: PHAssetResource) -> PhotosResource {
        PhotosResource(
            kind: kind(of: resource.type),
            originalFilename: resource.originalFilename,
            byteSize: byteSize(of: resource)
        )
    }

    /// PhotoKit's resource type in the core's vocabulary. Anything not an original keeps its raw
    /// value, including the undocumented type 16 an edited photo carries.
    static func kind(of type: PHAssetResourceType) -> PhotosResourceKind {
        switch type {
        case .photo: .photo
        case .video: .video
        case .audio: .audio
        case .alternatePhoto: .alternatePhoto
        case .pairedVideo: .pairedVideo
        default: .derived(rawValue: type.rawValue)
        }
    }

    /// The resource's size. `fileSize` is a key-value coding key rather than API, and it is the only
    /// source there is; guarded, so a macOS that drops it gives rows with no size rather than a crash.
    private static func byteSize(of resource: PHAssetResource) -> Int64? {
        guard resource.responds(to: NSSelectorFromString("fileSize")) else { return nil }
        return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
    }

    private static func isNetworkRequired(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == PHPhotosErrorDomain
            && error.code == PHPhotosError.Code.networkAccessRequired.rawValue
    }

    private static func libraryError(for error: any Error) -> any Error {
        let error = error as NSError
        guard error.domain == PHPhotosErrorDomain else { return PhotosLibraryError.failed(
            code: error.code
        ) }
        switch PHPhotosError.Code(rawValue: error.code) {
        case .userCancelled?: return CancellationError()
        case .accessRestricted?, .accessUserDenied?: return PhotosLibraryError.notAuthorized
        case .identifierNotFound?, .missingResource?, .invalidResource?: return PhotosLibraryError.itemGone
        default: return PhotosLibraryError.failed(code: error.code)
        }
    }

    private static func sizeOfFile(at path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// A PhotoKit completion handed back to the thread that is waiting for it.
private final class PhotoKitOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var stored: (any Error)?

    func finish(_ error: (any Error)?) {
        lock.withLock { stored = error }
        done.signal()
    }

    func wait() {
        done.wait()
    }

    var error: (any Error)? {
        lock.withLock { stored }
    }
}

/// One streamed download's shared state: written by PhotoKit's callbacks, read by the waiting thread.
private final class PhotoKitStream: @unchecked Sendable {
    private let lock = NSLock()
    private let completed = DispatchSemaphore(value: 0)
    private let handle: FileHandle
    private var written: Int64 = 0
    private var writeError: (any Error)?
    private var completionError: (any Error)?

    init(writingTo handle: FileHandle) {
        self.handle = handle
    }

    func append(_ data: Data) {
        lock.withLock {
            guard writeError == nil else { return }
            do {
                try handle.write(contentsOf: data)
                written += Int64(data.count)
            } catch {
                writeError = error
            }
        }
    }

    func finish(_ error: (any Error)?) {
        lock.withLock { completionError = error }
        completed.signal()
    }

    func waitForCompletion(seconds: Double) -> Bool {
        completed.wait(timeout: .now() + seconds) == .success
    }

    /// Report what has arrived since `reported`, returning the new total.
    func report(since reported: Int64, to progress: (Int64) -> Void) -> Int64 {
        let current = lock.withLock { written }
        guard current > reported else { return reported }
        progress(current - reported)
        return current
    }

    var writeFailure: (any Error)? {
        lock.withLock { writeError }
    }

    var requestFailure: (any Error)? {
        lock.withLock { completionError }
    }
}
