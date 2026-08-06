import Foundation

/// `LanguageGrammar.words` under a short name, because it is the most-repeated call in the table.
private func words(_ list: String) -> Set<String> { LanguageGrammar.words(list) }

/// The hash-comment half of the grammar table (PLAN.md §M17 ▸ Slice 1).
///
/// The same scanner as the C family with a different comment token and a different word list —
/// which is the whole reason `LanguageGrammar` is data. Ten languages, and none of them has a block
/// comment: Python's "block comment" is a triple-quoted string, and it is listed as one.
///
/// Note what is *absent* from every row here: `preprocessorSigil`. `#` is already the line comment,
/// so the two can never both be set, which is what the field's doc comment promises.
enum HashFamilyGrammars {
    /// The shape every row below starts from: `#` line comments, no block comment, double- and
    /// single-quoted literals.
    static func base(
        keywords: Set<String>,
        typeNames: Set<String> = [],
        strings: [LanguageGrammar.StringLiteral] = [.doubleQuoted, .singleQuoted],
        lineComments: [String] = ["#"],
        annotationSigil: String? = nil,
        keywordsAreCaseInsensitive: Bool = false
    ) -> LanguageGrammar {
        LanguageGrammar(
            lineComments: lineComments,
            blockComment: nil,
            strings: strings,
            keywords: keywords,
            typeNames: typeNames,
            annotationSigil: annotationSigil,
            keywordsAreCaseInsensitive: keywordsAreCaseInsensitive
        )
    }

    // MARK: - Scripting

    /// The triple-quoted forms are listed first because the compiled grammar sorts by opener
    /// length anyway — but written in this order the table says out loud that a docstring is a
    /// string, which is the one thing a Python file gets wrong if they are missing.
    static let python = base(
        keywords: words("""
        and as assert async await break case class continue def del elif else except False
        finally for from global if import in is lambda match None nonlocal not or pass raise
        return self True try while with yield
        """),
        typeNames: words("""
        bool bytes complex dict float frozenset int list object set str tuple type Exception
        """),
        strings: [.tripleDoubleQuoted, .tripleSingleQuoted, .doubleQuoted, .singleQuoted],
        annotationSigil: "@"
    )

    /// Ruby's `=begin`/`=end` block comment is not scanned: it is a whole-line delimiter rather
    /// than an inline one, and it is rare enough that the single flag it would need in
    /// `LanguageGrammar` would be carried by ten grammars for one.
    static let ruby = base(
        keywords: words("""
        alias and attr_accessor attr_reader attr_writer begin BEGIN break case class def do else
        elsif END end ensure extend false for if in include lambda module next nil not or proc
        redo require require_relative rescue retry return self super then true undef unless until
        when while yield
        """),
        typeNames: words("""
        Array File Float Hash Integer Proc Range String Struct Symbol Time
        """)
    )

    /// A **heredoc** (`<<EOF`) is not scanned — its terminator is named at the opening and has to
    /// be remembered, which is the boundary PLAN.md §6 draws. Its body simply colours as code.
    ///
    /// Single quotes take the escape-free form: inside `'…'` a shell has no escape character at
    /// all, so `'\'` is a complete, correct literal ending at its second quote.
    static let shell = base(
        keywords: words("""
        alias break case cd continue declare do done echo elif else esac eval exec exit export
        fi for function if in local printf read readonly return select set shift source test
        then time trap typeset unset until while
        """),
        strings: [.doubleQuoted, .unescapedSingleQuoted]
    )

    static let perl = base(
        keywords: words("""
        and BEGIN bless chomp chop cmp defined delete do else elsif END eq exists foreach for
        ge goto gt join keys last le local lt my ne next no not or our package pop print printf
        push redo ref require return say scalar shift sort split sub undef unless unshift until
        use values wantarray while
        """),
        strings: [.doubleQuoted, .singleQuoted, .backtickQuoted]
    )

    // MARK: - Build and configuration files

    static let makefile = base(
        keywords: words("""
        define else endef endif export ifdef ifeq ifndef ifneq include override sinclude
        unexport vpath
        """)
    )

    /// CMake commands are case-insensitive, and real projects are written in both cases — the
    /// second grammar on the flag SQL introduced.
    static let cmake = base(
        keywords: words("""
        add_custom_command add_definitions add_executable add_library add_subdirectory
        break cmake_minimum_required continue else elseif endforeach endfunction endif endmacro
        endwhile file find_package foreach function if include install list macro message option
        project return set string target_compile_options target_include_directories
        target_link_libraries unset while
        """),
        keywordsAreCaseInsensitive: true
    )

    /// Dockerfile instructions are conventionally uppercase and legally any case, so they take the
    /// same flag CMake does rather than a second copy of every word.
    static let dockerfile = base(
        keywords: words("""
        add arg as cmd copy entrypoint env expose from healthcheck label maintainer onbuild run
        shell stopsignal user volume workdir
        """),
        keywordsAreCaseInsensitive: true
    )

    /// YAML's booleans have several accepted spellings and YAML is *not* case-insensitive as a
    /// language, so they are listed rather than folded — `True` is a boolean and `TRue` is a
    /// string, which a case-insensitive flag could not express.
    static let yaml = base(
        keywords: words("""
        false False FALSE no No NO null Null NULL off Off OFF on On ON true True TRUE yes Yes YES
        """)
    )

    static let toml = base(
        keywords: words("false inf nan true"),
        strings: [.tripleDoubleQuoted, .tripleSingleQuoted, .doubleQuoted, .unescapedSingleQuoted]
    )

    /// INI, `.conf`, `.cfg` and `.properties`, which take `;` as a second comment token — the one
    /// row in the table that is a *family* of formats rather than a language, and is approximate on
    /// purpose.
    static let ini = base(
        keywords: words("false no off on true yes"),
        lineComments: ["#", ";"]
    )
}
