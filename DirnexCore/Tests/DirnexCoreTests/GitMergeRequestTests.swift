import Foundation
import Testing

@testable import DirnexCore

/// The command line of `Dirnex --git-merge` (PLAN.md §M37 Slice 6).
@Suite("git merge tool: the command line")
struct GitMergeRequestTests {
    private let binary = "/Applications/Dirnex.app/Contents/MacOS/Dirnex"
    private let top = "/Users/me/repo"

    private func request(_ paths: String...) -> GitMergeRequest? {
        GitMergeArguments.request(
            from: [binary, GitMergeArguments.flag] + paths,
            currentDirectory: top
        )
    }

    @Test("only the first argument asks for the command")
    func invocation() {
        #expect(GitMergeArguments.isInvocation([binary, "--git-merge", "a", "b", "c", "d"]))
        #expect(GitMergeArguments.isInvocation([binary, "--git-merge"]))
        #expect(!GitMergeArguments.isInvocation([binary]))
        #expect(!GitMergeArguments.isInvocation([]))
        #expect(!GitMergeArguments.isInvocation([binary, "-AppleLanguages", "(de)"]))
        #expect(
            !GitMergeArguments.isInvocation(
                [binary, "-AppleLanguages", "--git-merge", "a", "b", "c"]
            )
        )
        #expect(!GitMergeArguments.isInvocation([binary, "--git-merge-x", "a", "b", "c", "d"]))
    }

    @Test("what git passes comes out absolute, against the command's own folder")
    func relative() {
        #expect(
            request("./a_LOCAL_74127.txt", "./a_BASE_74127.txt", "./a_REMOTE_74127.txt", "a.txt") ==
                GitMergeRequest(
                    local: "/Users/me/repo/a_LOCAL_74127.txt",
                    base: "/Users/me/repo/a_BASE_74127.txt",
                    remote: "/Users/me/repo/a_REMOTE_74127.txt",
                    merged: "/Users/me/repo/a.txt"
                )
        )
    }

    @Test("a file in a subfolder keeps its folder")
    func subfolder() {
        #expect(
            request("./sub/a_LOCAL_1.txt", "./sub/a_BASE_1.txt", "./sub/a_REMOTE_1.txt", "sub/a.txt") ==
                GitMergeRequest(
                    local: "/Users/me/repo/sub/a_LOCAL_1.txt",
                    base: "/Users/me/repo/sub/a_BASE_1.txt",
                    remote: "/Users/me/repo/sub/a_REMOTE_1.txt",
                    merged: "/Users/me/repo/sub/a.txt"
                )
        )
    }

    @Test("an absolute path stays where it is")
    func absolute() {
        #expect(request("/t/l", "/t/b", "/t/r", "/w/m") ==
            GitMergeRequest(local: "/t/l", base: "/t/b", remote: "/t/r", merged: "/w/m"))
    }

    @Test("a dot between folders is dropped, and a double dot is left for the file system")
    func dots() {
        let made = request("a/./b", "././c", "d/../e", "/x/./y/../z")
        #expect(made?.local == "/Users/me/repo/a/b")
        #expect(made?.base == "/Users/me/repo/c")
        #expect(made?.remote == "/Users/me/repo/d/../e")
        #expect(made?.merged == "/x/y/../z")
    }

    @Test("a name with spaces, a dash or the flag's own spelling is still a path")
    func oddNames() {
        let made = request("./na me_LOCAL.txt", "-rf", "--git-merge", "sp ace.txt")
        #expect(made?.local == "/Users/me/repo/na me_LOCAL.txt")
        #expect(made?.base == "/Users/me/repo/-rf")
        #expect(made?.remote == "/Users/me/repo/--git-merge")
        #expect(made?.merged == "/Users/me/repo/sp ace.txt")
    }

    @Test("anything but four paths is no request", arguments: [0, 1, 3, 5])
    func wrongCount(count: Int) {
        let arguments = [binary, GitMergeArguments.flag] + Array(repeating: "a", count: count)
        #expect(GitMergeArguments.request(from: arguments, currentDirectory: top) == nil)
    }

    @Test("an empty path is no request", arguments: 0..<4)
    func emptyPath(position: Int) {
        var paths = ["a", "b", "c", "d"]
        paths[position] = ""
        let arguments = [binary, GitMergeArguments.flag] + paths
        #expect(GitMergeArguments.request(from: arguments, currentDirectory: top) == nil)
    }

    @Test("five paths are no request, even with one of them empty")
    func fiveWithAnEmptyOne() {
        let arguments = [binary, GitMergeArguments.flag, "a", "", "b", "c", "d"]
        #expect(GitMergeArguments.request(from: arguments, currentDirectory: top) == nil)
    }

    @Test("a relative path with no folder to be relative to is no request")
    func noWorkingDirectory() {
        let arguments = [binary, GitMergeArguments.flag, "a", "b", "c", "d"]
        #expect(GitMergeArguments.request(from: arguments, currentDirectory: "") == nil)
        let absolute = [binary, GitMergeArguments.flag, "/a", "/b", "/c", "/d"]
        #expect(GitMergeArguments.request(from: absolute, currentDirectory: "") != nil)
    }

    @Test("the arguments of some other command are no request")
    func notOurs() {
        let arguments = [binary, "--other", "a", "b", "c", "d"]
        #expect(GitMergeArguments.request(from: arguments, currentDirectory: top) == nil)
    }

    @Test("the file's name is the working-tree file's")
    func name() {
        #expect(request("./x", "./y", "./z", "sub/notes.txt")?.name == "notes.txt")
    }

    @Test("only a saved result exits 0")
    func exitCodes() {
        #expect(GitMergeAnswer.saved.exitCode == 0)
        #expect(GitMergeAnswer.notSaved.exitCode == 1)
        #expect(GitMergeAnswer.refused("no").exitCode == 1)
    }
}
