import Foundation
import Testing

@testable import DirnexCore

/// A script's language from its `#!` line. Every line here is one a survey of this Mac's scripts
/// found (2026-09-16), unless its comment says otherwise.
@Suite("SyntaxLanguage from a #! line")
struct SyntaxShebangTests {
    @Test("an interpreter path names the language")
    func interpreterPaths() {
        #expect(SyntaxLanguage.forShebang(in: "#!/bin/sh\necho hi\n") == .shell)
        #expect(SyntaxLanguage.forShebang(in: "#!/bin/bash -pu\n") == .shell)
        #expect(SyntaxLanguage.forShebang(in: "#!/bin/sh -\n") == .shell)
        #expect(SyntaxLanguage.forShebang(in: "#! /bin/zsh\n") == .shell)
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/bin/perl -w\n") == .perl)
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/bin/perl \n") == .perl)
        #expect(
            SyntaxLanguage.forShebang(
                in: "#!/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/bin/ruby\n"
            ) == .ruby
        )
        #expect(SyntaxLanguage.forShebang(in: "#!/Users/o/app/.venv312/bin/python3\n") == .python)
    }

    @Test("a launcher is skipped for the command it runs")
    func launchers() {
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/bin/env python3\n") == .python)
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/bin/env node --harmony\n") == .javascript)
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/bin/env -S ruby\n") == .ruby)
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/bin/env zx\n") == .javascript)
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/bin/env uv run\n") == .python)
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/bin/xcrun swift\n") == .swift)
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/bin/xcrun python3\n") == .python)
        // Not from the survey, which found no PowerShell script on this Mac.
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/bin/env pwsh\n") == .powerShell)
    }

    /// Not from the survey: `env`'s own options, which the parser has to step over to find the name.
    @Test("a launcher's options, their values and env's assignments are skipped")
    func launcherOptions() {
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/bin/env -u HOME -S python3\n") == .python)
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/bin/env LC_ALL=C perl\n") == .perl)
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/bin/env -i -- bash\n") == .shell)
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/bin/xcrun --sdk macosx swift\n") == .swift)
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/bin/env\n") == nil)
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/bin/env -u\n") == nil)
    }

    @Test("a version on the name is not part of it")
    func versionedNames() {
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/local/bin/python3.14\n") == .python)
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/bin/env python3.8\n") == .python)
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/bin/env vpython3\n") == .python)
        #expect(SyntaxLanguage.forShebang(in: "#!/bin/ksh93\n") == .shell)
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/bin/perl5.30\n") == .perl)
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/bin/Python\n") == .python)
    }

    @Test("a Windows line ending does not reach the name")
    func crlf() {
        #expect(SyntaxLanguage.forShebang(in: "#!/bin/sh\r\necho hi\r\n") == .shell)
    }

    @Test("an interpreter nothing here colors, or no #! line at all, is nil")
    func unclaimed() {
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/sbin/dtrace -s\n") == nil)
        #expect(SyntaxLanguage.forShebang(in: "#!/usr/bin/env ./node_modules/.bin/coffee\n") == nil)
        #expect(SyntaxLanguage.forShebang(in: "#!/bin/csh\n") == nil)
        #expect(SyntaxLanguage.forShebang(in: "#!\n") == nil)
        #expect(SyntaxLanguage.forShebang(in: "") == nil)
        #expect(SyntaxLanguage.forShebang(in: "1.0.10\n") == nil)
        // The kernel reads the first two bytes, so a `#!` anywhere else is not one.
        #expect(SyntaxLanguage.forShebang(in: " #!/bin/sh\n") == nil)
        #expect(SyntaxLanguage.forShebang(in: "# setup\n#!/bin/sh\n") == nil)
    }

    @Test("the name decides first, and the #! line only when the name claims nothing")
    func nameFirst() {
        #expect(SyntaxLanguage.forFile(named: "gradlew", text: "#!/bin/sh\n") == .shell)
        #expect(SyntaxLanguage.forFile(named: "pydoc3", text: "#!/usr/bin/env python3\n") == .python)
        #expect(SyntaxLanguage.forFile(named: "build.py", text: "#!/bin/sh\n") == .python)
        #expect(
            SyntaxLanguage.forFile(named: "Makefile", text: "#!/usr/bin/env python3\n") == .makefile
        )
        #expect(SyntaxLanguage.forFile(named: "VERSION", text: "1.0.10\n") == nil)
    }

    @Test("a first line with no break is read only as far as the limit")
    func unbrokenFirstLine() {
        let long = "#!/bin/sh " + String(repeating: "x", count: 4 * 1024 * 1024)
        #expect(SyntaxLanguage.forShebang(in: long) == .shell)
        let noName = "#!" + String(repeating: " ", count: 2000) + "/bin/sh\n"
        #expect(SyntaxLanguage.forShebang(in: noName) == nil)
    }
}
