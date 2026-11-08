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
///   successful copy and delivers nothing. So a rewrite is one way: the board starts as
///   ``Board/promises`` and leaves that state for good the first time the pointer is over another app.
/// - **A lazy type is answered once.** The pasteboard keeps whatever came back, an empty answer
///   included, so an app that was told "nothing" has to be given a fresh board before it can be told
///   anything else. And Chromium reads only on entry, so it has to leave and come back to see it.
/// - **Holding the answer freezes both ends.** The receiving app is blocked in the read and the drag
///   image stops following the pointer, and a release during the hold comes out refused. It works, and
///   it is what makes an ordinary file feel like an ordinary drag, so it is bounded by ``holdLimit``
///   and given up as soon as the pointer leaves that app.
/// - **A folder is two different things**, itself for Finder and a zip of itself for any other app,
///   because Gmail and the rest of Chromium take a dropped file and fail on a folder. A rewritten
///   board serves whoever reads it, so a drag holding a folder rewrites it again whenever the pointer
///   moves between Finder and another app (``Audience``). Measured 2026-11-08 with a throwaway drag
///   source: a board rewritten to a lazy zip URL over another app and back to the folder's own URL
///   over Finder dropped the folder into Finder, not the zip.
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
        /// Finder and its desktop. Takes the promise, so nothing is fetched for it until it is dropped.
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

    /// What the drag's board currently holds for the rows on a server.
    public enum Board: Sendable, Equatable {
        /// The session's own file promises, as the drag began.
        case promises
        /// `public.file-url` declared, and answered when somebody reads it.
        case lazyFileURLs
        /// Real file URLs, written outright because the bytes are here.
        case fileURLs
    }

    /// How far the bytes have got.
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
        /// Start bringing the bytes down.
        case startTransfer
        /// Call the transfer off, removing whatever part of it arrived.
        case stopTransfer
    }

    /// Who the board's rows were last written for.
    ///
    /// The same for both until a row is offered differently to Finder, which only a folder is
    /// (``init(finderHasItsOwnBoard:)``).
    public enum Audience: Sendable, Equatable {
        /// Finder, which takes a folder as itself.
        case finder
        /// Every other app, which is handed a zip of a folder.
        case otherApps
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

    public private(set) var board: Board = .promises
    public private(set) var transfer: Transfer = .notStarted
    /// Who the board was last written for. Meaningful once it has left ``Board/promises``, which only
    /// another app makes it do.
    public private(set) var audience: Audience = .otherApps

    /// Whether Finder is offered something other than what the rest are, so the board is written
    /// again each time the pointer crosses between the two.
    private let finderHasItsOwnBoard: Bool

    /// The answer this board has given, which every other row of it has to share. All of them or
    /// none: a drop of three that quietly attached two is worse than a refusal.
    private var answer: Answer?
    /// Who was told ``Answer/nothing``, so a different app can be given a board of its own.
    private var refusedProcessID: Int32?

    /// `finderHasItsOwnBoard` is whether a row reaches Finder as something other than what every
    /// other app gets: a folder, which is a zip everywhere but Finder (`DragOutRoute.zipsForOtherApps`).
    /// Without one, Finder reads the same rewritten board as everybody else, as it always has.
    public init(finderHasItsOwnBoard: Bool = false) {
        self.finderHasItsOwnBoard = finderHasItsOwnBoard
    }

    /// The pointer is over `surface`. Called as it moves, so it has to come out as no effects almost
    /// always, and it has to run before that app reads the board: the move arrives first, 6 ms ahead
    /// of the read in Teams.
    public mutating func pointerMoved(over surface: Surface) -> [Effect] {
        guard let processID = surface.processID else { return [] }
        switch board {
        case .promises:
            guard case .otherApp = surface else { return [] }
            board = .lazyFileURLs
            audience = .otherApps
            answer = nil
            guard transfer == .notStarted else { return [.writeLazyFileURLs] }
            transfer = .running
            return [.writeLazyFileURLs, .startTransfer]
        case .lazyFileURLs:
            if let rewrite = changeAudience(for: surface) { return rewrite }
            // An app that was already told "nothing" keeps that answer until the bytes land, when it
            // has to leave and come back. A different app gets its own chance to wait.
            guard answer == .nothing, refusedProcessID != processID, transfer == .running else {
                return []
            }
            answer = nil
            refusedProcessID = nil
            return [.writeLazyFileURLs]
        case .fileURLs:
            return changeAudience(for: surface) ?? []
        }
    }

    /// Write the board again for whoever `surface` belongs to, when that is a different audience
    /// from the one it was written for and the drag has a row the two are offered differently.
    ///
    /// The new board answers afresh, so Finder gets a wait of its own after another app was told
    /// "nothing". It is written whatever became of the transfer, since a folder on this disk reaches
    /// Finder as itself and needs nothing the transfer was making.
    private mutating func changeAudience(for surface: Surface) -> [Effect]? {
        guard finderHasItsOwnBoard else { return nil }
        let wanted: Audience = if case .finder = surface { .finder } else { .otherApps }
        guard wanted != audience else { return nil }
        audience = wanted
        refusedProcessID = nil
        guard transfer == .landed else {
            board = .lazyFileURLs
            answer = nil
            return [.writeLazyFileURLs]
        }
        board = .fileURLs
        answer = .fileURLs
        return [.writeFileURLs]
    }

    /// An app is reading `public.file-url` from one of the board's rows.
    public mutating func readFileURL(from surface: Surface) -> Answer {
        if let answer { return answer }
        switch transfer {
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
        guard answer == nil, transfer == .running else { return }
        refuse(surface)
    }

    /// Every row's bytes are on this Mac.
    ///
    /// A board that has already told somebody "nothing" cannot change its answer, so it is replaced.
    /// One that has not simply answers the next read with the file.
    public mutating func transferLanded() -> [Effect] {
        transfer = .landed
        guard board == .lazyFileURLs, answer == .nothing else { return [] }
        board = .fileURLs
        answer = .fileURLs
        return [.writeFileURLs]
    }

    public mutating func transferFailed() {
        transfer = .failed
    }

    /// The drag is over. `mayFinish` is whether a transfer still running may go on unasked, so that a
    /// second try at the same drop is immediate.
    public mutating func dragEnded(mayFinish: Bool) -> [Effect] {
        guard transfer == .running, !mayFinish else { return [] }
        return [.stopTransfer]
    }

    private mutating func refuse(_ surface: Surface) {
        answer = .nothing
        refusedProcessID = surface.processID
    }
}
