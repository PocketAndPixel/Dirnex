import DirnexCore
import Foundation

/// Reads the byte view's pages as they are wanted, off the main thread (PLAN.md §M37 Slice 2).
///
/// A row is asked for while the table draws, on the main thread, and a file may be on a mount that
/// takes seconds to answer. So a row that is not held comes back `nil`, draws blank, and its page is
/// read in the background. **One read at a time, and only of a page still on screen**: dragging the
/// scroller across a file on a slow share would otherwise queue a read for every page it passed.
@MainActor
final class BinaryRowSource {
    /// A page is held and its rows can be drawn.
    var onLoad: ((Int64) -> Void)?
    /// A read failed. The rows stay blank.
    var onFailure: ((any Error) -> Void)?
    /// The pages on screen now, which is what decides whether a wanted page is still worth reading.
    var pagesOnScreen: () -> Set<Int64> = { [] }

    private let read: @Sendable (Int64) throws -> BinaryPage
    private var cache = BinaryPageCache()
    private var wanted: [Int64] = []
    private var failed: Set<Int64> = []
    /// The page being read now, which a second ask must not queue again.
    private var reading: Int64?

    init(read: @escaping @Sendable (Int64) throws -> BinaryPage) {
        self.read = read
    }

    convenience init(pair: BinaryFilePair) {
        self.init { try pair.page($0) }
    }

    /// Row `row` if its page is held, else `nil` and the page is on its way.
    func row(_ row: Int64) -> BinaryHexRow? {
        let index = BinaryPage.index(ofRow: row)
        if let page = cache.page(index) {
            return page.row(row)
        }
        request(index)
        return nil
    }

    private func request(_ index: Int64) {
        guard index != reading, !wanted.contains(index), !failed.contains(index) else { return }
        wanted.append(index)
        readNext()
    }

    private func readNext() {
        guard reading == nil else { return }
        let onScreen = pagesOnScreen()
        wanted.removeAll { !onScreen.contains($0) }
        guard let index = wanted.first else { return }
        wanted.removeFirst()
        reading = index
        let read = read
        Task { [weak self] in
            let outcome = await BlockingWork.run { Result { try read(index) } }
            self?.finish(index, outcome)
        }
    }

    private func finish(_ index: Int64, _ outcome: Result<BinaryPage, any Error>) {
        reading = nil
        switch outcome {
        case let .success(page):
            cache.insert(page)
            onLoad?(index)
        case let .failure(error):
            failed.insert(index)
            onFailure?(error)
        }
        readNext()
    }
}
