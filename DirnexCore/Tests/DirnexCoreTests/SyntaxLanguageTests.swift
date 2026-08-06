import Foundation
import Testing

@testable import DirnexCore

/// Which language a file gets, and the invariants the grammar table has to hold (PLAN.md §M17 ▸
/// Slice 1). The table is data, and data is exactly what drifts without a test over it.
@Suite("SyntaxLanguage")
struct SyntaxLanguageTests {
    // MARK: - Routing

    @Test("an extension picks the language, whatever its case")
    func byExtension() {
        #expect(SyntaxLanguage.forFile(named: "Panel.swift") == .swift)
        #expect(SyntaxLanguage.forFile(named: "PANEL.SWIFT") == .swift)
        #expect(SyntaxLanguage.forFile(named: "main.py") == .python)
        #expect(SyntaxLanguage.forFile(named: "schema.sql") == .sql)
        #expect(SyntaxLanguage.forFile(named: "app.tsx") == .typeScript)
        #expect(SyntaxLanguage.forFile(named: "styles.scss") == .css)
    }

    @Test("a .h is the union of the three languages it might be")
    func headerRouting() {
        // `UTType` answers `public.c-header` and cannot say which dialect — which is why the
        // routing is extension-first at all (`SyntaxLanguage`'s doc comment).
        #expect(SyntaxLanguage.forFile(named: "Widget.h") == .cHeader)
        #expect(SyntaxLanguage.forFile(named: "Widget.hpp") == .cPlusPlus)
        #expect(SyntaxLanguage.forFile(named: "Widget.m") == .objectiveC)
        let header = SyntaxLanguage.cHeader.grammar
        #expect(header?.keywords.contains("template") == true)
        #expect(header?.keywords.contains("interface") == true)
        #expect(header?.annotationSigil == "@")
    }

    @Test("an extensionless name and a dot-file route by whole name")
    func byFileName() {
        #expect(SyntaxLanguage.forFile(named: "Makefile") == .makefile)
        #expect(SyntaxLanguage.forFile(named: "GNUmakefile") == .makefile)
        #expect(SyntaxLanguage.forFile(named: "Dockerfile") == .dockerfile)
        #expect(SyntaxLanguage.forFile(named: "CMakeLists.txt") == .cmake)
        #expect(SyntaxLanguage.forFile(named: "Rakefile") == .ruby)
        // The only dot is the first character, so an extension-only route would read the whole
        // name as the extension and find nothing.
        #expect(SyntaxLanguage.forFile(named: ".zshrc") == .shell)
        #expect(SyntaxLanguage.forFile(named: ".editorconfig") == .ini)
    }

    @Test("a path is reduced to its last component")
    func pathsWork() {
        #expect(SyntaxLanguage.forFile(named: "/Users/o/Dev/x/Panel.swift") == .swift)
        #expect(SyntaxLanguage.forFile(named: "src/.bashrc") == .shell)
    }

    @Test("an unclaimed file is nil, which is not a failure")
    func unknownFiles() {
        // Renders exactly as it did before the milestone: one colour, correct.
        #expect(SyntaxLanguage.forFile(named: "notes.txt") == nil)
        #expect(SyntaxLanguage.forFile(named: "archive.zip") == nil)
        #expect(SyntaxLanguage.forFile(named: "README") == nil)
        #expect(SyntaxLanguage.forFile(named: "") == nil)
        #expect(SyntaxLanguage.forFile(named: ".") == nil)
    }

    @Test("the three scanner-backed languages route, and offer no grammar")
    func scannerBackedLanguages() {
        #expect(SyntaxLanguage.forFile(named: "index.html") == .markup)
        // `.xhtml` is `public.xhtml` and conforms to neither `public.html` nor anything the family
        // could be derived from (docs/NOTES.md), so the set is named rather than inferred.
        #expect(SyntaxLanguage.forFile(named: "page.xhtml") == .markup)
        #expect(SyntaxLanguage.forFile(named: "Info.plist") == .markup)
        #expect(SyntaxLanguage.forFile(named: "logo.svg") == .markup)
        #expect(SyntaxLanguage.forFile(named: "PLAN.md") == .markdown)
        #expect(SyntaxLanguage.forFile(named: "fix.patch") == .diff)
        for language in [SyntaxLanguage.markup, .markdown, .diff] {
            #expect(language.grammar == nil)
        }
    }

    @Test("an .xcstrings is JSON, which is what the file itself says")
    func stringCatalogsAreJSON() {
        // Probed against this repo's own catalogs: they open with `{ "sourceLanguage": … }`.
        // PLAN.md §M17 lists `.xcstrings` with the markup family; that is a slip.
        #expect(SyntaxLanguage.forFile(named: "Localizable.xcstrings") == .json)
    }

    // MARK: - Table invariants

    @Test("no extension and no file name is claimed by two languages")
    func routingIsUnambiguous() {
        var extensions: [String: SyntaxLanguage] = [:]
        var collisions: [String] = []
        for language in SyntaxLanguage.allCases {
            for suffix in language.fileExtensions {
                if let existing = extensions[suffix], existing != language {
                    collisions.append(suffix)
                }
                extensions[suffix] = language
            }
        }
        #expect(collisions.isEmpty)

        var names: [String: SyntaxLanguage] = [:]
        var nameCollisions: [String] = []
        for language in SyntaxLanguage.allCases {
            for name in language.fileNames {
                if let existing = names[name], existing != language { nameCollisions.append(name) }
                names[name] = language
            }
        }
        #expect(nameCollisions.isEmpty)
    }

    @Test("every language routes from at least one file, and every route round-trips")
    func everyLanguageIsReachable() {
        var unreachable: [SyntaxLanguage] = []
        var misrouted: [String] = []
        for language in SyntaxLanguage.allCases {
            if language.fileExtensions.isEmpty, language.fileNames.isEmpty {
                unreachable.append(language)
            }
            for suffix in language.fileExtensions
                where SyntaxLanguage.forFile(named: "sample.\(suffix)") != language {
                misrouted.append(suffix)
            }
            for name in language.fileNames where SyntaxLanguage.forFile(named: name) != language {
                misrouted.append(name)
            }
        }
        #expect(unreachable.isEmpty)
        #expect(misrouted.isEmpty)
    }

    @Test("every grammar can claim something — a comment, a string or a word")
    func everyGrammarIsUseful() {
        var inert: [SyntaxLanguage] = []
        for language in SyntaxLanguage.allCases {
            guard let grammar = language.grammar else { continue }
            let claims = !grammar.lineComments.isEmpty || grammar.blockComment != nil
                || !grammar.strings.isEmpty || !grammar.keywords.isEmpty
            if !claims { inert.append(language) }
        }
        #expect(inert.isEmpty)
    }

    @Test("a case-insensitive grammar stores its words lowercased")
    func foldedGrammarsAreStoredFolded() {
        // The scanner folds the file's word once and looks it up as-is, so a capital in the table
        // would be a keyword that can never match — and nothing else would say so.
        var wrong: [String] = []
        for language in SyntaxLanguage.allCases {
            guard let grammar = language.grammar, grammar.keywordsAreCaseInsensitive else {
                continue
            }
            wrong += grammar.keywords.filter { $0 != $0.lowercased() }
            wrong += grammar.typeNames.filter { $0 != $0.lowercased() }
        }
        #expect(wrong.isEmpty)
    }

    @Test("`#` is never both a line comment and the preprocessor sigil")
    func sigilsDoNotCollide() {
        // The one thing the scanner cannot decide between, so the table must never ask it to.
        var conflicted: [SyntaxLanguage] = []
        for language in SyntaxLanguage.allCases {
            guard let grammar = language.grammar else { continue }
            if let sigil = grammar.preprocessorSigil, grammar.lineComments.contains(sigil) {
                conflicted.append(language)
            }
        }
        #expect(conflicted.isEmpty)
    }

    @Test("a keyword is always ASCII, which is what lets the scanner skip the lookup")
    func keywordsAreASCII() {
        // `SyntaxHighlighter.classify` refuses to build a word containing a non-ASCII unit. A
        // non-ASCII keyword in the table would therefore be dead data, silently.
        var wide: [String] = []
        for language in SyntaxLanguage.allCases {
            guard let grammar = language.grammar else { continue }
            wide += (grammar.keywords.union(grammar.typeNames)).filter { !$0.allSatisfy(\.isASCII) }
        }
        #expect(wide.isEmpty)
    }

    @Test("a grammar with a block comment gives both delimiters")
    func blockCommentsAreComplete() {
        var broken: [SyntaxLanguage] = []
        for language in SyntaxLanguage.allCases {
            guard let block = language.grammar?.blockComment else { continue }
            if block.open.isEmpty || block.close.isEmpty { broken.append(language) }
        }
        #expect(broken.isEmpty)
    }
}
