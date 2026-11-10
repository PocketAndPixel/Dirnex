import Foundation
import Testing

@testable import DirnexCore

@Suite("A one-shot secret pipe")
struct OneShotSecretPipeTests {
    private static let secret = Data("pässword with $pecial\n".utf8)

    private func withPipe(_ body: (OneShotSecretPipe) throws -> Void) throws {
        let directory = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("OneShotSecretPipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try body(OneShotSecretPipe(path: (directory as NSString).appendingPathComponent("secret")))
    }

    /// A real `cat` of the pipe: the same reader the askpass helper is.
    private func startReader(_ path: String) throws -> (Process, Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.arguments = [path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        return (process, output)
    }

    private func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    @Test("a reader gets the exact bytes")
    func readerGetsTheBytes() throws {
        try withPipe { pipe in
            let (reader, output) = try startReader(pipe.path)
            #expect(pipe.deliver(Self.secret, timeout: 10))
            #expect(output.fileHandleForReading.readDataToEndOfFile() == Self.secret)
            reader.waitUntilExit()
            #expect(reader.terminationStatus == 0)
        }
    }

    @Test("what sits on disk is a private pipe with nothing in it")
    func onDiskIsAPrivateEmptyPipe() throws {
        try withPipe { pipe in
            var info = stat()
            #expect(lstat(pipe.path, &info) == 0)
            #expect(info.st_mode & S_IFMT == S_IFIFO)
            #expect(info.st_mode & 0o777 == 0o600)
            #expect(info.st_size == 0)
        }
    }

    @Test("the pipe is gone once it has been read, so a second reader finds nothing")
    func goneAfterItsReader() throws {
        try withPipe { pipe in
            let (reader, output) = try startReader(pipe.path)
            #expect(pipe.deliver(Self.secret, timeout: 10))
            _ = output.fileHandleForReading.readDataToEndOfFile()
            reader.waitUntilExit()
            // A `#require`, because a reader of a pipe still standing would wait here forever.
            try #require(!exists(pipe.path))

            let (second, secondOutput) = try startReader(pipe.path)
            #expect(secondOutput.fileHandleForReading.readDataToEndOfFile().isEmpty)
            second.waitUntilExit()
            #expect(second.terminationStatus != 0)
        }
    }

    @Test("with no reader it gives up, and leaves nothing to wait on")
    func noReaderGivesUp() throws {
        try withPipe { pipe in
            #expect(!pipe.deliver(Self.secret, timeout: 0.1))
            #expect(!exists(pipe.path))
        }
    }

    @Test("cancelling stops the wait well before its limit")
    func cancellingStopsTheWait() throws {
        try withPipe { pipe in
            let started = ContinuousClock.now
            #expect(!pipe.deliver(Self.secret, timeout: 60, isCancelled: { true }))
            #expect(ContinuousClock.now - started < .seconds(30))
            #expect(!exists(pipe.path))
        }
    }

    @Test("a second pipe at the same path is refused")
    func existingPathIsRefused() throws {
        try withPipe { pipe in
            #expect(throws: POSIXError.self) { _ = try OneShotSecretPipe(path: pipe.path) }
        }
    }

    @Test("a reader that has left is a failed send, and does not end the process")
    func goneReaderIsAFailedSend() {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        close(descriptors[0])
        defer { close(descriptors[1]) }
        #expect(!OneShotSecretPipe.send(Self.secret, to: descriptors[1], until: .distantFuture))
    }
}
