import Foundation
import Testing

@testable import DirnexCore

@Suite("GitStatusEntry")
struct GitStatusEntryTests {
    private func entry(_ code: String, path: String = "f.txt") -> GitStatusEntry {
        let characters = Array(code)
        return GitStatusEntry(
            relativePath: path,
            indexStatus: characters[0],
            worktreeStatus: characters[1]
        )
    }

    @Test("whole-entry verdicts answer before the per-axis columns")
    func wholeEntryVerdicts() {
        #expect(entry("??").status == .untracked)
        #expect(entry("!!").status == .ignored)
    }

    @Test("every unmerged combination is a conflict")
    func unmergedIsConflict() {
        // Either side literally `U`, plus the both-added / both-deleted pairs.
        for code in ["UU", "AU", "UA", "DU", "UD", "AA", "DD"] {
            #expect(entry(code).status == .conflicted, "\(code) should be a conflict")
        }
    }

    @Test("the index column wins when something is staged")
    func indexColumnWins() {
        // A file staged as new and then edited again is more usefully "added" than "modified".
        #expect(entry("AM").status == .added)
        #expect(entry("RM").status == .renamed)
        #expect(entry("M ").status == .modified)
        #expect(entry("A ").status == .added)
        #expect(entry("R ").status == .renamed)
        #expect(entry("C ").status == .renamed)
    }

    @Test("the worktree column answers when nothing is staged")
    func worktreeColumnFallback() {
        #expect(entry(" M").status == .modified)
        #expect(entry(" D").status == .deleted)
        #expect(entry("  ").status == .unmodified)
    }

    @Test("a type change reads as a modification")
    func typeChangeIsModified() {
        // `T` — a file replaced by a symlink, say. A panel row has nothing better to say than "M".
        #expect(entry("T ").status == .modified)
        #expect(entry(" T").status == .modified)
    }

    @Test("a rename carries where it came from")
    func renameCarriesOrigin() {
        let renamed = GitStatusEntry(
            relativePath: "new.txt",
            indexStatus: "R",
            worktreeStatus: " ",
            originalPath: "old.txt"
        )
        #expect(renamed.status == .renamed)
        #expect(renamed.originalPath == "old.txt")
    }
}

@Suite("GitFileStatus")
struct GitFileStatusTests {
    @Test("codes are Git's own letters, and a clean file shows nothing")
    func statusCodes() {
        #expect(GitFileStatus.unmodified.code == nil)
        #expect(GitFileStatus.modified.code == "M")
        #expect(GitFileStatus.added.code == "A")
        #expect(GitFileStatus.deleted.code == "D")
        #expect(GitFileStatus.renamed.code == "R")
        #expect(GitFileStatus.untracked.code == "?")
        #expect(GitFileStatus.ignored.code == "!")
        #expect(GitFileStatus.conflicted.code == "U")
    }

    @Test("precedence ranks a conflict loudest and a clean file quietest")
    func rollupPrecedenceOrder() {
        // The ordering a directory's roll-up resolves ties by.
        #expect(GitFileStatus.conflicted.rollupPrecedence > GitFileStatus.modified.rollupPrecedence)
        #expect(GitFileStatus.modified.rollupPrecedence > GitFileStatus.added.rollupPrecedence)
        #expect(GitFileStatus.added.rollupPrecedence > GitFileStatus.untracked.rollupPrecedence)
        #expect(GitFileStatus.untracked.rollupPrecedence > GitFileStatus.ignored.rollupPrecedence)
        #expect(GitFileStatus.ignored.rollupPrecedence > GitFileStatus.unmodified.rollupPrecedence)
    }

    @Test("only actionable statuses colour their ancestors")
    func rollsUpToAncestors() {
        // An ignored file must not make its containing folder look ignored.
        #expect(!GitFileStatus.ignored.rollsUpToAncestors)
        #expect(!GitFileStatus.unmodified.rollsUpToAncestors)
        for status in [GitFileStatus.modified, .added, .deleted, .renamed, .untracked, .conflicted] {
            #expect(status.rollsUpToAncestors, "\(status) should roll up")
        }
    }

    @Test("only collapsed statuses are inherited by descendants")
    func inheritedByDescendants() {
        // Git emits one row for an untracked/ignored directory and says nothing about its contents,
        // so only those two can be inherited downwards.
        #expect(GitFileStatus.untracked.isInheritedByDescendants)
        #expect(GitFileStatus.ignored.isInheritedByDescendants)
        for status in [GitFileStatus.modified, .added, .deleted, .renamed, .conflicted, .unmodified] {
            #expect(!status.isInheritedByDescendants, "\(status) should not be inherited")
        }
    }
}
