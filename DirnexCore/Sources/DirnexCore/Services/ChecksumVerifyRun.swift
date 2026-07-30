import Foundation

/// The `.verify` half of a checksum job (PLAN.md §M14 Slice 2) — the primary half of the feature.
///
/// Most people never author a checksum file; they download one next to an ISO and want to know
/// whether the bytes survived. So this is the path that has to be tolerant of what other tools
/// wrote (`ChecksumManifest.parse` reads all six shapes the M14 probe captured, where `shasum -c`
/// refuses four of them) and honest about what it could not check.
///
/// The algorithm is never passed in: it comes out of the manifest, by a `MD5 (…)` label or by the
/// digest width, which is distinct for all four. A caller able to override it could verify a
/// SHA-256 file as MD5 and report every single line as a mismatch.
struct ChecksumVerifyRun {
    let context: ChecksumRunContext

    func execute(manifest: VFSPath) -> OperationReport {
        let manifestName = manifest.lastComponent
        let parsed: ChecksumManifest
        do {
            parsed = try read(manifest, named: manifestName)
        } catch let error as ChecksumError {
            return context.report(outcome: .failed(error))
        } catch {
            context.recordFailure(manifest, error)
            return context.report(outcome: nil)
        }

        let names = Set(parsed.entries.map(\.name))
        let walked = gather(manifestNames: names)
        let listing = ChecksumScope.comparableListing(
            walked: walked.map { ($0.name, $0.entry.isHidden) },
            manifestName: manifestName,
            manifestNames: names
        )
        let comparable = Set(listing)
        // Only files the manifest actually claims are hashed. The rest of the listing exists to
        // answer "extra", which costs a `stat` the walk already did and not one byte of reading.
        let claimed = walked.filter { names.contains($0.name) && comparable.contains($0.name) }
        context.measure(files: claimed)

        var computed: [String: ChecksumVerification.Computation] = [:]
        for file in claimed {
            guard !context.checkCancelled() else { return context.report(outcome: nil) }
            computed[file.name] = context.digest(of: file.entry, using: parsed.algorithm).computation
        }
        guard !context.checkCancelled() else { return context.report(outcome: nil) }
        return context.report(
            outcome: .verified(
                ChecksumVerification.verify(parsed, listing: listing, computed: computed)
            )
        )
    }

    /// Read and parse the checksum file.
    ///
    /// `impliedName` is what makes Total Commander's single-file `.crc` companion readable: its
    /// whole content is one bare hex number, so the name it describes exists nowhere but in the
    /// manifest's own file name (`disk.iso.crc` → `disk.iso`).
    private func read(_ manifest: VFSPath, named manifestName: String) throws -> ChecksumManifest {
        let data = try Data(contentsOf: URL(fileURLWithPath: manifest.path))
        return try ChecksumManifest.parse(
            data,
            implicitName: ChecksumManifest.impliedName(forManifestFileName: manifestName)
        )
    }

    /// Every regular file the manifest could be talking about, plus the siblings that make an
    /// `extra` verdict meaningful — pruned by `ChecksumScope` so a subtree the manifest never
    /// mentions is not walked at all.
    ///
    /// Sorted by name so a re-run's report diffs cleanly against the previous one; the walk's own
    /// order is directory-entry order, which is not stable across filesystems.
    private func gather(manifestNames: Set<String>) -> [ChecksumWalkedFile] {
        let root = context.job.root
        var found: [ChecksumWalkedFile] = []
        var stack: [VFSPath] = [root]
        while let directory = stack.popLast() {
            if context.isCancelled() { return found }
            for entry in (try? context.backend.listDirectory(at: directory)) ?? [] {
                guard let name = ChecksumScope.relativeName(of: entry.path, under: root) else {
                    continue
                }
                if ChecksumScope.shouldDescend(into: entry) {
                    if ChecksumScope.shouldDescend(
                        intoSubdirectory: name,
                        manifestNames: manifestNames
                    ) {
                        stack.append(entry.path)
                    }
                    continue
                }
                guard ChecksumScope.isHashable(entry) else { continue }
                found.append(ChecksumWalkedFile(name: name, entry: entry))
            }
        }
        return found.sorted { $0.name < $1.name }
    }
}
