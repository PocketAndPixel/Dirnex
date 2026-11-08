import AppKit
import DirnexCore

/// What a drag's transfer ended with, handed from its own thread to the main actor.
///
/// A box rather than an `await`, because whoever wants it may be holding the main thread.
final class RemoteDragTransferOutcome: @unchecked Sendable {
    struct Settled {
        let landed: [MaterializedFile]
        /// Members extracted out of an archive, which no cache adopts: `ArchivePreviewCache` keeps
        /// what it extracted itself, and these sit in the extractor's temp root until next launch.
        let extracted: [VFSPath: URL]
        /// Folders made into zips, with a server folder's staged tree beside its zip (`DragOutZip`).
        let zipped: [DragOutZip.Made]
        let error: (any Error)?
    }

    private let lock = NSLock()
    private var value: Settled?

    var settled: Settled? {
        lock.withLock { value }
    }

    var isSettled: Bool {
        settled != nil
    }

    func settle(_ settled: Settled) {
        lock.withLock { value = settled }
    }
}

/// What the transfer is doing now, written by its thread and read when the status is drawn.
final class RemoteDragPhaseBox: @unchecked Sendable {
    enum Phase: Sendable {
        case downloading
        case extracting
        case compressing
    }

    private let lock = NSLock()
    private var current: Phase

    init(_ phase: Phase) {
        current = phase
    }

    var value: Phase {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// What one drag offers other apps, gathered on the main actor when it begins (PLAN.md §M36).
///
/// The controller used to work this out for itself from each row's backend, which knew only servers.
/// The pane knows the rest: which archives are locked this session, what a member's extraction needs,
/// and which copies its window already holds, in either cache.
struct DragOutOffer {
    /// The route each row takes, by path (`DragOutRoute`).
    let routes: [VFSPath: DragOutRoute]
    /// What extracting each `.extract` row needs, by path.
    let extractions: [VFSPath: DragOutExtraction]
    /// A copy of the row already on this disk, from a preview, an open or an earlier drag.
    let alreadyHere: @MainActor (FileEntry) -> URL?
    /// Called once, the first time the pointer is over another app, when a row is a member of a
    /// locked archive (decision A): that row goes nowhere outside Dirnex, and the user is told why.
    let onLockedRowsLeaving: @MainActor () -> Void

    /// Whether any row stays behind because its archive is locked.
    var holdsLockedRows: Bool {
        routes.values.contains(.insideDirnexOnly(.lockedArchive))
    }

    /// Whether Finder is offered something other than every other app is: a folder, which is itself
    /// for Finder and a zip for the rest (`RemoteDragHandoff.init(finderHasItsOwnBoard:)`).
    var finderHasItsOwnBoard: Bool {
        routes.values.contains(where: \.zipsForOtherApps)
    }

    /// What a drag offered before archive members could go out: every file on a server, from the
    /// cache it would land in. The default for a caller that names no offer.
    static func serverFilesOnly(_ entries: [FileEntry], cache: RemoteFileCache) -> DragOutOffer {
        var routes: [VFSPath: DragOutRoute] = [:]
        for entry in entries where entry.path.backend.archivePath == nil {
            routes[entry.path] = DragOutRoute.route(for: entry) { _ in true }
        }
        return DragOutOffer(
            routes: routes,
            extractions: [:],
            alreadyHere: { cache.cachedURL(for: $0) },
            onLockedRowsLeaving: {}
        )
    }
}

/// What is under the pointer during a real drag.
@MainActor
enum RemoteDragPointer {
    /// Asked through the window server, since the answer is about other apps' windows and the drag's
    /// own image is not one it reports. About 0.3 ms when measured, which a drag's moves can afford.
    static func surface() -> RemoteDragHandoff.Surface {
        let number = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        guard number > 0,
              let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number))
              as? [[String: Any]],
              let processID = info.first?[kCGWindowOwnerPID as String] as? pid_t else {
            return .neutral
        }
        let app = NSRunningApplication(processIdentifier: processID)
        return .classify(
            processID: processID,
            bundleIdentifier: app?.bundleIdentifier,
            isRegularApp: app?.activationPolicy == .regular,
            ownProcessID: ProcessInfo.processInfo.processIdentifier
        )
    }
}
