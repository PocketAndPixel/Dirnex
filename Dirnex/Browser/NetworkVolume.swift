import DirnexCore
import Foundation

/// The mounted network share a local path is on, if it is on one.
///
/// `volumeIsLocal` is `false` for a mounted share and `true` for a disk — measured 2026-09-20 on a
/// live Synology share and this Mac's own disk in the same run. Two unrelated questions need that
/// one fact: whether a share's recycle bin catches a delete
/// (``PanelViewController/shareRecycleBinGoverning(_:)``), and whose refusal a `permissionDenied`
/// was (``VFSErrorText``), since a server's answer cannot be changed in System Settings.
enum NetworkVolume {
    /// The mount point of the **network** volume `path` is on, or `nil` for anything else —
    /// including a path on a connected server, which is not on any volume of this Mac however its
    /// spelling happens to collide with one.
    ///
    /// `resourceValues` is bound before either key is read: `try?` on the whole expression would
    /// flatten "the read threw" into "the key is absent" (docs/NOTES.md), and here those must both
    /// land on the same answer, "not a share", for the same reason rather than by luck.
    static func root(of path: VFSPath) -> VFSPath? {
        guard path.backend == .local else { return nil }
        let url = URL(fileURLWithPath: path.path)
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeIsLocalKey]),
              values.volumeIsLocal == false,
              let volume = values.volume
        else {
            return nil
        }
        return .local(volume.path)
    }
}
