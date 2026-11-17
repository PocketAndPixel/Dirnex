import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// What the copy and move dialog reads from the jobs it follows (PLAN.md §M41): one phase, and the
/// sums a keeping-folders copy needs since it is one job per folder.
@Suite("Copy dialog state")
struct TransferDialogStateTests {
    @Test("bytes and files add up over the jobs, and the running job names the file")
    func sumsOverJobs() {
        let file = VFSPath.local("/src/folder/one.bin")
        let jobs = [
            Self.job(.finished, bytes: (100, 100), files: (2, 2)),
            Self.job(
                .running,
                bytes: (50, 200),
                files: (1, 4),
                current: .init(file, done: 30, size: 60)
            )
        ]

        let state = TransferDialogState.read(jobs, tracked: 2, isSubmitting: false)

        #expect(state.phase == .running)
        #expect(state.totalBytes == 300)
        #expect(state.completedBytes == 150)
        #expect(state.totalFiles == 6)
        #expect(state.completedFiles == 3)
        #expect(state.currentFile == file)
        #expect(state.currentFileFraction == 0.5)
        #expect(state.fraction == 0.5)
    }

    /// A job reads `.waiting` for an instant between being queued and starting. Said as "waiting
    /// its turn" on every copy, that would flash; it is only true while something else is running.
    @Test("a waiting job reads as waiting only behind other work, and as paused in a paused queue")
    func waitingNeedsOthers() {
        let jobs = [Self.job(.waiting)]
        #expect(TransferDialogState.read(jobs, tracked: 1, isSubmitting: false).phase == .preparing)
        #expect(TransferDialogState.read(
            jobs, tracked: 1, isSubmitting: false, queue: .init(othersActive: true)
        ).phase == .waiting)
        #expect(TransferDialogState.read(
            jobs, tracked: 1, isSubmitting: false, queue: .init(isPaused: true)
        ).phase == .paused)
    }

    /// The queue drops finished jobs once it drains, so "done" is read from the last snapshot of each
    /// job, and only once every job the transfer will queue has been seen to end.
    @Test("done only when every tracked job has been seen to end and no more are coming")
    func doneNeedsEveryJob() {
        let finished = [Self.job(.finished, bytes: (10, 10))]
        #expect(TransferDialogState.read(finished, tracked: 1, isSubmitting: false).phase == .done)
        #expect(
            TransferDialogState.read(finished, tracked: 1, isSubmitting: true).phase == .preparing
        )
        #expect(
            TransferDialogState.read(finished, tracked: 2, isSubmitting: false).phase == .preparing
        )
        #expect(
            TransferDialogState.read([], tracked: 0, isSubmitting: false).phase == .done,
            "a transfer that queued nothing is over"
        )
        #expect(TransferDialogState.read(finished, tracked: 1, isSubmitting: false).fraction == 1)
    }

    @Test("the dialog's Pause reads Resume only when every unfinished job is paused on its own")
    func heldNeedsEveryOpenJob() {
        let held = Self.job(.paused, held: true)
        let parkedByTheBar = Self.job(.paused)
        let done = Self.job(.finished)

        #expect(TransferDialogState.read([held, done], tracked: 2, isSubmitting: false).isHeld)
        #expect(
            !TransferDialogState.read([held, parkedByTheBar], tracked: 2, isSubmitting: false).isHeld
        )
        #expect(
            TransferDialogState.read([held, parkedByTheBar], tracked: 2, isSubmitting: false).phase == .paused
        )
        #expect(!TransferDialogState.read([done], tracked: 1, isSubmitting: false).isHeld)
    }

    /// A copy of empty files moves no bytes; its bar goes by files instead of sitting at zero.
    @Test("with no bytes to move the bar goes by files")
    func filesWhenNoBytes() {
        let state = TransferDialogState.read(
            [Self.job(.running, bytes: (0, 0), files: (3, 4))], tracked: 1, isSubmitting: false
        )
        #expect(state.fraction == 0.75)
    }

    // MARK: - Fixtures

    /// The file a job is writing, for the fixture below.
    struct Writing {
        let path: VFSPath
        let done: Int64
        let size: Int64

        init(_ path: VFSPath, done: Int64 = 0, size: Int64 = 1) {
            self.path = path
            self.done = done
            self.size = size
        }
    }

    static func job(
        _ status: JobStatus,
        bytes: (done: Int64, total: Int64) = (0, 0),
        files: (done: Int, total: Int)? = nil,
        current: Writing? = nil,
        held: Bool = false
    ) -> JobSnapshot {
        let progress = OperationProgress(
            totalBytes: bytes.total,
            completedBytes: bytes.done,
            totalItems: 1,
            completedItems: status == .finished ? 1 : 0,
            currentItem: current?.path,
            files: files.map {
                TransferFiles(
                    total: $0.total,
                    completed: $0.done,
                    current: current?.path,
                    currentCompletedBytes: current?.done ?? 0,
                    currentTotalBytes: current?.size ?? 0
                )
            }
        )
        let report = status == .finished || status == .cancelled
            ? OperationReport(
                completedItems: 1,
                completedBytes: bytes.done,
                skipped: [],
                failures: [],
                wasCancelled: status == .cancelled
            )
            : nil
        return JobSnapshot(
            id: OperationJobID(),
            kind: .copy,
            status: status,
            progress: status == .waiting ? nil : progress,
            report: report,
            isHeld: held
        )
    }
}

/// The dialog's new words, compiled into every language the app ships (PLAN.md §M41).
///
/// Read through each `.lproj` the build produced rather than the catalog, the way
/// `MaterializeTitleCountTests` does, so a plural form that does not compile, or a translation that
/// dropped its placeholder, fails here rather than on a translated screen.
@Suite("Copy dialog words")
struct TransferDialogWordsTests {
    static let counted = ["Copy %lld items to:", "Move %lld items to:"]

    @Test("the counted questions take each language's plural forms", arguments: counted)
    func plurals(key: String) {
        let one = Self.rendered(key, [1])
        let few = Self.rendered(key, [3])
        let many = Self.rendered(key, [5])
        #expect(one.count >= 14, "\(one.keys.sorted())")
        // Russian and Polish have a form for 3 that is not the form for 5; the catalog has to know it.
        #expect(few["ru"]?.contains("объекта") == true, "\(few["ru"] ?? "nil")")
        #expect(many["ru"]?.contains("объектов") == true, "\(many["ru"] ?? "nil")")
        #expect(one["ru"]?.contains("1 объект ") == true, "\(one["ru"] ?? "nil")")
        #expect(one["en"]?.contains("1 item ") == true, "\(one["en"] ?? "nil")")
        for (language, text) in one.merging(few, uniquingKeysWith: { $1 }) {
            #expect(!text.contains("%"), "\(language): \(text)")
        }
    }

    @Test("every new line with a placeholder keeps it in every language", arguments: [
        "Copy “%@” to:", "Move “%@” to:", "Copying to “%@”", "Moving to “%@”"
    ])
    func namesSurvive(key: String) {
        let all = Self.renderedText(key, "Backup")
        #expect(all.count >= 14, "\(all.keys.sorted())")
        for (language, text) in all {
            #expect(text.contains("Backup"), "\(language): \(text)")
        }
    }

    @Test("the file count keeps both numbers in every language")
    func fileCount() {
        let all = Self.rendered("Files: %lld of %lld", [34, 340])
        #expect(all.count >= 14, "\(all.keys.sorted())")
        for (language, text) in all {
            #expect(text.contains("34") && text.contains("340"), "\(language): \(text)")
        }
    }

    private static func rendered(_ key: String, _ counts: [Int]) -> [String: String] {
        format(key) { format, language in
            String(
                format: format,
                locale: Locale(identifier: language),
                arguments: counts.map { $0 as any CVarArg }
            )
        }
    }

    private static func renderedText(_ key: String, _ text: String) -> [String: String] {
        format(key) { format, language in
            String(
                format: format,
                locale: Locale(identifier: language),
                arguments: [text as NSString]
            )
        }
    }

    private static func format(_ key: String, _ fill: (String, String) -> String) -> [String: String] {
        let app = Bundle(for: PanelViewController.self)
        var out: [String: String] = [:]
        for lproj in app.paths(forResourcesOfType: "lproj", inDirectory: nil) {
            let language = (lproj as NSString).lastPathComponent.replacingOccurrences(
                of: ".lproj",
                with: ""
            )
            guard language != "Base", let bundle = Bundle(path: lproj) else { continue }
            let format = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            guard format != key || language == "en" else { continue }
            out[language] = fill(format, language)
        }
        return out
    }
}
