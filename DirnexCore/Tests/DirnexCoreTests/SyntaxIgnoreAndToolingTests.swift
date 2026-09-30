import Foundation
import Testing

@testable import DirnexCore

/// Ignore files, `.gitattributes` and `CODEOWNERS`, and the four build and platform grammars in
/// `ToolingGrammars` (docs/HISTORY.md, 2026-09-16).
@Suite("SyntaxIgnore and the tooling grammars")
struct SyntaxIgnoreAndToolingTests {
    private typealias Span = SyntaxSpan

    private func ignore(_ text: String) -> [Span] { syntaxSpans(text, .ignoreFile) }
    private func attributes(_ text: String) -> [Span] { syntaxSpans(text, .gitAttributes) }

    // MARK: - Ignore files

    @Test("a comment line, a negation, and the glob metacharacters")
    func ignorePatterns() {
        let source = """
        # Build products
        .build/
        *.xcuserstate
        !keep.log
        **/DerivedData/
        file?[0-9].txt
        """
        #expect(ignore(source) == [
            Span("# Build products", .comment),
            Span("*", .keyword),
            Span("!", .keyword),
            Span("**", .keyword),
            Span("?", .keyword),
            Span("[0-9]", .keyword)
        ])
    }

    @Test("a # or ! anywhere but first is part of the pattern, and an escape is literal")
    func ignoreLiterals() {
        // What a grammar's line comment would get wrong: the rest of `docs#1/` is not a comment.
        #expect(ignore("docs#1/\nkeep!\n\\#literal\n\\*.txt\n").isEmpty)
    }

    @Test("a lone [ is a literal, and a ] straight after [ or [! belongs to the class")
    func characterClasses() {
        #expect(ignore("[abc\n[]]x\n[!a].o\n") == [
            Span("[]]", .keyword),
            Span("[!a]", .keyword)
        ])
    }

    // MARK: - .gitattributes and CODEOWNERS

    @Test("an attribute, its value, and its unset and unspecified forms")
    func gitAttributes() {
        let source = """
        * text=auto
        *.pbxproj -diff merge=union
        "my file.txt" !eol binary
        """
        #expect(attributes(source) == [
            Span("*", .keyword),
            Span("text", .typeOrTag),
            Span("auto", .string),
            Span("*", .keyword),
            Span("-diff", .typeOrTag),
            Span("merge", .typeOrTag),
            Span("union", .string),
            Span("\"my file.txt\"", .string),
            Span("!eol", .typeOrTag),
            Span("binary", .typeOrTag)
        ])
    }

    @Test("a .gitattributes pattern has no negation")
    func attributesPatternIsNotNegated() {
        #expect(attributes("!x text") == [Span("text", .typeOrTag)])
    }

    @Test("a CODEOWNERS line is a pattern and its owners")
    func codeOwners() {
        #expect(attributes("# Web\n*.js @org/web-team user@example.com\r\n") == [
            Span("# Web", .comment),
            Span("*", .keyword),
            Span("@org/web-team", .typeOrTag),
            Span("user@example.com", .typeOrTag)
        ])
    }

    // MARK: - The tooling grammars

    @Test("an .xcconfig colors its comments, includes, strings and YES/NO")
    func xcconfig() {
        let source = """
        // Shared settings
        #include? "Pods/Pods.xcconfig"
        SWIFT_VERSION = 6.0
        ENABLE_BITCODE = NO
        OTHER_LDFLAGS = $(inherited) -ObjC
        HOST = https://example.com
        """
        #expect(syntaxSpans(source, .xcconfig) == [
            Span("// Shared settings", .comment),
            Span("#include", .keyword),
            Span("\"Pods/Pods.xcconfig\"", .string),
            Span("6.0", .number),
            Span("NO", .keyword),
            Span("inherited", .keyword),
            // As Xcode reads it: a `//` in a value is a comment.
            Span("//example.com", .comment)
        ])
    }

    @Test("a .strings table is comments and strings")
    func appleStrings() {
        #expect(syntaxSpans("/* Button */\n\"OK\" = \"Хорошо\";\n// note", .appleStrings) == [
            Span("/* Button */", .comment),
            Span("\"OK\"", .string),
            Span("\"Хорошо\"", .string),
            Span("// note", .comment)
        ])
    }

    @Test("a batch file's REM and :: comments, @echo, and case-insensitive commands")
    func batch() {
        let source = """
        @echo off
        REM Build it
        :: also a comment
        set "DIR=%~dp0"
        IF errorlevel 1 exit /b 1
        echo removed
        """
        #expect(syntaxSpans(source, .batch) == [
            Span("@echo", .keyword),
            Span("off", .keyword),
            Span("REM Build it", .comment),
            Span(":: also a comment", .comment),
            Span("set", .keyword),
            Span("\"DIR=%~dp0\"", .string),
            Span("IF", .keyword),
            Span("errorlevel", .keyword),
            Span("1", .number),
            Span("exit", .keyword),
            Span("1", .number),
            // `removed` starts like `rem` and is a word, not a comment.
            Span("echo", .keyword)
        ])
    }

    @Test("PowerShell's block comments, variables, types, escapes and here-strings")
    func powerShell() {
        let source = """
        <#
          Stop the stack.
        #>
        $ErrorActionPreference = 'Continue'
        function Stop-All([string]$Name) {
            Write-Host "Stopping `"$Name`"" # done
            ForEach ($x in $items) { }
            $text = @"
        multi "line"
        "@
        }
        """
        #expect(syntaxSpans(source, .powerShell) == [
            Span("<#\n  Stop the stack.\n#>", .comment),
            Span("$ErrorActionPreference", .keyword),
            Span("'Continue'", .string),
            Span("function", .keyword),
            Span("string", .typeOrTag),
            Span("$Name", .keyword),
            Span("\"Stopping `\"$Name`\"\"", .string),
            Span("# done", .comment),
            Span("ForEach", .keyword),
            Span("$x", .keyword),
            Span("in", .keyword),
            Span("$items", .keyword),
            Span("$text", .keyword),
            Span("@\"\nmulti \"line\"\n\"@", .string)
        ])
    }
}
