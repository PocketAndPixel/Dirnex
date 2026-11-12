import AppKit
import DirnexCore

/// The sidebar's Volumes section (PLAN.md §M1 "Volumes/places strip … replaces TC's drive letters"):
/// the mounted drives, external disks, and removable media, each with a capacity tooltip and — when
/// ejectable — an eject button. Split out of `SidebarViewController` so that file stays under its
/// length limit, the same reason Favorites, iCloud and Recents render from their own companions.
extension SidebarViewController {
    /// Build (or reuse) a volume cell: a drive symbol, a capacity tooltip, and — when the volume
    /// can eject — the eject button wired. `internal`, not `private`, because `viewFor` in the main
    /// file dispatches to it and Swift `private` doesn't cross files.
    func volumeCell(for volume: MountedVolume) -> NSView {
        let cell = reuse(SidebarCellView.identifier) as? SidebarCellView ?? SidebarCellView()
        let icon = Self.templateSymbol(volume.symbolName, pointSize: 15, describedAs: volume.name)
        let canEject = volume.canEject
        cell.configure(
            name: volume.name,
            image: icon,
            canEject: canEject,
            tooltip: capacityTooltip(volume)
        )
        cell.onEject = canEject ? { [weak self] in self?.eject(volume) } : nil
        return cell
    }

    /// A "123 GB available of 456 GB" tooltip for volumes that report capacity.
    private func capacityTooltip(_ volume: MountedVolume?) -> String? {
        guard let volume, let total = volume.totalCapacity, let available = volume.availableCapacity else {
            return volume?.name
        }
        return Self.capacityLine(available: available, total: total)
    }

    /// "123 GB available of 456 GB": a volume's whole tooltip, and the second line of a saved SFTP
    /// server's, whose numbers are the same `statvfs` fields (``SFTPDiskFree``). One call site for
    /// the string, so its one comment covers both (docs/NOTES.md ▸ Localization).
    static func capacityLine(available: Int64, total: Int64) -> String {
        String(
            localized: "\(FileFormatting.byteString(available)) available of \(FileFormatting.byteString(total))",
            comment: """
            Free space of a disk: a volume's sidebar tooltip, and the line under a saved SFTP server's \
            address. %1$@ is free space, %2$@ is total capacity.
            """
        )
    }

    /// Volumes whose Eject is still waiting for an answer, so a second click on one adds no second
    /// request, whose failure on a volume already gone would be an alert about nothing.
    private static var ejectsInFlight: Set<String> = []

    /// Eject (or unmount) a removable volume via the workspace, surfacing any failure —
    /// a drive that's busy or in use should say so, not fail silently.
    ///
    /// The call runs off the main thread. An unmount first waits for every process that registered
    /// to approve one, so one that never answers freezes a main thread waiting on it for
    /// DiskArbitration's whole timeout: 10.7 s on 2026-11-02 (docs/NOTES.md ▸ SMB). It is the same
    /// call, so it ejects and fails as it did. Off the main thread it was probed against a disk
    /// image, clean and busy, with the Main Thread Checker loaded, which reported nothing.
    private func eject(_ volume: MountedVolume) {
        let url = volume.path.localURL
        guard Self.ejectsInFlight.insert(url.path).inserted else { return }
        Task { @MainActor in
            let failure = await BlockingWork.run { () -> String? in
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
            Self.ejectsInFlight.remove(url.path)
            if let failure { presentEjectFailure(of: volume, reason: failure) }
        }
    }

    private func presentEjectFailure(of volume: MountedVolume, reason: String) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Couldn’t eject “\(volume.name)”",
            comment: "Eject-failure alert title; %@ is the volume's name."
        )
        alert.informativeText = reason
        alert.alertStyle = .warning
        alert.enableEscapeToCancel() // ⎋ → OK; the only button, so it dismisses either way.
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
