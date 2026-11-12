import AppKit
import DirnexCore

/// The line under the dragged row: how the bytes are coming, and over an app that may want a folder
/// zipped, how to get the zip (2026-11-09). On the drag image because that is the one thing still in
/// front of somebody holding a drag over another app (`RemoteDragStatus`).
extension RemoteDragHandoffController {
    /// Keep the drag image's status current for as long as the transfer runs. Polled, for the reason
    /// `RemoteFetchPrompt` polls: a transfer reports far more often than anybody can read.
    func followProgress(ofBytes sizes: [Int64]) {
        progressTotal = sizes.allSatisfy { $0 >= 0 } ? sizes.reduce(0, +) : nil
        statusTask = Task { [weak self] in
            while !Task.isCancelled, let self, handoff.transfer == .running {
                drawStatus()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func drawStatus() {
        guard isDragging else { return }
        showStatus(statusLine)
    }

    /// What the line says now, about the work the board's current form needs.
    var statusLine: String? {
        switch handoff.progress {
        case .notStarted:
            return shiftHint
        case .running:
            // The zips are made after the transfer, so a transfer still running is what is under way.
            guard handoff.transfer == .running else { return RemoteDragStatus.compressing }
            switch phase.value {
            case .extracting: return RemoteDragStatus.extracting
            case .downloading:
                return RemoteDragStatus.downloading(moved: moved.value, of: progressTotal)
            }
        case .landed:
            // Worth saying to an app that was already told there was nothing, because it will not look
            // again until the pointer leaves it and comes back.
            return handoff.needsReentry ? RemoteDragStatus.ready : shiftHint
        case .failed:
            guard handoff.transfer == .failed else { return RemoteDragStatus.compressionFailed }
            switch phase.value {
            case .extracting: return RemoteDragStatus.extractionFailed
            case .downloading: return RemoteDragStatus.failed
            }
        }
    }

    /// Over any app, Finder included, for a drag holding a folder: what ⇧ gives. It counts as the
    /// pointer enters, because that is what Teams and Chrome drop, so a key changed since the entry
    /// asks for the pointer to leave and come back. Nothing over Dirnex itself, which reads its own
    /// payload.
    private var shiftHint: String? {
        guard offer.holdsFolders, lastSurface != .neutral else { return nil }
        let offersZip = handoff.form == .zips
        guard shiftHeld() == offersZip else { return RemoteDragStatus.moveOutAndBackIn }
        return offersZip ? RemoteDragStatus.asZip : RemoteDragStatus.holdShiftAndReenter
    }
}
