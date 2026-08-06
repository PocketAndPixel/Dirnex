import Foundation

/// A sequence diagram, placed (PLAN.md §M18 ▸ Slice 4).
struct MermaidSequenceDrawing: Equatable {
    struct Participant: Equatable {
        let label: String
        let isActor: Bool
        /// The header box. The lifeline hangs from its bottom edge, down the middle.
        let frame: MermaidRect
    }

    struct Message: Equatable {
        /// Two points for an ordinary message, four for one a participant sends to itself — which
        /// is why this is a polyline rather than a pair. A self-message is the one case where the
        /// arrow has to leave the lifeline and come back.
        let points: [MermaidPoint]
        let text: String
        let style: MermaidSequence.MessageStyle
        /// The text's anchor. Above the line for an ordinary message, beside the loop for a self.
        let labelCentre: MermaidPoint
        let isSelf: Bool
    }

    struct Note: Equatable {
        let frame: MermaidRect
        let text: String
    }

    let width: Double
    let height: Double
    /// Where every lifeline ends — one value, because they all run to the bottom of the drawing.
    let lifelineBottom: Double
    let participants: [Participant]
    let messages: [Message]
    let notes: [Note]
    /// The narrow bars showing a participant is busy.
    let activations: [MermaidRect]
}

/// Placing a sequence diagram (PLAN.md §M18 ▸ Slice 4).
///
/// No layout algorithm, and that is the point — a sequence diagram is **positional**. Participants
/// take columns in the order they were declared and events take rows in the order they were
/// written, so the whole job is arithmetic: how wide each column has to be, and how far down each
/// row sits.
///
/// The one place it is not merely additive is column *separation*. A message's text sits between
/// two lifelines, so a long label pushes its columns apart — and a label spanning several columns
/// spreads that demand across every gap it crosses, rather than paying for it all at one.
enum MermaidSequenceLayout {
    private static let margin = 10.0
    private static let padX = 12.0
    private static let padY = 6.0
    private static let columnGap = 30.0
    private static let headerGap = 26.0
    private static let selfLoopWidth = 44.0
    private static let activationWidth = 10.0

    static func lay(
        out diagram: MermaidSequence,
        metric: MarkdownTextMetric
    ) -> MermaidSequenceDrawing {
        let boxHeight = metric.lineHeight + 2 * padY
        let widths = diagram.participants.map { max(metric.width($0.label) + 2 * padX, 56) }
        let centres = columns(diagram, widths: widths, metric: metric)
        let participants = zip(zip(diagram.participants, widths), centres).map { pair, centre in
            MermaidSequenceDrawing.Participant(
                label: pair.0.label,
                isActor: pair.0.isActor,
                frame: MermaidRect(
                    x: centre - pair.1 / 2,
                    y: margin,
                    width: pair.1,
                    height: boxHeight
                )
            )
        }
        var walker = Walker(
            centres: centres,
            index: Dictionary(
                uniqueKeysWithValues: diagram.participants.enumerated().map { ($1.id, $0) }
            ),
            metric: metric,
            cursor: margin + boxHeight + headerGap
        )
        for event in diagram.events { walker.read(event) }
        let bottom = walker.cursor + headerGap / 2
        // Hoisted out of the initializer below: it mutates the walker, and reading the other fields
        // in the same expression would be an exclusivity question nobody should have to answer.
        let activations = walker.close(at: bottom)
        return MermaidSequenceDrawing(
            width: max(
                (centres.last ?? 0) + (widths.last ?? 0) / 2 + margin,
                walker.rightReach + margin
            ),
            height: bottom + margin,
            lifelineBottom: bottom,
            participants: participants,
            messages: walker.messages,
            notes: walker.notes,
            activations: activations
        )
    }

    // MARK: - Columns

    /// Each participant's centre x.
    ///
    /// Two demands set a gap: the two header boxes must not touch, and any message label crossing
    /// that gap must fit. The second is spread across the gaps the message *spans*, so a wide label
    /// on a message from the first participant to the last widens the diagram evenly instead of
    /// tearing one pair apart.
    private static func columns(
        _ diagram: MermaidSequence,
        widths: [Double],
        metric: MarkdownTextMetric
    ) -> [Double] {
        guard !widths.isEmpty else { return [] }
        var gaps = [Double](repeating: 0, count: max(widths.count - 1, 0))
        for index in gaps.indices {
            gaps[index] = widths[index] / 2 + widths[index + 1] / 2 + columnGap
        }
        let index = Dictionary(
            uniqueKeysWithValues: diagram.participants.enumerated().map { ($1.id, $0) }
        )
        for case let .message(from, to, text, _) in diagram.events {
            guard let start = index[from], let end = index[to], start != end, !text.isEmpty else {
                continue
            }
            let span = abs(end - start)
            let needed = (metric.width(text) + 2 * padX) / Double(span)
            for gap in min(start, end)..<max(start, end) {
                gaps[gap] = max(gaps[gap], needed)
            }
        }
        var centres = [margin + widths[0] / 2]
        for gap in gaps { centres.append(centres[centres.count - 1] + gap) }
        return centres
    }

    // MARK: - Rows

    /// The downward walk over events, accumulating rows.
    ///
    /// A struct with a `cursor` rather than a fold, because every event's height depends on what it
    /// is — a self-message needs its loop, a note needs its box — and the next row starts wherever
    /// the last one finished.
    private struct Walker {
        let centres: [Double]
        let index: [String: Int]
        let metric: MarkdownTextMetric
        var cursor: Double
        var messages: [MermaidSequenceDrawing.Message] = []
        var notes: [MermaidSequenceDrawing.Note] = []
        var activations: [MermaidRect] = []
        /// Open activations, as a stack per participant: mermaid allows a participant to be
        /// activated twice and drawn as nested bars.
        var open: [Int: [Double]] = [:]
        /// The furthest right anything reached, which a self-loop or a note can push past the last
        /// lifeline.
        var rightReach = 0.0
        /// Where the last event was *drawn*, which is not where the cursor is: the cursor has
        /// already advanced to the next row. An activation bar has to be measured against the
        /// former, or it ends below the message that follows its `deactivate`.
        var lastRowY: Double?

        private var rowPitch: Double { metric.lineHeight * 2.4 }

        mutating func read(_ event: MermaidSequence.Event) {
            switch event {
            case let .message(from, to, text, style):
                message(from: from, to: to, text: text, style: style)
            case let .note(placement, participants, text):
                note(placement: placement, participants: participants, text: text)
            case let .activate(id):
                // The bar starts at the message that triggered it, a little above the line.
                if let column = index[id] {
                    open[column, default: []].append((lastRowY ?? cursor) - 6)
                }
            case let .deactivate(id):
                guard let column = index[id], var stack = open[column], let top = stack.popLast()
                else { return }
                open[column] = stack
                activations.append(bar(
                    column: column,
                    top: top,
                    bottom: (lastRowY ?? cursor) + 6,
                    depth: stack.count
                ))
            }
        }

        private mutating func message(
            from: String,
            to: String,
            text: String,
            style: MermaidSequence.MessageStyle
        ) {
            guard let start = index[from], let end = index[to] else { return }
            let y = cursor
            if start == end {
                let x = centres[start]
                let bottom = y + metric.lineHeight + 4
                messages.append(MermaidSequenceDrawing.Message(
                    points: [
                        MermaidPoint(x: x, y: y),
                        MermaidPoint(x: x + selfLoopWidth, y: y),
                        MermaidPoint(x: x + selfLoopWidth, y: bottom),
                        MermaidPoint(x: x, y: bottom)
                    ],
                    text: text,
                    style: style,
                    labelCentre: MermaidPoint(x: x + selfLoopWidth + 6, y: y + metric.lineHeight / 2),
                    isSelf: true
                ))
                rightReach = max(rightReach, x + selfLoopWidth + 6 + metric.width(text))
                lastRowY = y
                cursor = bottom + rowPitch * 0.6
                return
            }
            messages.append(MermaidSequenceDrawing.Message(
                points: [
                    MermaidPoint(x: centres[start], y: y),
                    MermaidPoint(x: centres[end], y: y)
                ],
                text: text,
                style: style,
                labelCentre: MermaidPoint(
                    x: (centres[start] + centres[end]) / 2,
                    y: y - metric.lineHeight * 0.7
                ),
                isSelf: false
            ))
            lastRowY = y
            cursor = y + rowPitch
        }

        private mutating func note(
            placement: MermaidSequence.NotePlacement,
            participants: [String],
            text: String
        ) {
            let columns = participants.compactMap { index[$0] }.sorted()
            guard let first = columns.first, let last = columns.last else { return }
            let width = metric.width(text) + 2 * 10
            let height = metric.lineHeight + 2 * padY
            let x: Double
            switch placement {
            case .over:
                let span = centres[last] - centres[first]
                x = centres[first] + span / 2 - max(width, span + 20) / 2
            case .leftOf:
                x = centres[first] - width - 12
            case .rightOf:
                x = centres[last] + 12
            }
            let frame = MermaidRect(
                x: x,
                y: cursor - metric.lineHeight * 0.5,
                width: placement == .over
                    ? max(width, centres[last] - centres[first] + 20)
                    : width,
                height: height
            )
            notes.append(MermaidSequenceDrawing.Note(frame: frame, text: text))
            rightReach = max(rightReach, frame.maxX)
            lastRowY = frame.midY
            cursor = frame.maxY + rowPitch * 0.5
        }

        /// An activation bar, nudged right for each one already open on the same lifeline so nested
        /// activations are visibly nested rather than drawn on top of each other.
        private func bar(column: Int, top: Double, bottom: Double, depth: Int) -> MermaidRect {
            MermaidRect(
                x: centres[column] - activationWidth / 2 + Double(depth) * activationWidth / 2,
                y: top,
                width: activationWidth,
                height: max(bottom - top, metric.lineHeight)
            )
        }

        /// Activations the file never closed, run to the foot of the diagram.
        ///
        /// A real document forgets a `deactivate`, and dropping the bar would show a participant as
        /// idle for the rest of a diagram that says otherwise.
        mutating func close(at bottom: Double) -> [MermaidRect] {
            for (column, stack) in open.sorted(by: { $0.key < $1.key }) {
                for (depth, top) in stack.enumerated() {
                    activations.append(bar(column: column, top: top, bottom: bottom, depth: depth))
                }
            }
            open = [:]
            return activations
        }
    }
}
