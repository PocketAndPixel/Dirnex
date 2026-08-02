import Foundation
import Testing

@testable import DirnexCore

@Suite("FileColorRule")
struct FileColorRuleTests {
    private func rule(
        _ patterns: [String],
        color: String = "#008080",
        target: FileColorTarget = .any
    ) -> FileColorRule {
        FileColorRule(patterns: patterns, colorHex: color, target: target)
    }

    // MARK: - Matching

    @Test("a pattern matches by name, case-insensitively, like +/- pattern select")
    func matchesIgnoringCase() {
        let images = rule(["*.jpg"])
        #expect(images.matches(name: "holiday.jpg"))
        #expect(images.matches(name: "HOLIDAY.JPG"))
        #expect(images.matches(name: "Holiday.Jpg"))
        #expect(!images.matches(name: "holiday.jpeg"))
    }

    @Test("any pattern in the rule is enough — one colour, several extensions")
    func matchesAnyPattern() {
        let images = rule(["*.jpg", "*.png", "*.gif"])
        #expect(images.matches(name: "a.jpg"))
        #expect(images.matches(name: "b.png"))
        #expect(images.matches(name: "c.gif"))
        #expect(!images.matches(name: "d.tiff"))
    }

    @Test("a rule with no patterns matches nothing — the shape a half-written rule has")
    func emptyRuleMatchesNothing() {
        #expect(!rule([]).matches(name: "anything.txt"))
        #expect(!rule([]).matches(name: ""))
    }

    /// Probed against the real `fnmatch` before this was written: it answers its *error* code (2)
    /// rather than `FNM_NOMATCH` for these, and `Glob` tests for `== 0` — so they fall on the safe
    /// side of the line. The editor is live, so every one of these is a state the user's list passes
    /// through while they type, and the alternative (an error read as "matches") would flood the
    /// pane with colour mid-keystroke.
    @Test("a malformed pattern colours nothing rather than everything")
    func malformedPatternMatchesNothing() {
        #expect(!rule(["["]).matches(name: "["))
        #expect(!rule(["[a-"]).matches(name: "b"))
        #expect(!rule(["*["]).matches(name: "x["))
        #expect(!rule(["\\"]).matches(name: "\\"))
    }

    /// The two `fnmatch` behaviours a user will actually meet, pinned so a later "fix" to `Glob`
    /// (setting `FNM_PERIOD`, say) has to argue with a test: `*` takes dotfiles, and `*.*` does not
    /// take a name with no extension.
    @Test("* covers dotfiles; *.* means 'has an extension'")
    func wildcardScope() {
        #expect(rule(["*"]).matches(name: ".gitignore"))
        #expect(rule(["*.*"]).matches(name: "notes.txt"))
        #expect(!rule(["*.*"]).matches(name: "Makefile"))
    }

    // MARK: - Target

    @Test("a target admits only its own kind of row")
    func targetAdmits() {
        #expect(FileColorTarget.any.admits(isDirectory: true))
        #expect(FileColorTarget.any.admits(isDirectory: false))
        #expect(!FileColorTarget.filesOnly.admits(isDirectory: true))
        #expect(FileColorTarget.filesOnly.admits(isDirectory: false))
        #expect(FileColorTarget.foldersOnly.admits(isDirectory: true))
        #expect(!FileColorTarget.foldersOnly.admits(isDirectory: false))
    }

    // MARK: - Sanitizing

    @Test("patterns are trimmed and empties dropped on the way in")
    func sanitizesPatterns() {
        let typed = rule([" *.jpg ", "", "   ", "*.png"])
        #expect(typed.patterns == ["*.jpg", "*.png"])
    }

    // MARK: - Codable

    @Test("a rule round-trips through JSON")
    func roundTrips() throws {
        let original = FileColorRule(
            name: "Images",
            patterns: ["*.jpg", "*.png"],
            colorHex: "#00A0A0",
            target: .filesOnly
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FileColorRule.self, from: data)
        #expect(decoded == original)
        #expect(decoded.id == original.id)
    }

    /// The trap PLAN.md §M15 Slice 1 recorded one level up, where a `Codable` enum throwing on an
    /// unknown case took the whole `PersistedTab` with it. Here the blast radius is larger — the
    /// rule list is a single JSON value, so one throw empties *every* rule the user ever wrote.
    @Test("a target written by a newer build degrades to .any, keeping the rule")
    func unknownTargetDegrades() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Future","patterns":["*.zip"],\
        "colorHex":"#FF8800","target":"symlinksOnly"}
        """
        let decoded = try JSONDecoder().decode(FileColorRule.self, from: Data(json.utf8))
        #expect(decoded.target == .any)
        #expect(decoded.patterns == ["*.zip"])
        #expect(decoded.name == "Future")
    }

    @Test("a hand-edited rule missing fields decodes rather than throwing")
    func missingFieldsDegrade() throws {
        // `##"…"##`, not `#"…"#`: a colour hex is preceded by a quote, so `"#` inside the literal
        // would close a single-pound raw string early.
        let decoded = try JSONDecoder().decode(
            FileColorRule.self,
            from: Data(##"{"patterns":["*.log"],"colorHex":"#123456"}"##.utf8)
        )
        #expect(decoded.patterns == ["*.log"])
        #expect(decoded.colorHex == "#123456")
        #expect(decoded.target == .any)
        #expect(decoded.name.isEmpty)
    }
}

@Suite("FileColorRules")
struct FileColorRulesTests {
    private func rule(
        _ patterns: [String],
        color: String,
        target: FileColorTarget = .any
    ) -> FileColorRule {
        FileColorRule(patterns: patterns, colorHex: color, target: target)
    }

    private func entry(
        _ name: String,
        kind: FileEntry.Kind = .file,
        symlinkTargetKind: FileEntry.Kind? = nil
    ) -> FileEntry {
        FileEntry(
            path: .local("/tmp/\(name)"),
            name: name,
            kind: kind,
            byteSize: 0,
            modificationDate: Date(),
            creationDate: Date(),
            isHidden: name.hasPrefix("."),
            permissions: 0o644,
            inode: 1,
            symlinkTargetKind: symlinkTargetKind
        )
    }

    // MARK: - First match wins

    /// The whole contract of an ordered list, and the reason nothing here sorts or dedupes: a user
    /// puts the specific rule above the general one, and that arrangement *is* their intent.
    @Test("the first matching rule wins, not the most specific")
    func firstMatchWins() {
        let rules = FileColorRules(rules: [
            rule(["*.min.js"], color: "#AAAAAA"),
            rule(["*.js"], color: "#F7DF1E")
        ])
        #expect(rules.firstMatch(name: "app.min.js", isDirectory: false)?.colorHex == "#AAAAAA")
        #expect(rules.firstMatch(name: "app.js", isDirectory: false)?.colorHex == "#F7DF1E")
    }

    /// The same two rules the other way round: the general one now shadows the specific one
    /// completely. This is a list a user is allowed to build — and to see, while they drag it
    /// straight — so it is pinned as correct behaviour rather than repaired.
    @Test("a general rule above a specific one shadows it, and that is not repaired")
    func shadowingIsPreserved() {
        let rules = FileColorRules(rules: [
            rule(["*.js"], color: "#F7DF1E"),
            rule(["*.min.js"], color: "#AAAAAA")
        ])
        #expect(rules.firstMatch(name: "app.min.js", isDirectory: false)?.colorHex == "#F7DF1E")
        #expect(rules.rules.count == 2)
    }

    @Test("no rule matching is nil, and an empty list matches nothing")
    func noMatch() {
        #expect(FileColorRules().firstMatch(name: "a.txt", isDirectory: false) == nil)
        let rules = FileColorRules(rules: [rule(["*.jpg"], color: "#008080")])
        #expect(rules.firstMatch(name: "a.txt", isDirectory: false) == nil)
    }

    // MARK: - Target

    /// The case a name glob genuinely cannot express, and the reason `target` is a field: `*` would
    /// otherwise take every file along with every folder.
    @Test("a folders-only rule skips files with the same name, and vice versa")
    func targetGatesTheMatch() {
        let folders = FileColorRules(rules: [rule(["*"], color: "#4A90D9", target: .foldersOnly)])
        #expect(folders.firstMatch(name: "src", isDirectory: true)?.colorHex == "#4A90D9")
        #expect(folders.firstMatch(name: "src", isDirectory: false) == nil)

        let files = FileColorRules(rules: [rule(["*"], color: "#B0B0B0", target: .filesOnly)])
        #expect(files.firstMatch(name: "src", isDirectory: false)?.colorHex == "#B0B0B0")
        #expect(files.firstMatch(name: "src", isDirectory: true) == nil)
    }

    /// A folders-only rule that a file's name matches must not consume the file's turn — the next
    /// rule still gets to claim it.
    @Test("a rule its target rejects is skipped, not treated as the match")
    func rejectedTargetFallsThrough() {
        let rules = FileColorRules(rules: [
            rule(["*"], color: "#4A90D9", target: .foldersOnly),
            rule(["*.txt"], color: "#CC0000", target: .filesOnly)
        ])
        #expect(rules.firstMatch(name: "notes.txt", isDirectory: false)?.colorHex == "#CC0000")
    }

    /// `isDirectoryLike`, not `isDirectory`: a symlink pointing at a folder opens into that folder
    /// everywhere else in the pane, so it is coloured as one here too.
    @Test("a symlink to a folder counts as a folder")
    func symlinkToFolderIsAFolder() {
        let rules = FileColorRules(rules: [rule(["*"], color: "#4A90D9", target: .foldersOnly)])
        #expect(
            rules.firstMatch(for: entry("link", kind: .symlink, symlinkTargetKind: .directory)) != nil
        )
        #expect(
            rules.firstMatch(for: entry("link", kind: .symlink, symlinkTargetKind: .file)) == nil
        )
        #expect(rules.firstMatch(for: entry("dir", kind: .directory)) != nil)
        #expect(rules.firstMatch(for: entry("plain.txt")) == nil)
    }

    // MARK: - Editing

    @Test("append puts a new rule last, where it cannot shadow what is already there")
    func appendsLast() {
        var rules = FileColorRules(rules: [rule(["*.jpg"], color: "#008080")])
        rules.append(rule(["*.png"], color: "#800080"))
        #expect(rules.rules.map(\.colorHex) == ["#008080", "#800080"])
    }

    @Test("update replaces by id and reports whether the rule was still there")
    func updatesByID() {
        let first = rule(["*.jpg"], color: "#008080")
        var rules = FileColorRules(rules: [first, rule(["*.png"], color: "#800080")])
        var edited = first
        edited.colorHex = "#00FF00"
        // Hoisted: a `mutating` call cannot sit inside `#expect` (NOTES.md ▸ Testing).
        let replaced = rules.update(edited)
        #expect(replaced)
        #expect(rules.rules[0].colorHex == "#00FF00")
        // The case a commit-on-focus-loss genuinely reaches: the rule was deleted mid-edit.
        let missing = rules.update(rule(["*.gif"], color: "#000000"))
        #expect(!missing)
    }

    @Test("remove ignores an out-of-range index")
    func removeOutOfRange() {
        var rules = FileColorRules(rules: [rule(["*.jpg"], color: "#008080")])
        rules.remove(at: 5)
        rules.remove(at: -1)
        #expect(rules.rules.count == 1)
        rules.remove(at: 0)
        #expect(rules.isEmpty)
    }

    @Test("move lands the rule at its destination in the resulting list")
    func moveSemantics() {
        var rules = FileColorRules(rules: [
            rule(["a"], color: "#A"),
            rule(["b"], color: "#B"),
            rule(["c"], color: "#C")
        ])
        rules.move(from: 0, to: 2)
        #expect(rules.rules.map(\.patterns) == [["b"], ["c"], ["a"]])
        rules.move(from: 2, to: 0)
        #expect(rules.rules.map(\.patterns) == [["a"], ["b"], ["c"]])
        // Out of range on either end is clamped rather than trapping.
        rules.move(from: 0, to: 99)
        #expect(rules.rules.map(\.patterns) == [["b"], ["c"], ["a"]])
        rules.move(from: 7, to: 0)
        #expect(rules.rules.map(\.patterns) == [["b"], ["c"], ["a"]])
    }

    // MARK: - Codable

    @Test("the list round-trips through JSON in order")
    func roundTripsInOrder() throws {
        let rules = FileColorRules(rules: [
            FileColorRule(name: "Images", patterns: ["*.jpg"], colorHex: "#008080"),
            FileColorRule(
                name: "Archives",
                patterns: ["*.zip"],
                colorHex: "#800080",
                target: .filesOnly
            )
        ])
        let data = try JSONEncoder().encode(rules)
        let decoded = try JSONDecoder().decode(FileColorRules.self, from: data)
        #expect(decoded == rules)
        #expect(decoded.rules.map(\.name) == ["Images", "Archives"])
    }

    /// A store that duplicated an id — the one repair the initializer makes, because an editor
    /// keyed on id would otherwise act on whichever row it found first.
    @Test("a duplicated id is collapsed to its first occurrence")
    func duplicateIDsCollapse() {
        let id = UUID()
        let rules = FileColorRules(rules: [
            FileColorRule(id: id, patterns: ["*.jpg"], colorHex: "#008080"),
            FileColorRule(id: id, patterns: ["*.png"], colorHex: "#800080")
        ])
        #expect(rules.rules.count == 1)
        #expect(rules.rules[0].patterns == ["*.jpg"])
    }
}
