import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// ⌥F5 with an end that is not on this Mac, and ⏎ on an archive that is not either — against a real
/// server, through the real `sftp` (PLAN.md §M24 Slice 6).
///
/// Every claim here is about bytes crossing a network and then reaching a **subprocess**, which the
/// headless suites deliberately cannot see: `PackRunnerTests` proves the runner's rules against an
/// in-memory store that never spawns anything, and `ArchivePackingTests` proves the argv without
/// running `bsdtar` at all. Neither can say whether `bsdtar` really honours a `-C` per source, or
/// whether an archive built here really lands on a server intact.
///
/// The three halves are deliberately asymmetric in what they check, because they can fail in
/// different directions: the **source** half is checked by extracting the archive and comparing
/// bytes, the **destination** half by an *independent* download rather than by asking the writer
/// what it wrote, and the **browse** half by listing the mount.
///
/// Gated on the same config file as `SFTPLiveIntegrationTests`, which is what keeps it out of CI.
/// Every fixture it needs is minted by the test that needs it, so the account only has to be
/// reachable and writable — nothing has to be hand-placed on it first.
@Suite("Pack live integration", .serialized, .enabled(if: SFTPLiveEnvironment.current != nil))
struct PackLiveIntegrationTests {
    private func backend() throws -> (SFTPBackend, SFTPLiveEnvironment.Config) {
        let config = try #require(SFTPLiveEnvironment.current)
        let transport = SFTPProcessTransport(
            location: config.location,
            authentication: .key(identityFile: config.identityFile)
        )
        return (SFTPBackend(location: config.location, transport: transport), config)
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-pack-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Mints the two source objects this suite packs, in a scratch subtree of their own.
    ///
    /// They used to be *assumed* to sit at `remotePath` — an unstated precondition, so against a
    /// server nobody had hand-prepared the `stat` threw and the failure read as a broken pack
    /// rather than as a missing fixture. Minting them here also keeps the suite independent of its
    /// neighbours, which every sibling live suite already achieves with a UUID-named subtree.
    ///
    /// Returns the payloads as well as the directory, because the archive has to be checked
    /// against the bytes that were uploaded rather than against anything read back over the same
    /// transport that wrote them.
    private func provisionSources(
        _ backend: SFTPBackend, _ config: SFTPLiveEnvironment.Config
    ) throws -> (directory: VFSPath, payloads: [String: String]) {
        let base = VFSPath(backend: config.location.backendID, path: config.remotePath)
        let directory = base.appending("dirnex-pack-src-\(UUID().uuidString)")
        try backend.createDirectory(at: directory)

        let staging = try scratch()
        defer { try? FileManager.default.removeItem(at: staging) }

        var payloads: [String: String] = [:]
        for name in ["alpha.txt", "beta.txt"] {
            let payload = "\(name) for the live pack probe \(UUID().uuidString)"
            let local = staging.appendingPathComponent(name)
            try Data(payload.utf8).write(to: local)
            try backend.copyFile(
                at: .local(local.path),
                to: directory.appending(name),
                progress: { _ in },
                isCancelled: { false }
            )
            payloads[name] = payload
        }
        return (directory, payloads)
    }

    // MARK: - Sources on a server

    @Test("two objects staged from a server pack into one archive, each from its own directory")
    func packsStagedRemoteSources() async throws {
        // Off the cooperative pool: every verb below blocks on a subprocess for a real network
        // round trip, which a test body may not do — see ``offCooperativePool``.
        try await offCooperativePool {
            let (backend, config) = try backend()
            let staging = try scratch()
            defer { try? FileManager.default.removeItem(at: staging) }
            let (remoteDirectory, payloads) = try provisionSources(backend, config)
            defer { try? backend.removeItem(at: remoteDirectory) }

            // Exactly the layout `MaterializeRunner` produces: one directory per object, keeping
            // its real name — which is what makes `bsdtar -C` per source necessary at all.
            var sources: [PackSource] = []
            for name in ["alpha.txt", "beta.txt"] {
                let entry = try backend.stat(at: remoteDirectory.appending(name))
                let file = try MaterializeRunner.materialize(
                    entry, intoDirectory: staging.path, using: backend
                )
                let url = URL(fileURLWithPath: file.localPath)
                sources.append(
                    PackSource(
                        directory: url.deletingLastPathComponent().path, name: url.lastPathComponent
                    )
                )
            }
            // Two *different* directories, which is the premise the whole slice rests on.
            #expect(Set(sources.map(\.directory)).count == 2)

            let archive = staging.appendingPathComponent("out.zip").path
            try ArchivePacker.pack(
                sources: sources, toArchiveAt: archive, format: .zip, level: .normal
            )

            // Read back through `bsdtar` itself rather than through anything that built it: the
            // bytes have to be the server's, under the names the user marked, with no trace of the
            // per-object directories they were staged in.
            let extraction = try ArchiveExtractor.extract(
                innerPaths: ["alpha.txt", "beta.txt"], fromArchiveAt: archive
            )
            #expect(extraction.extractedPaths.count == 2)
            let out = URL(fileURLWithPath: extraction.extractedPaths[0]).deletingLastPathComponent()
            // Against the payloads that were uploaded, never against a local file at the *remote*
            // path: the old spelling read `config.remotePath` through `String(contentsOfFile:)`,
            // which is a local read of a server path and so only ever held while the server was
            // this Mac. Against a genuinely remote account it threw, failing a pack that worked.
            for name in ["alpha.txt", "beta.txt"] {
                #expect(
                    try String(
                        contentsOfFile: out.appendingPathComponent(name).path, encoding: .utf8
                    ) == payloads[name]
                )
            }
        }
    }

    // MARK: - A destination on a server

    @Test("an encrypted archive built here lands on the server intact")
    func uploadsTheFinishedArchive() async throws {
        try await offCooperativePool {
            let (backend, config) = try backend()
            let staging = try scratch()
            defer { try? FileManager.default.removeItem(at: staging) }
            try Data("packed from this Mac".utf8)
                .write(to: staging.appendingPathComponent("payload.txt"))

            let name = "live-\(UUID().uuidString.prefix(8)).zip"
            let target = VFSPath(
                backend: config.location.backendID,
                path: (config.remotePath as NSString).appendingPathComponent(String(name))
            )
            let job = PackJob(
                sources: [PackSource(directory: staging.path, name: "payload.txt")],
                archive: target,
                encryption: .aes256,
                passphrase: ArchivePassphrase("live probe passphrase")
            )
            let report = PackRunner.run(
                FileOperation(
                    kind: .pack(job), sources: [], destinationDirectory: target.parent ?? target
                ),
                using: backend
            )
            #expect(report.succeeded)

            // The independent read: a fresh download rather than asking the writer what it wrote,
            // and it is what proves the transfer rather than the writer agreeing with itself.
            let back = staging.appendingPathComponent("downloaded.zip")
            let entry = try backend.stat(at: target)
            try backend.copyFile(
                at: target,
                to: .local(back.path),
                expectedSize: entry.byteSize,
                progress: { _ in },
                isCancelled: { false }
            )
            defer { try? backend.removeItem(at: target) }

            let inspection = try EncryptedArchiveReader.inspect(archiveAt: back.path)
            #expect(inspection.needsPassphrase)
            #expect(inspection.entries.map(\.archivePath) == ["payload.txt"])
            let out = staging.appendingPathComponent("unpacked", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            _ = try EncryptedArchiveReader.extract(
                archiveAt: back.path,
                into: out.path,
                passphrase: ArchivePassphrase("live probe passphrase")
            )
            #expect(
                try String(
                    contentsOfFile: out.appendingPathComponent("payload.txt").path,
                    encoding: .utf8
                )
                    == "packed from this Mac"
            )
            // And nothing of it is left in the temp root — the half nobody would ever report.
            let holders = try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())
            #expect(
                !holders.contains {
                    FileManager.default.fileExists(
                        atPath: (NSTemporaryDirectory() as NSString)
                            .appendingPathComponent($0 + "/" + name)
                    )
                }
            )
        }
    }

    // MARK: - Browsing one

    @Test("a .zip on the server comes down whole and lists its members")
    func browsesARemoteArchive() async throws {
        try await offCooperativePool {
            let (backend, config) = try backend()
            let staging = try scratch()
            defer { try? FileManager.default.removeItem(at: staging) }

            // Built here and uploaded, rather than assumed to be on the server: a hand-placed
            // `backup.zip` holding exactly these two members is an unstated precondition, and its
            // absence fails as a broken browse.
            let members = staging.appendingPathComponent("members", isDirectory: true)
            try FileManager.default.createDirectory(at: members, withIntermediateDirectories: true)
            for name in ["one.txt", "two.txt"] {
                try Data("\(name) in the live browse probe".utf8)
                    .write(to: members.appendingPathComponent(name))
            }
            let built = staging.appendingPathComponent("backup.zip").path
            try ArchivePacker.pack(
                sources: ["one.txt", "two.txt"].map {
                    PackSource(directory: members.path, name: $0)
                },
                toArchiveAt: built,
                format: .zip,
                level: .normal
            )

            let archiveName = "dirnex-pack-browse-\(UUID().uuidString.prefix(8)).zip"
            let remote = VFSPath(
                backend: config.location.backendID,
                path: (config.remotePath as NSString).appendingPathComponent(archiveName)
            )
            try backend.copyFile(
                at: .local(built),
                to: remote,
                progress: { _ in },
                isCancelled: { false }
            )
            defer { try? backend.removeItem(at: remote) }

            let file = try MaterializeRunner.materialize(
                try backend.stat(at: remote), intoDirectory: staging.path, using: backend
            )

            // The mount is the ordinary one once the bytes are here, which is the whole shape of the
            // feature: fetch the file, then browse the copy.
            let mount = VFSPath(backend: .archive(forArchiveAt: file.localPath), path: "/")
            let toc = try ArchiveMounter.readTableOfContents(ofArchiveAt: file.localPath)
            let names = try ArchiveBackend(archiveOnDiskPath: file.localPath, toc: toc)
                .listDirectory(at: mount)
                .map(\.name)
                .sorted()
            #expect(names == ["one.txt", "two.txt"])
        }
    }
}
