import Darwin
import Testing

@testable import Dirnex

@Suite("git merge tool: socket inheritance")
struct GitMergeSocketInheritanceTests {
    @Test("exec closes the socket before the child's program starts")
    func closesOnExec() async throws {
        let inherited = try await offCooperativePool {
            let descriptor = try #require(GitMergeSocket.make())
            defer { close(descriptor) }

            var attributes: posix_spawnattr_t?
            try #require(posix_spawnattr_init(&attributes) == 0)
            defer { posix_spawnattr_destroy(&attributes) }
            // Keep the child alive after exec, before it can close any descriptor itself.
            // No CLOEXEC_DEFAULT: that would hide a missing FD_CLOEXEC in our socket setup.
            try #require(posix_spawnattr_setflags(
                &attributes, Int16(POSIX_SPAWN_START_SUSPENDED)
            ) == 0)
            let program = try #require(strdup("/usr/bin/true"))
            defer { free(program) }
            let arguments: [UnsafeMutablePointer<CChar>?] = [program, nil]
            var child: pid_t = 0
            try #require(posix_spawn(
                &child, program, nil, &attributes, arguments, environ
            ) == 0)
            defer {
                kill(child, SIGKILL)
                var status: Int32 = 0
                while waitpid(child, &status, 0) < 0, errno == EINTR {}
            }

            var info = socket_fdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            let result = proc_pidfdinfo(child, descriptor, PROC_PIDFDSOCKETINFO, &info, size)
            // A failed inspection must mean the descriptor is absent, not lack of permission.
            let code = errno
            try #require(result == size || (result == 0 && code == EBADF))
            return result == size
        }
        #expect(!inherited)
    }
}
