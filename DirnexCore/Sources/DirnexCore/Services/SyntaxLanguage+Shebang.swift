import Foundation

/// Routing a script by its `#!` line, for the files whose name says nothing about their language:
/// `gradlew`, `bin/rails`, `/usr/bin/pydoc3`, and every script somebody saved without an extension.
public extension SyntaxLanguage {
    /// The language for a file named `name` whose text is `text`: the name first, and the `#!` line
    /// only when the name claims nothing.
    ///
    /// Name first because a name is the one routing that never needs the file's bytes, and because
    /// where both answer they agree on everything but the rare script whose name and interpreter
    /// disagree — and there the name is what the author chose to call it.
    static func forFile(named name: String, text: String) -> SyntaxLanguage? {
        forFile(named: name) ?? forShebang(in: text)
    }

    /// The language the interpreter on `text`'s `#!` line is written in, or `nil` when `text` does not
    /// open with one or names an interpreter nothing here colors (`dtrace`, `pwsh`, `osascript`).
    ///
    /// The shapes are the ones a survey of about 3 000 scripts on this Mac found (2026-09-16): a path
    /// (`#!/bin/sh`, `#! /bin/zsh`, `#!/usr/bin/perl -w`, a virtual environment's
    /// `/…/.venv/bin/python3`), a launcher in front of the interpreter (`#!/usr/bin/env node`,
    /// `#!/usr/bin/env -S ruby`, `#!/usr/bin/xcrun swift`), and a version on the name
    /// (`python3.14`, `ksh93`).
    static func forShebang(in text: String) -> SyntaxLanguage? {
        // The kernel reads the first two bytes and nothing else decides it, so nothing may precede
        // them — not a space, not a comment. A byte-order mark is already gone: `TextPreview` strips it.
        guard text.hasPrefix("#!") else { return nil }
        let line = text.dropFirst(2).prefix(shebangLengthLimit).prefix { !$0.isNewline }
        var words = line.split(whereSeparator: \.isWhitespace).map(String.init)[...]
        guard let first = words.popFirst() else { return nil }
        var command = commandName(first)
        while let valueOptions = launchers[command] {
            guard let launched = launchedCommand(in: &words, valueOptions: valueOptions) else {
                return nil
            }
            command = commandName(launched)
        }
        return interpreters[command]
    }

    /// The most of the first line read. A real `#!` line is a path and a few words; this only stops a
    /// file that opens with `#!` and has no line break from being walked to its end.
    private static let shebangLengthLimit = 1024

    /// Commands that run the next word rather than the script, with the options of theirs that take a
    /// value — which is the value word that has to be skipped along with the option.
    private static let launchers: [String: Set<String>] = [
        "env": ["-u", "-P", "-C"],
        "xcrun": ["--sdk", "-sdk", "--toolchain", "-toolchain"]
    ]

    /// Interpreter names, as `commandName` leaves them, and the language a script for each is in.
    private static let interpreters: [String: SyntaxLanguage] = [
        "sh": .shell, "bash": .shell, "zsh": .shell, "ksh": .shell, "mksh": .shell, "dash": .shell,
        "python": .python, "pypy": .python, "vpython": .python,
        // `#!/usr/bin/env uv run`: uv runs Python scripts and nothing else.
        "uv": .python,
        "ruby": .ruby,
        "perl": .perl,
        "node": .javascript, "nodejs": .javascript, "zx": .javascript,
        "swift": .swift,
        "php": .php
    ]

    /// The first word a launcher runs, consuming everything up to and including it: its options, the
    /// value an option takes, `--`, and `env`'s `NAME=value` assignments. `nil` when nothing is left.
    private static func launchedCommand(
        in words: inout ArraySlice<String>,
        valueOptions: Set<String>
    ) -> String? {
        while let word = words.popFirst() {
            if valueOptions.contains(word) {
                _ = words.popFirst()
            } else if !word.hasPrefix("-"), !word.contains("=") {
                return word
            }
        }
        return nil
    }

    /// The name a word runs, lowercased and without its version: `/usr/local/bin/python3.14` is
    /// `python`, `ksh93` is `ksh`, `Python` is `python`. A name that is nothing but a version stays
    /// as it is and matches nothing.
    private static func commandName(_ word: String) -> String {
        let name = (word.split(separator: "/").last.map(String.init) ?? word).lowercased()
        let unversioned = name.reversed().drop { $0.isASCII && ($0.isNumber || $0 == ".") }
        return unversioned.isEmpty ? name : String(unversioned.reversed())
    }
}
