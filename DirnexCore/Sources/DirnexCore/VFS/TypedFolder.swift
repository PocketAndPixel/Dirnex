import Foundation

/// The folder a path typed into a dialog's field names: Export's folder field (2026-11-18) and the
/// copy and move dialog's destination (2026-11-19), one parse so the two cannot drift.
///
/// The text names a folder on `base`'s backend, which is the other pane's. Empty text is `base`
/// itself. A path that does not start at a root is taken from `base`. `~` is this Mac's home on
/// this disk only: on a server it would name the wrong machine's home, so there it is a name like
/// any other.
///
/// **`.` and `..` are resolved by their spelling**, as a shell's `cd` does, where ``VFSPath``
/// leaves them to the backend. The copy dialog compares the typed folder with the ones it refuses,
/// the source's own folder and anything inside a marked folder, and `dest/..` would otherwise
/// pass as a folder that is neither. `..` at the root stays at the root.
public enum TypedFolder {
    public static func resolve(_ text: String, from base: VFSPath) -> VFSPath {
        var path = text.trimmingCharacters(in: .whitespaces)
        if path.isEmpty { return base }
        if base.backend == .local { path = (path as NSString).expandingTildeInPath }
        if !path.hasPrefix("/") { path = base.path + "/" + path }
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(component)
            }
        }
        return VFSPath(backend: base.backend, path: "/" + components.joined(separator: "/"))
    }
}
