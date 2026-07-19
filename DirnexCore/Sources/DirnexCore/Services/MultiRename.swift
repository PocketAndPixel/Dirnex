import Foundation

// Total Commander's Multi-Rename Tool, headless (PLAN.md §M4 "Multi-rename tool: pattern
// tokens ([N] name, [C] counter, [E] ext, date tokens), regex find/replace, case transforms,
// live preview table, applies as one undoable batch").
//
// This is the pure *planning* half: given a set of items and a `RenameSpec`, it produces one
// `RenameProposal` per item — the old→new mapping the preview table renders and the app
// applies as a single batch. It touches no disk (so it stays unit-testable without a
// filesystem); the app performs the actual moves through the `VFSBackend` primitive and
// journals them for undo (`UndoRecord.multiRename`).
//
// The mapping is deterministic in list order — the `[C]` counter advances one step per item —
// so the app hands items in the panel's current display order and the preview is stable.

// MARK: - Spec

/// Case folding applied to the whole resulting filename (extension included).
public enum RenameCase: String, Sendable, Equatable, CaseIterable {
    case asIs
    case lower
    case upper
    case capitalized

    func apply(_ text: String) -> String {
        switch self {
        case .asIs: return text
        case .lower: return text.lowercased()
        case .upper: return text.uppercased()
        case .capitalized: return text.capitalized
        }
    }
}

/// The `[C]` counter: an incrementing number, one step per item in list order, zero-padded to
/// a minimum width. `start`/`step`/`padding` are TC's three counter knobs.
public struct RenameCounter: Sendable, Equatable {
    public var start: Int
    public var step: Int
    /// Minimum number of digits, zero-padded (`1` = no leading zeros; a longer number is never
    /// truncated). Clamped to at least 1.
    public var padding: Int

    public init(start: Int = 1, step: Int = 1, padding: Int = 1) {
        self.start = start
        self.step = step
        self.padding = max(1, padding)
    }

    func value(at index: Int) -> Int { start + index * step }

    /// The counter text for the item at `index`, sign-aware so a negative start pads its
    /// digits, not the minus (`-5` at width 3 → `-005`).
    func formatted(at index: Int) -> String {
        let raw = value(at: index)
        let sign = raw < 0 ? "-" : ""
        var digits = String(abs(raw))
        if digits.count < padding {
            digits = String(repeating: "0", count: padding - digits.count) + digits
        }
        return sign + digits
    }
}

/// The full recipe for a batch rename — the state the tool's controls edit. Its defaults
/// (`[N]` / `[E]`, no find/replace, as-is case, counter from 1) reproduce the original names,
/// so an untouched tool is a no-op preview until the user changes something.
public struct RenameSpec: Sendable, Equatable {
    /// Template for the name part, before the extension. Default `[N]` = original base name.
    public var nameTemplate: String
    /// Template for the extension part, without the dot. Default `[E]` = original extension.
    /// When it renders empty, the result has no extension (and no trailing dot).
    public var extensionTemplate: String
    /// Search text applied to the combined name after token substitution; empty disables
    /// find/replace. Literal by default, a regular expression when `useRegex` is set.
    public var find: String
    /// Replacement for `find`. With `useRegex`, supports `$1`-style capture references.
    public var replace: String
    public var useRegex: Bool
    public var caseTransform: RenameCase
    public var counter: RenameCounter

    public init(
        nameTemplate: String = "[N]",
        extensionTemplate: String = "[E]",
        find: String = "",
        replace: String = "",
        useRegex: Bool = false,
        caseTransform: RenameCase = .asIs,
        counter: RenameCounter = RenameCounter()
    ) {
        self.nameTemplate = nameTemplate
        self.extensionTemplate = extensionTemplate
        self.find = find
        self.replace = replace
        self.useRegex = useRegex
        self.caseTransform = caseTransform
        self.counter = counter
    }

    /// The identity spec — reproduces every input name unchanged.
    public static let identity = RenameSpec()

    /// Whether the regex `find` pattern compiles. Always `true` when not using a regex or the
    /// pattern is empty, so the tool can surface a red "invalid pattern" hint without special-
    /// casing the common literal path.
    public var regexIsValid: Bool {
        guard useRegex, !find.isEmpty else { return true }
        return (try? NSRegularExpression(pattern: find)) != nil
    }
}

// MARK: - Proposal

/// One item's disposition in a rename batch — what the preview table colors and the app filters
/// on before applying.
public enum RenameStatus: Sendable, Equatable {
    /// The new name equals the original — nothing to do; skipped on apply.
    case unchanged
    /// A valid, non-colliding change that will be applied.
    case rename
    /// The template rendered an empty name.
    case emptyName
    /// The new name contains a path separator ("/"), which a filename can't.
    case invalidCharacter
    /// Two items in the batch produced the same new name — they'd clash with each other.
    case duplicate
    /// The new name lands on a file already in the directory that isn't part of the batch —
    /// applying would clobber a bystander, so it's blocked.
    case collision

    /// A problem that blocks the whole batch (as opposed to a clean rename or a skip).
    public var isProblem: Bool {
        switch self {
        case .unchanged, .rename: return false
        case .emptyName, .invalidCharacter, .duplicate, .collision: return true
        }
    }
}

/// One row of the rename plan: an item, its current name, the proposed name, and whether that
/// name is applyable. Identity is the source path, so a SwiftUI/AppKit list can diff rows.
public struct RenameProposal: Sendable, Equatable, Identifiable {
    public let source: VFSPath
    public let originalName: String
    public let newName: String
    public let status: RenameStatus

    public init(source: VFSPath, originalName: String, newName: String, status: RenameStatus) {
        self.source = source
        self.originalName = originalName
        self.newName = newName
        self.status = status
    }

    public var id: VFSPath { source }

    /// A clean, applyable change.
    public var willRename: Bool { status == .rename }
}

// MARK: - Engine

public enum MultiRename {
    /// Plan a batch rename of `items` under `spec`. `existingNames` is every name currently in
    /// the destination directory (including the items themselves), used to flag names that
    /// would clobber a bystander. The `[C]` counter follows the order of `items`.
    ///
    /// Collision rules keep the batch always-safe and always cleanly undoable: a new name may
    /// only equal its own item's original (a pure case change) — never another existing file,
    /// including another batch member's original (a swap/chain), which is reported as a
    /// `.collision` rather than applied through fragile temp-name juggling.
    public static func plan(
        for items: [FileEntry],
        spec: RenameSpec,
        existingNames: Set<String>
    ) -> [RenameProposal] {
        let regex = spec.useRegex && !spec.find.isEmpty
            ? try? NSRegularExpression(pattern: spec.find)
            : nil

        let proposed = items.enumerated().map { index, entry in
            (entry: entry, newName: newName(for: entry, index: index, spec: spec, regex: regex))
        }

        // Case-insensitive to match the default APFS volume: two names differing only in case
        // still collide on disk.
        let existingLower = Set(existingNames.map { $0.lowercased() })
        var targetCounts: [String: Int] = [:]
        for item in proposed {
            targetCounts[item.newName.lowercased(), default: 0] += 1
        }

        return proposed.map { entry, newName in
            RenameProposal(
                source: entry.path,
                originalName: entry.name,
                newName: newName,
                status: status(
                    original: entry.name,
                    newName: newName,
                    existingLower: existingLower,
                    targetCounts: targetCounts
                )
            )
        }
    }

    private static func status(
        original: String,
        newName: String,
        existingLower: Set<String>,
        targetCounts: [String: Int]
    ) -> RenameStatus {
        if newName.isEmpty { return .emptyName }
        if newName.contains("/") { return .invalidCharacter }
        // A case-sensitive comparison: a case-only change ("Photo" → "photo") is a real rename.
        if newName == original { return .unchanged }

        let lower = newName.lowercased()
        if (targetCounts[lower] ?? 0) > 1 { return .duplicate }
        // Landing on any existing file other than this item itself would clobber a bystander.
        if lower != original.lowercased(), existingLower.contains(lower) { return .collision }
        return .rename
    }

    // MARK: - Name building

    private static func newName(
        for entry: FileEntry,
        index: Int,
        spec: RenameSpec,
        regex: NSRegularExpression?
    ) -> String {
        let counter = spec.counter.formatted(at: index)
        let namePart = substitute(spec.nameTemplate, entry: entry, counter: counter)
        let extPart = substitute(spec.extensionTemplate, entry: entry, counter: counter)
        var combined = extPart.isEmpty ? namePart : namePart + "." + extPart
        combined = findReplace(combined, spec: spec, regex: regex)
        return spec.caseTransform.apply(combined)
    }

    /// Replace `[X]` tokens in `template` in a single left-to-right scan, so a token's *value*
    /// (a filename that happens to contain "[C]") is never re-substituted. Unknown or malformed
    /// brackets pass through literally.
    private static func substitute(_ template: String, entry: FileEntry, counter: String) -> String {
        guard template.contains("[") else { return template }
        let tokens = tokenValues(for: entry, counter: counter)
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "[",
               let (value, next) = matchToken(in: template, after: index, tokens: tokens) {
                result += value
                index = next
            } else {
                result.append(template[index])
                index = template.index(after: index)
            }
        }
        return result
    }

    /// If `template` has a known single-letter token `[X]` starting at the "[" at `open`, return
    /// its value and the index just past the "]". All tokens are one letter, so this is a fixed
    /// three-character lookahead.
    private static func matchToken(
        in template: String,
        after open: String.Index,
        tokens: [Character: String]
    ) -> (value: String, next: String.Index)? {
        let letterIndex = template.index(after: open)
        guard letterIndex < template.endIndex else { return nil }
        let closeIndex = template.index(after: letterIndex)
        guard closeIndex < template.endIndex, template[closeIndex] == "]",
              let value = tokens[template[letterIndex]] else { return nil }
        return (value, template.index(after: closeIndex))
    }

    /// The substitution table for one item: name/extension/counter plus date-from-modification
    /// tokens, in the user's local calendar (the file's date as they see it in the panel).
    private static func tokenValues(for entry: FileEntry, counter: String) -> [Character: String] {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: entry.modificationDate
        )
        func pad(_ value: Int?, _ width: Int) -> String {
            String(format: "%0\(width)d", value ?? 0)
        }
        return [
            "N": entry.baseName,
            "E": entry.fileExtension,
            "C": counter,
            "Y": pad(components.year, 4),
            "M": pad(components.month, 2),
            "D": pad(components.day, 2),
            "h": pad(components.hour, 2),
            "n": pad(components.minute, 2),
            "s": pad(components.second, 2)
        ]
    }

    private static func findReplace(
        _ input: String,
        spec: RenameSpec,
        regex: NSRegularExpression?
    ) -> String {
        guard !spec.find.isEmpty else { return input }
        if spec.useRegex {
            // An invalid pattern (`regex == nil`) leaves the name untouched — the tool flags it
            // via `RenameSpec.regexIsValid` rather than mangling every row.
            guard let regex else { return input }
            let range = NSRange(input.startIndex..., in: input)
            return regex.stringByReplacingMatches(
                in: input,
                range: range,
                withTemplate: spec.replace
            )
        }
        return input.replacingOccurrences(of: spec.find, with: spec.replace)
    }
}
