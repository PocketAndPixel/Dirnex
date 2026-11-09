import Foundation

/// What a drag of rows whose bytes are on a server offers, as the pointer travels over other apps.
///
/// Finder takes a file promise, and Teams, Slack, Chrome and VS Code cannot: Chromium's drop code
/// reads `public.file-url` and nothing that gets a promised file written, so a promise there is simply
/// refused (`PopulateDropDataFromPasteboard`, measured in Teams 2026-11-03). They want a real file,
/// and they want to know the moment the pointer enters. So one board cannot serve both, and each
/// fact below is one that ruled out the shorter design:
///
/// - **Finder may not be shown a file URL it cannot answer.** With a promise and a URL on one item it
///   reads the URL, 13 ms after the pointer arrives, and never touches the promise. An empty answer
///   does not fall back to the promise either: the drop is refused.
/// - **A promise only works as one of the session's own items.** Wrapped in another writer it is
///   refused, and written back to the board after a rewrite, even byte for byte, Finder reports a
///   successful copy and delivers nothing. So a rewrite is one way: the board starts
///   ``Board/asBegun`` and leaves that state for good the first time it has to.
/// - **A lazy type is answered once.** The pasteboard keeps whatever came back, an empty answer
///   included, so an app that was told "nothing" has to be given a fresh board before it can be told
///   anything else. And Chromium reads only on entry, so it has to leave and come back to see it.
/// - **Holding the answer freezes both ends.** The receiving app is blocked in the read and the drag
///   image stops following the pointer, and a release during the hold comes out refused. It works, and
///   it is what makes an ordinary file feel like an ordinary drag, so it is bounded by ``holdLimit``
///   and given up as soon as the pointer leaves that app.
/// - **A folder goes as itself, and as a zip of itself when Shift is held as the pointer enters an
///   app, whatever the app** (``Form``, 2026-11-09). Gmail answers "Attachment failed" for a folder,
///   while VLC and Finder take one, and no app tells a drag which it wants: Chrome accepts the folder
///   and only the page inside it fails. So the user chooses, holding the key no drag operation already
///   uses (⌥ copies, ⌘ moves, ⌃ makes an alias). **As the pointer enters**, because Teams and Chrome
///   drop what they read then: in six of Oleg's drops, logged, ⇧ went down over the app, the board was
///   rewritten to the zip and read again 30 ms later, and the drop still took the folder, while a drop
///   with ⇧ held from before the entry took the zip. So a change of Shift over the app the pointer is
///   already in changes nothing until it leaves and comes back.
///
/// Pure, like `Panel`: the caller performs the writes and the transfer and reports back, so every
/// one of these rules is testable without a drag session, which cannot be synthesized.
public struct RemoteDragHandoff: Sendable, Equatable {
    /// How long a read of the file URL may hold the app asking, waiting for the bytes to land.
    ///
    /// A policy number rather than a limit anything imposes: a lazy read held for 45 s came back
    /// fine. It is about how long a frozen app stays a hitch instead of a hang, and three seconds was
    /// measured to pass in Teams with the file attaching afterwards.
    public static let holdLimit: Duration = .seconds(3)

    /// What is under the pointer, as far as this drag is concerned.
    public enum Surface: Sendable, Equatable {
        /// Finder and its desktop. Takes the promise, so nothing is fetched for it until it is dropped,
        /// unless Shift asks for a folder's zip.
        case finder(processID: Int32)
        /// Any other application's window, which may only understand a file URL.
        case otherApp(processID: Int32)
        /// Dirnex itself, which reads its own payload, or the Dock, the menu bar and the like.
        case neutral

        /// Decide from what a window's owner says about itself.
        ///
        /// By *regular application* rather than by a list of the apps that want a URL, because that
        /// list is everything built on Chromium and has no end. A background helper never becomes a
        /// reason to start a download.
        public static func classify(
            processID: Int32,
            bundleIdentifier: String?,
            isRegularApp: Bool,
            ownProcessID: Int32
        ) -> Surface {
            if processID == ownProcessID { return .neutral }
            if bundleIdentifier == "com.apple.finder" { return .finder(processID: processID) }
            return isRegularApp ? .otherApp(processID: processID) : .neutral
        }

        fileprivate var processID: Int32? {
            switch self {
            case let .finder(processID), let .otherApp(processID): processID
            case .neutral: nil
            }
        }
    }

    /// What the drag's board currently holds for the rows that are handed off.
    public enum Board: Sendable, Equatable {
        /// What the drag began with: the session's own file promises for rows on a server or in an
        /// archive, and its own URL for a row on this disk.
        case asBegun
        /// `public.file-url` declared, and answered when somebody reads it.
        case lazyFileURLs
        /// Real file URLs, written outright because the bytes are here.
        case fileURLs
    }

    /// How far some work has got: the transfer, or the zips made after it.
    public enum Transfer: Sendable, Equatable {
        case notStarted
        case running
        case landed
        case failed
    }

    /// Something the caller has to do.
    public enum Effect: Sendable, Equatable {
        /// Replace the board with rows that answer `public.file-url` when read.
        case writeLazyFileURLs
        /// Replace the board with rows that carry their real file URLs.
        case writeFileURLs
        /// Start bringing the bytes down: files fetched or extracted, and a server's folders staged.
        case startTransfer
        /// Start making each folder's zip, from the folder on this disk or from its staged tree.
        case startCompression
        /// Call off whatever is running, removing whatever part of it arrived.
        case stopTransfer
    }

    /// What the board offers a folder as.
    ///
    /// The same for every row that is not a folder, so a drag without one never changes form.
    public enum Form: Sendable, Equatable {
        /// The folder itself: its own URL on this disk, a server's promise to Finder, or a server's
        /// tree once staged. What every app gets until Shift is held.
        case folders
        /// A zip of each folder, made when Shift is held as the pointer enters an app, Finder included.
        case zips
    }

    /// What to tell an app reading `public.file-url`.
    public enum Answer: Sendable, Equatable {
        /// The bytes are here: answer with the path.
        case fileURLs
        /// Answer with nothing, so this app is offered no file.
        case nothing
        /// The bytes are on their way: hold the read, then ask again.
        case wait
    }

    public private(set) var board: Board = .asBegun
    /// The files fetched or extracted, and a server's folders staged: what either form needs.
    public private(set) var transfer: Transfer = .notStarted
    /// The folders' zips, which only ``Form/zips`` needs, started once the transfer has landed,
    /// since a server's folder is zipped from its staged tree.
    public private(set) var compression: Transfer = .notStarted
    /// What the board was last written to offer a folder as.
    public private(set) var form: Form = .folders
    /// Whether the board was replaced after telling the app under the pointer "nothing", which that
    /// app only sees once the pointer leaves it and comes back.
    public private(set) var needsReentry = false

    /// Whether a row is a folder, so the board changes form with Shift.
    private let holdsFolders: Bool
    /// Whether the board began holding a promise, which an app other than Finder cannot read. Without
    /// one it already serves every app, as long as each folder goes as itself.
    private let beganWithPromises: Bool
    /// Set once the drag is over, after which nothing new is started.
    private var hasEnded = false

    /// The answer this board has given, which every other row of it has to share. All of them or
    /// none: a drop of three that quietly attached two is worse than a refusal.
    private var answer: Answer?
    /// Who was told ``Answer/nothing``, so a different app can be given a board of its own.
    private var refusedProcessID: Int32?
    /// The app the pointer is in, so a move within it is told from an entry, which is when Shift counts.
    private var enteredProcessID: Int32?

    /// `holdsFolders` is whether a row is a folder, which reaches an app as a zip while Shift is held
    /// (`DragOutRoute.zipsWithShift`). `beganWithPromises` is whether a row went
    /// out as a promise (`DragOutRoute.isPromised`); a drag of rows on this disk alone has none, and
    /// its board serves every app as it is until Shift asks for a zip.
    public init(holdsFolders: Bool = false, beganWithPromises: Bool = true) {
        self.holdsFolders = holdsFolders
        self.beganWithPromises = beganWithPromises
    }

    /// How far the work the board's current form needs has got: the transfer for ``Form/folders``,
    /// and the transfer and the zips together for ``Form/zips``.
    public var progress: Transfer {
        progress(for: form)
    }

    /// The pointer is over `surface`, with Shift held or not. Called as it moves, so it has to come
    /// out as no effects almost always, and it has to run before that app reads the board: the move
    /// arrives first, 6 ms ahead of the read in Teams. Shift counts only as the pointer enters an app.
    public mutating func pointerMoved(over surface: Surface, shiftHeld: Bool = false) -> [Effect] {
        guard let processID = surface.processID else {
            // Over Dirnex, the Dock or the menu bar the app the pointer left has seen it go, and coming
            // back is an entry.
            enteredProcessID = nil
            return []
        }
        let entering = processID != enteredProcessID
        enteredProcessID = processID
        let wanted = entering ? form(over: surface, shiftHeld: shiftHeld) : form
        switch board {
        case .asBegun:
            // Finder takes the board as it began, a promise included, and so does every other app when
            // nothing was promised, as long as each folder goes as itself.
            let servesAsBegun = if case .finder = surface { true } else { !beganWithPromises }
            guard !(servesAsBegun && wanted == .folders) else { return [] }
            form = wanted
            let starts = startWork()
            return rewrite() + starts
        case .lazyFileURLs:
            if let rewrite = changeForm(to: wanted) { return rewrite }
            // An app that was already told "nothing" keeps that answer until the bytes land, when it
            // has to leave and come back. A different app gets its own chance to wait.
            guard answer == .nothing, refusedProcessID != processID, progress == .running else {
                return []
            }
            answer = nil
            refusedProcessID = nil
            return [.writeLazyFileURLs]
        case .fileURLs:
            return changeForm(to: wanted) ?? []
        }
    }

    /// What a folder is offered as to an app the pointer enters: a zip while Shift is held, and the
    /// folder itself otherwise.
    private func form(over surface: Surface, shiftHeld: Bool) -> Form {
        guard holdsFolders, shiftHeld, surface != .neutral else { return .folders }
        return .zips
    }

    /// Write the board again for `wanted`, when that differs from what it was written for.
    ///
    /// The new board answers afresh, so an app told "nothing" in one form gets a wait of its own in
    /// the other. It is written whatever became of the work, since a folder on this disk goes as
    /// itself and needs nothing the work was making.
    private mutating func changeForm(to wanted: Form) -> [Effect]? {
        guard wanted != form else { return nil }
        form = wanted
        refusedProcessID = nil
        let starts = startWork()
        return rewrite() + starts
    }

    /// Replace the board for the current form: real URLs when its work is done, lazy ones otherwise.
    private mutating func rewrite() -> [Effect] {
        needsReentry = false
        guard progress == .landed else {
            board = .lazyFileURLs
            answer = nil
            return [.writeLazyFileURLs]
        }
        board = .fileURLs
        answer = .fileURLs
        return [.writeFileURLs]
    }

    /// Start what the current form needs and nothing has started yet. A zip waits for the transfer,
    /// which ``transferLanded()`` then starts it from.
    private mutating func startWork() -> [Effect] {
        var effects: [Effect] = []
        if transfer == .notStarted {
            transfer = .running
            effects.append(.startTransfer)
        }
        if form == .zips, compression == .notStarted, transfer == .landed {
            compression = .running
            effects.append(.startCompression)
        }
        return effects
    }

    private func progress(for form: Form) -> Transfer {
        guard form == .zips else { return transfer }
        if transfer == .failed || compression == .failed { return .failed }
        if transfer == .landed, compression == .landed { return .landed }
        return transfer == .notStarted ? .notStarted : .running
    }

    /// An app is reading `public.file-url` from one of the board's rows.
    public mutating func readFileURL(from surface: Surface) -> Answer {
        if let answer { return answer }
        switch progress {
        case .landed:
            answer = .fileURLs
            return .fileURLs
        case .failed:
            refuse(surface)
            return .nothing
        case .notStarted, .running:
            return .wait
        }
    }

    /// A held read ran out of ``holdLimit``, or the pointer left the app it was held for.
    public mutating func holdEnded(over surface: Surface) {
        guard answer == nil, progress == .running else { return }
        refuse(surface)
    }

    /// Every row's bytes are on this Mac. Starts the zips when the board is waiting for them.
    ///
    /// A board that has already told somebody "nothing" cannot change its answer, so it is replaced.
    /// One that has not simply answers the next read with the file.
    public mutating func transferLanded() -> [Effect] {
        transfer = .landed
        var effects: [Effect] = []
        if form == .zips, compression == .notStarted, !hasEnded {
            compression = .running
            effects.append(.startCompression)
        }
        return effects + replaceRefusedBoard()
    }

    public mutating func transferFailed() {
        transfer = .failed
    }

    /// Every folder's zip is made.
    public mutating func compressionLanded() -> [Effect] {
        compression = .landed
        return replaceRefusedBoard()
    }

    public mutating func compressionFailed() {
        compression = .failed
    }

    /// The real URLs, in place of a board that said "nothing" while its form's work was running.
    private mutating func replaceRefusedBoard() -> [Effect] {
        guard board == .lazyFileURLs, answer == .nothing, progress == .landed else { return [] }
        board = .fileURLs
        answer = .fileURLs
        needsReentry = true
        return [.writeFileURLs]
    }

    /// The drag is over. `mayFinish` is whether a transfer still running may go on unasked, so that a
    /// second try at the same drop is immediate. A zip never may: nothing keeps one for a second try.
    public mutating func dragEnded(mayFinish: Bool) -> [Effect] {
        hasEnded = true
        let stops = compression == .running || (transfer == .running && !mayFinish)
        return stops ? [.stopTransfer] : []
    }

    private mutating func refuse(_ surface: Surface) {
        answer = .nothing
        refusedProcessID = surface.processID
    }
}
