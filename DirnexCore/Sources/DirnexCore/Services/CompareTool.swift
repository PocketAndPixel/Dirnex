import Foundation

/// What Compare By Contents opens two files in: Dirnex's own compare window, or an external diff
/// tool (PLAN.md §M31 Slice 4).
///
/// Dirnex's window is always there, so it is the default and the fallback: an external tool is used
/// only while it is the user's choice in Settings and still installed.
public enum CompareTool: Sendable, Hashable, Identifiable {
    /// Dirnex's own read-only, side-by-side compare window.
    case dirnex
    /// An external diff tool, installed.
    case external(ExternalDiffTool)

    /// The identifier Settings saves for Dirnex's own window. It shares the space of
    /// `ExternalDiffTool.identifier`, which none of the known tools uses.
    public static let dirnexIdentifier = "dirnex"

    public var id: String { identifier }

    public var identifier: String {
        switch self {
        case .dirnex: Self.dirnexIdentifier
        case let .external(tool): tool.identifier
        }
    }

    /// The choices Settings offers: Dirnex first, then every installed tool in
    /// `ExternalDiffTool.known`'s order.
    public static func choices(installed: [ExternalDiffTool]) -> [CompareTool] {
        [.dirnex] + installed.map { .external($0) }
    }

    /// The tool to compare with: the user's Settings choice while it is installed, else Dirnex.
    ///
    /// A chosen tool that has since been uninstalled falls back to Dirnex rather than failing, and
    /// the stale choice is left alone, so reinstalling the tool restores it without a visit to
    /// Settings.
    public static func preferred(identifier: String, installed: [ExternalDiffTool]) -> CompareTool {
        installed.first { $0.identifier == identifier }.map { .external($0) } ?? .dirnex
    }

    /// The choice Settings shows, from what it saved: the saved tool, or Dirnex when nothing was
    /// saved.
    ///
    /// Settings offered **Automatic** until 2026-10-22, saved as the empty string, which opened the
    /// first installed tool. It was the default, and Dirnex is the default now, so a saved Automatic
    /// is Dirnex too: an external tool is used only when it was picked by name.
    public static func identifier(saved: String?) -> String {
        guard let saved, !saved.isEmpty else { return dirnexIdentifier }
        return saved
    }
}
