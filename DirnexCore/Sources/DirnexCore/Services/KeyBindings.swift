import Foundation

/// A user's keyboard-shortcut customizations, layered over `CommandCatalog`'s defaults
/// (PLAN.md §M3 "rebindable shortcuts with conflict detection"). Headless and `Codable`: the
/// app persists it as JSON and consults `shortcut(for:)` when building the menu bar and the Cmd+K
/// palette, so a rebind is a data change the whole UI reflects without any AppKit rewiring.
///
/// There is one scheme, the catalog's — a macOS-flavored hybrid of ⌘-based editing and navigation
/// with Total Commander's F-keys for the file operations. It used to have a "Total Commander"
/// sibling, two overrides deep (F3 for Quick Look, ⇧F6 for Rename), removed on 2026-10-21 to free
/// ⇧F6 for the move beside ⇧F5's copy; a user who wants TC's own two keys rebinds them by hand.
///
/// Only *overrides* are stored — a command with no entry uses its catalog default — so the
/// serialized form stays small and a new default automatically reaches users who never touched
/// that command. The registry's secondary, Finder-style gestures wired directly in the table's
/// key model (e.g. ⌘⌫ for Trash) are an app concern outside this model, so conflict detection
/// covers only the registry's primary shortcuts.
public struct KeyBindings: Sendable, Equatable, Codable {
    /// One command's override. `.unbound` explicitly strips the shortcut (so a default can be
    /// removed, not just replaced); `.shortcut` rebinds it. Absent from `overrides` = the
    /// catalog default stands.
    public enum Binding: Sendable, Equatable, Codable {
        case shortcut(CommandShortcut)
        case unbound
    }

    /// Per-command overrides, keyed by `Command.id`. Kept private so every mutation routes
    /// through the methods that normalize away no-op overrides.
    public private(set) var overrides: [String: Binding]

    public init(overrides: [String: Binding] = [:]) {
        self.overrides = overrides
    }

    // MARK: - Resolution

    /// The effective shortcut for `id`: the user's override if present (a rebind, or `nil`
    /// when explicitly unbound), otherwise the command's catalog default.
    public func shortcut(for id: String) -> CommandShortcut? {
        if let override = overrides[id] {
            switch override {
            case let .shortcut(shortcut): return shortcut
            case .unbound: return nil
            }
        }
        return Self.defaultShortcut(for: id)
    }

    /// Whether `id`'s shortcut differs from its catalog default (i.e. the user changed it).
    /// Drives the Settings "revert to default" affordance.
    public func isCustomized(_ id: String) -> Bool {
        overrides[id] != nil
    }

    // MARK: - Mutation

    /// Rebind `id` to `shortcut`, or unbind it when `shortcut` is `nil`. If the new value
    /// equals the catalog default, the override is dropped instead of stored — so a binding
    /// that matches the default always reads as "not customized".
    public mutating func setShortcut(_ shortcut: CommandShortcut?, for id: String) {
        let fallback = Self.defaultShortcut(for: id)
        if shortcut == fallback {
            overrides[id] = nil
        } else if let shortcut {
            overrides[id] = .shortcut(shortcut)
        } else {
            overrides[id] = .unbound
        }
    }

    /// Drop `id`'s override so it reverts to the catalog default.
    public mutating func reset(_ id: String) {
        overrides[id] = nil
    }

    /// Clear every override, restoring the whole registry to its catalog defaults.
    public mutating func resetAll() {
        overrides.removeAll()
    }

    // MARK: - Conflicts

    /// The other command ids whose effective shortcut equals `id`'s — the collisions the
    /// Settings UI flags. Empty when `id` is unbound or its shortcut is unique.
    public func conflicts(for id: String) -> [String] {
        guard let target = shortcut(for: id) else { return [] }
        return CommandCatalog.all
            .map(\.id)
            .filter { $0 != id && shortcut(for: $0) == target }
    }

    /// Every shortcut bound to more than one command, mapped to those commands' ids in
    /// registry order — the complete conflict picture for a "warnings" summary. Empty when
    /// no shortcut collides.
    public func allConflicts() -> [CommandShortcut: [String]] {
        var byShortcut: [CommandShortcut: [String]] = [:]
        for command in CommandCatalog.all {
            guard let shortcut = shortcut(for: command.id) else { continue }
            byShortcut[shortcut, default: []].append(command.id)
        }
        return byShortcut.filter { $0.value.count > 1 }
    }

    /// Whether any two commands share a shortcut under these bindings.
    public var hasConflicts: Bool {
        !allConflicts().isEmpty
    }

    /// The catalog default shortcut for `id`, or `nil` when the command has none / is unknown.
    private static func defaultShortcut(for id: String) -> CommandShortcut? {
        CommandCatalog.command(for: id)?.shortcut
    }
}
