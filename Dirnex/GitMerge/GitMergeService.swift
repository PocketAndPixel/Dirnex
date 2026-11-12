import AppKit
import DirnexCore

/// The app's side of `git mergetool` (PLAN.md §M37 Slice 6): a request from `Dirnex --git-merge`
/// opens M34's merge window on the files git made, and the window's end answers the command.
///
/// Save writes `$MERGED` and nothing else. It keeps no undo copy, since git stages the file as soon
/// as the command exits, and it is git that decides the file is resolved. The command brings the app
/// to the front (`GitMergeClient`), which the app cannot do for itself.
@MainActor
final class GitMergeService {
    /// What a merge's end sends back to the command that asked for it.
    typealias Reply = @MainActor (GitMergeAnswer) -> Void
    /// Builds the window for a merge: the real one, or a test's that is never shown.
    typealias WindowOpener = @MainActor (MergeInput, MergeSaving) -> MergeWindowController
    /// Says why a merge did not open, and returns once that has been read.
    typealias Refuser = @MainActor (_ title: String, _ detail: String) async -> Void

    static let shared = GitMergeService(
        openWindow: { MergeWindowController.present($0, saving: $1) },
        refuse: GitMergeService.showRefusal
    )

    private let openWindow: WindowOpener
    private let refuse: Refuser
    private var listener: GitMergeListener?
    private(set) var sessions: [GitMergeSession] = []

    init(openWindow: @escaping WindowOpener, refuse: @escaping Refuser) {
        self.openWindow = openWindow
        self.refuse = refuse
    }

    /// Start listening. Once the browser window is up, so a merge window has one to center on. A
    /// request made earlier waits in the socket's queue.
    func start() {
        guard let support = GitMergeSocketLocation.supportDirectory, let path = GitMergeSocketLocation.path else {
            return
        }
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        do {
            listener = try GitMergeListener(path: path) { request, connection in
                Task { @MainActor in
                    await GitMergeService.shared.open(request) { answer in
                        Self.send(answer, over: connection)
                    }
                }
            }
        } catch {
            // The command waits out its time and says Dirnex didn't answer.
            NSLog("Dirnex couldn't listen for git mergetool: %@", error.reason)
        }
    }

    /// The app is quitting: every merge still open answers as it stands, so a result saved before
    /// ⌘Q still counts, and the socket goes.
    func stop() {
        for session in sessions {
            session.finish()
        }
        sessions = []
        listener?.stop()
        listener = nil
    }

    /// Read `request`'s files off the main thread, then open the merge window on them or say why
    /// not. `reply` runs exactly once, when the merge is over.
    func open(_ request: GitMergeRequest, reply: @escaping Reply) async {
        let read = await BlockingWork.run {
            GitMergeDocuments.read(request, transport: GitProcessTransport())
        }
        switch read {
        case let .success(documents):
            let session = GitMergeSession(reply: reply)
            let closed: @MainActor () -> Void = { [weak self, weak session] in
                guard let session else { return }
                session.finish()
                self?.sessions.removeAll { $0 === session }
            }
            let saving = MergeSaving(undo: { .none }, journal: { _ in }, closed: closed)
            sessions.append(session)
            session.controller = openWindow(
                GitMergeDocuments.mergeInput(for: request, documents),
                saving
            )
        case let .failure(failure):
            let detail = CompareOpener.failureDetail(failure)
            await refuse(PanelViewController.resolveFailureTitle(request.name), detail)
            reply(.refused(detail))
        }
    }

    /// Write `answer` to the command and hang up. A command that has gone, as after ⌃C, is nothing
    /// to report.
    private nonisolated static func send(
        _ answer: GitMergeAnswer,
        over connection: GitMergeSocketConnection
    ) {
        try? GitMergeWire.send(answer, over: connection)
        connection.close()
    }

    /// The alert Resolve Conflict… shows for the same refusal, over the browser window.
    private static func showRefusal(title: String, detail: String) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
        alert.offerFullDiskAccessSettings()
        let browser = (NSApp.delegate as? AppDelegate)?.activeBrowserWindowController?.window
        _ = await alert.runSheet(over: browser)
    }
}

/// One merge a command is waiting on.
@MainActor
final class GitMergeSession {
    /// Answered once, and `nil` after that.
    private var reply: GitMergeService.Reply?
    var controller: MergeWindowController?

    init(reply: @escaping GitMergeService.Reply) {
        self.reply = reply
    }

    /// Tell the command how the merge ended: saved if the window ever saved a result, whatever was
    /// chosen after that, since the file then holds a whole result.
    func finish() {
        guard let reply else { return }
        self.reply = nil
        reply(controller?.savedChoices != nil ? .saved : .notSaved)
    }
}

/// The versions `git mergetool` made, read for the merge window.
struct GitMergeDocuments: Sendable {
    let operation: GitOperation
    /// Whether the base holds anything. git writes an empty `$BASE` when both sides added the file.
    let hasBase: Bool
    let base: ComparedDocument
    let yours: ComparedDocument
    let theirs: ComparedDocument
    let target: ComparedFileSave.Target

    /// Read `request`'s files. `$MERGED` is stamped first, so a write during the read makes the
    /// save ask. A `$BASE` that isn't there is an empty base, as git's documentation allows. Blocking;
    /// call it off the main thread.
    nonisolated static func read(
        _ request: GitMergeRequest,
        transport: some GitTransport
    ) -> Result<GitMergeDocuments, CompareReadFailure> {
        let target = ComparedFileSave.Target.reading(request.merged)
        func document(_ path: String) throws(CompareReadFailure) -> ComparedDocument {
            do {
                return try ComparedDocument.read(contentsOf: URL(fileURLWithPath: path))
            } catch {
                throw CompareReadFailure(name: request.name, reason: error)
            }
        }
        do throws(CompareReadFailure) {
            let baseExists = FileManager.default.fileExists(atPath: request.base)
            let base = baseExists ? try document(request.base) : emptyBase
            let folder = VFSPath.local(request.merged).parent?.path ?? "/"
            return try .success(GitMergeDocuments(
                operation: GitConflictReader.operationInProgress(
                    at: folder,
                    transport: transport,
                    exists: { FileManager.default.fileExists(atPath: $0) }
                ),
                hasBase: !base.lines.isEmpty,
                base: base,
                yours: document(request.local),
                theirs: document(request.remote),
                target: target
            ))
        } catch {
            return .failure(error)
        }
    }

    /// An empty file decoded, which always succeeds.
    private nonisolated static var emptyBase: ComparedDocument {
        // swiftlint:disable:next force_try
        try! ComparedDocument.decode(Data())
    }

    /// What the window is opened on: Resolve Conflict…'s words for each side, since these are the
    /// same three versions, and the result saved over the working-tree file.
    nonisolated static func mergeInput(for request: GitMergeRequest, _ documents: GitMergeDocuments) -> MergeInput {
        let opening = documents.yours.text(ofFirstLines: SyntaxLanguage.contentsLineLimit)
        return MergeInput(
            name: request.name,
            base: MergeVersion(
                detail: documents.hasBase
                    ? PanelViewController.conflictBaseDetail
                    : PanelViewController.conflictNoBaseDetail,
                document: documents.base
            ),
            yours: MergeVersion(
                detail: PanelViewController.conflictYoursDetail(documents.operation),
                document: documents.yours
            ),
            theirs: MergeVersion(
                detail: PanelViewController.conflictTheirsDetail(documents.operation),
                document: documents.theirs
            ),
            target: documents.target,
            resultDetail: resultDetail,
            language: SyntaxLanguage.forFile(named: request.name, text: opening)
        )
    }

    /// The line under Result: git is waiting on the window, and saving alone does not end the wait.
    nonisolated static var resultDetail: String {
        String(
            localized: "Save, then close this window to go back to git",
            comment: """
            Merge window, under Result, when git mergetool opened it: git waits until the window closes. \
            git is a program's name, not to be translated.
            """
        )
    }
}
