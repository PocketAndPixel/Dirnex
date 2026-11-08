import AppKit
import DirnexCore

/// One file of the byte view.
struct BinaryCompareSide: Sendable {
    /// The file's name, for the window's title.
    let name: String
    /// Where the file is, as the user knows it, over its column.
    let detail: String
    /// The copy on this disk that is read.
    let path: VFSPath
}

/// Why two files are shown byte by byte rather than as text (PLAN.md §M37 Slice 2).
enum BinaryCompareReason: Equatable {
    /// `name` holds a NUL with no byte-order mark.
    case notText(name: String)
    /// No encoding reads `name` without loss.
    case undecodable(name: String)
    /// A file is past what the text window reads whole.
    case tooLarge

    /// The reason a file the text window could not read goes to the byte view, or `nil` when it
    /// could not be read at all, which no view of it would help.
    init?(_ failure: CompareReadFailure) {
        switch failure.reason {
        case .binary: self = .notText(name: failure.name)
        case .undecodable: self = .undecodable(name: failure.name)
        case .tooLarge: self = .tooLarge
        case .unreadable, .stopped: return nil
        }
    }
}

/// Two files side by side in hex at the same offset, of any size (PLAN.md §M37 Slice 2).
///
/// **The window is up before the scan ends.** It knows the two sizes when it opens, so it has its
/// rows, and each row reads its own page when drawn (`BinaryRowSource`). The differences arrive as
/// the scan finds them. Closing the window stops the scan.
///
/// One table holds both sides, so the two are level by construction, and it is the table that is
/// asked what is on screen. Read-only, and nothing here writes.
@MainActor
final class BinaryCompareWindowController: NSWindowController, NSWindowDelegate {
    /// What compares the two files: the real scan, or a test's. The two closures are the scan's
    /// report and its Stop.
    typealias Scanner = @Sendable (
        BinaryFilePair,
        @escaping @Sendable (BinaryComparison) -> Void,
        @escaping @Sendable () -> Bool
    ) throws -> BinaryComparison

    /// Windows on screen. A controller holds itself here until its window closes.
    private(set) static var open: [BinaryCompareWindowController] = []

    static let liveScanner: Scanner = { pair, report, isCancelled in
        try BinaryComparison.scan(pair, report: report, isCancelled: isCancelled)
    }

    let left: BinaryCompareSide
    let right: BinaryCompareSide
    let reason: BinaryCompareReason
    let pair: BinaryFilePair
    let rows: BinaryRowSource
    /// How many rows the table shows.
    let rowCount: Int
    /// How many digits the offset column shows.
    let offsetDigits: Int
    private let scanner: Scanner
    private let stop = CancellationFlag()

    /// What the scan has found so far, and at the end the whole answer.
    private(set) var comparison: BinaryComparison?
    /// Why the scan ended short, if it did.
    var scanFailure: (any Error)?
    /// Why a part of the files could not be shown, if one could not.
    var readFailure: (any Error)?
    /// The first byte of the change the counter names, or `nil` for none. An offset rather than a
    /// position in the list, since a list at its bound renumbers as it joins stretches.
    var currentChangeOffset: Int64?
    /// While the controller itself moves the selection, so that is not taken for the user's move.
    var isMovingSelection = false
    private var didOpenOnFirstChange = false

    let toolbar = CompareToolbar()
    let banner = NSTextField(wrappingLabelWithString: "")
    let scrollView = NSScrollView()
    let table = BinaryHexTable()
    let overview = CompareOverviewView()
    let offsetColumn = NSTableColumn(identifier: .init("offset"))
    let leftColumn = NSTableColumn(identifier: .init("left"))
    let rightColumn = NSTableColumn(identifier: .init("right"))
    var keyMonitor: Any?
    let modalLevel = ModalLevelKeeper()

    /// Open a window comparing the two files of `pair`.
    @discardableResult
    static func present(
        left: BinaryCompareSide,
        right: BinaryCompareSide,
        pair: BinaryFilePair,
        reason: BinaryCompareReason
    ) -> BinaryCompareWindowController {
        let controller = BinaryCompareWindowController(
            left: left,
            right: right,
            pair: pair,
            reason: reason
        )
        open.append(controller)
        controller.place()
        if let window = controller.window {
            controller.modalLevel.raise(window)
        }
        controller.showWindow(nil)
        controller.startScan()
        return controller
    }

    init(
        left: BinaryCompareSide,
        right: BinaryCompareSide,
        pair: BinaryFilePair,
        reason: BinaryCompareReason,
        rows: BinaryRowSource? = nil,
        scanner: @escaping Scanner = BinaryCompareWindowController.liveScanner
    ) {
        self.left = left
        self.right = right
        self.reason = reason
        self.pair = pair
        self.rows = rows ?? BinaryRowSource(pair: pair)
        self.scanner = scanner
        let largest = max(pair.leftByteSize, pair.rightByteSize)
        rowCount = min(
            Int(BinaryHexLayout.rowCount(forByteCount: largest)),
            BinaryCompareStyle.maximumRows
        )
        offsetDigits = BinaryHexLayout.offsetDigits(forByteCount: largest)
        // Not deferred, for the same reason as the compare window's: a window a test builds has to
        // lay out without being shown.
        let window = CompareWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.initialWidth(digits: offsetDigits),
                height: 720
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 320)
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        connectRows()
        showBanner()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Wide enough for the whole table, its scroller and the overview strip.
    private static func initialWidth(digits: Int) -> CGFloat {
        BinaryCompareStyle.offsetWidth(digits: digits) + 2 * BinaryCompareStyle.sideWidth
            + CompareOverviewView.width + 24
    }

    private func place() {
        guard let window else { return }
        let browser = (NSApp.delegate as? AppDelegate)?.activeBrowserWindowController?.window
        DialogWindowPlacement.place(window, key: "BinaryCompareWindow", centeredOver: browser)
    }

    // MARK: - Scanning

    func startScan() {
        let pair = pair
        let scanner = scanner
        let stop = stop
        let report: @Sendable (BinaryComparison) -> Void = { [weak self] partial in
            let owner = self
            Task { @MainActor in owner?.showPartial(partial) }
        }
        Task { [weak self] in
            let outcome = await BlockingWork.run {
                Result { try scanner(pair, report, { stop.isCancelled }) }
            }
            self?.finishScan(outcome)
        }
    }

    private func showPartial(_ partial: BinaryComparison) {
        guard comparison?.isFinished != true, scanFailure == nil else { return }
        show(partial)
    }

    private func finishScan(_ outcome: Result<BinaryComparison, any Error>) {
        switch outcome {
        case let .success(answer):
            show(answer)
        case let .failure(error) where error is CancellationError:
            break
        case let .failure(error):
            scanFailure = error
            showBanner()
            refreshCounter()
        }
    }

    /// Put what is known of the comparison on screen.
    func show(_ answer: BinaryComparison) {
        comparison = answer
        let kinds = Self.changeKinds(answer)
        overview.rowCount = rowCount
        overview.changeRows = answer.changeRows
        overview.kinds = kinds
        overview.needsDisplay = true
        showBanner()
        refreshCounter()
        openOnFirstChange()
    }

    /// Every stretch is a change; the bytes only one side has read as an insertion or a removal, as
    /// they would in the text window.
    static func changeKinds(_ answer: BinaryComparison) -> [CompareChangeKind] {
        var kinds = [CompareChangeKind](
            repeating: .change,
            count: answer.differences.stretches.count
        )
        if let side = answer.longerSide {
            kinds.append(side == .right ? .insertion : .removal)
        }
        return kinds
    }

    /// The window opens on the first difference, as the text window does, unless the user has
    /// already moved by the time the scan finds one.
    private func openOnFirstChange() {
        guard !didOpenOnFirstChange, let first = comparison?.changes.first else { return }
        didOpenOnFirstChange = true
        guard currentChangeOffset == nil, table.selectedRow <= 0, firstVisibleRow == 0 else { return }
        goToChange(at: first.lowerBound)
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        stop.isCancelled = true
        modalLevel.stop()
        removeKeyMonitor()
        Self.open.removeAll { $0 === self }
    }
}
