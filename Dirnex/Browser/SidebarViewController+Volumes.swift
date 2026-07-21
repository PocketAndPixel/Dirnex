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
        return "\(FileFormatting.byteString(available)) available of \(FileFormatting.byteString(total))"
    }

    /// Eject (or unmount) a removable volume via the workspace, surfacing any failure —
    /// a drive that's busy or in use should say so, not fail silently.
    private func eject(_ volume: MountedVolume) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.path.localURL)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t eject “\(volume.name)”"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            if let window = view.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }
}
