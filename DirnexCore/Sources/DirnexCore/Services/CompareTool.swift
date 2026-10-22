import Foundation

/// What Compare By Contents opens two files in: Dirnex's own compare window, or an external diff
/// tool (PLAN.md §M31 Slice 4).
///
/// Dirnex's window is always there, so there is always an answer: a Mac with none of the external
/// tools compares in Dirnex rather than reporting that nothing is installed. It is the automatic
/// choice only when no external tool is installed, so a user who already has Kaleidoscope, BBEdit
/// or Xcode keeps the tool ⌥F3 opened before; anyone can pick Dirnex in Settings.
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

    /// The name Settings shows. Every one is a product name, the same in every language.
    public var displayName: String {
        switch self {
        case .dirnex: "Dirnex"
        case let .external(tool): tool.displayName
        }
    }

    /// The choices Settings offers besides Automatic: Dirnex first, then every installed tool in
    /// the automatic order.
    public static func choices(installed: [ExternalDiffTool]) -> [CompareTool] {
        [.dirnex] + installed.map { .external($0) }
    }

    /// The tool to compare with.
    ///
    /// - Parameters:
    ///   - preferredIdentifier: the user's Settings choice, or `nil`/empty for **automatic**.
    ///   - installed: the installed external tools, in the automatic order.
    ///
    /// A chosen tool that has since been uninstalled falls through to automatic rather than
    /// failing, and the stale preference is left alone, so reinstalling the tool restores the
    /// choice without a visit to Settings. Automatic is the first installed tool, else Dirnex.
    public static func preferred(
        identifier preferredIdentifier: String?,
        installed: [ExternalDiffTool]
    ) -> CompareTool {
        if preferredIdentifier == dirnexIdentifier { return .dirnex }
        if let preferredIdentifier,
           let match = installed.first(where: { $0.identifier == preferredIdentifier }) {
            return .external(match)
        }
        return installed.first.map { .external($0) } ?? .dirnex
    }
}
