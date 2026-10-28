import Foundation

/// The environment every `bsdtar` child runs under: ``ChildProcessLocale``'s pinned locale, and a
/// `PATH` that reaches `zstd`.
///
/// `bsdtar` runs `zstd` itself to read or write a `.tar.zst`, looked up in its own `PATH`, and a
/// Dock-launched Dirnex has none that holds it (``ZstdTool``). The directory ``ZstdTool/locate()``
/// found is appended, so the argv every listing, extraction, pack and rewrite sends is unchanged.
public enum BsdtarEnvironment {
    /// This process's environment, ready for a `bsdtar` child.
    public static func inherited() -> [String: String] {
        make(from: ProcessInfo.processInfo.environment, zstd: ZstdTool.locate())
    }

    /// `environment` with the locale pinned and `zstd`'s directory on `PATH`. A `nil` `zstd`
    /// leaves `PATH` as it was.
    public static func make(from environment: [String: String], zstd: String?) -> [String: String] {
        var child = ChildProcessLocale.pinningLocale(environment)
        child["PATH"] = ZstdTool.childPath(environment["PATH"], zstd: zstd)
        return child
    }
}
