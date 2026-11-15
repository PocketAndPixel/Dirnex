import Foundation

/// The second half of a state diagram's layout: everything placed, turned into what is drawn
/// (PLAN.md §M39 ▸ Slice 13).
extension MermaidStatePass {
    /// A ranked transition, from its real source's outline through its dummies to its real target's.
    ///
    /// The ends are the transition's own states, not the ones that stood for them in the region it
    /// was ranked in, so a line into a state inside a composite carries on across the border.
    func edge(
        _ link: MermaidStateRegionLayout.Link,
        origin: MermaidPoint,
        frames: [MermaidRect]
    ) -> MermaidStateDrawing.Edge {
        let transition = diagram.transitions[link.transition]
        let waypoints = link.waypoints.map { $0.offset(by: origin) }
        let start = MermaidOutline.boundary(
            of: frames[transition.from],
            shape: shape(of: transition.from),
            toward: waypoints.first ?? frames[transition.to].center
        )
        let end = MermaidOutline.boundary(
            of: frames[transition.to],
            shape: shape(of: transition.to),
            toward: waypoints.last ?? frames[transition.from].center
        )
        let points = [start] + waypoints + [end]
        return MermaidStateDrawing.Edge(
            points: points,
            label: transition.label,
            labelCenter: link.labelCenter?.offset(by: origin) ?? Self.middle(of: points)
        )
    }

    /// Every state's transitions to itself, as loops beside it.
    func loops(_ frames: [MermaidRect]) -> [MermaidStateDrawing.Edge] {
        loopsOf.keys.sorted().flatMap { state -> [MermaidStateDrawing.Edge] in
            let transitions = loopsOf[state] ?? []
            let drawn = MermaidSelfLoops(
                frame: frames[state],
                shape: shape(of: state),
                direction: flow(of: state),
                labels: transitions.map { diagram.transitions[$0].label }
            ).drawn(metric: metric)
            return zip(transitions, drawn).map { position, loop in
                MermaidStateDrawing.Edge(
                    points: loop.points,
                    label: diagram.transitions[position].label,
                    labelCenter: loop.labelCenter ?? Self.middle(of: loop.points),
                    isLoop: true
                )
            }
        }
    }

    /// Transitions no region could rank — between a composite and a state inside it, or between the
    /// top level's `--` regions — drawn straight from outline to outline.
    func directEdges(_ frames: [MermaidRect]) -> [MermaidStateDrawing.Edge] {
        direct.map { position in
            let transition = diagram.transitions[position]
            let from = frames[transition.from]
            let to = frames[transition.to]
            let points = [
                MermaidOutline.boundary(
                    of: from,
                    shape: shape(of: transition.from),
                    toward: to.center
                ),
                MermaidOutline.boundary(of: to, shape: shape(of: transition.to), toward: from.center)
            ]
            return MermaidStateDrawing.Edge(
                points: points,
                label: transition.label,
                labelCenter: Self.middle(of: points)
            )
        }
    }

    func note(
        _ note: MermaidStateDiagram.Note,
        frame: MermaidRect,
        of state: MermaidRect
    ) -> MermaidStateDrawing.Note {
        MermaidStateDrawing.Note(
            frame: frame,
            texts: note.lines.enumerated().map { index, line in
                MermaidStateDrawing.Text(
                    string: line,
                    center: MermaidPoint(
                        x: frame.midX,
                        y: frame.y + Self.notePadY + metric.lineHeight * (Double(index) + 0.5)
                    )
                )
            },
            link: [
                MermaidOutline.boundary(of: frame, shape: .rectangle, toward: state.center),
                MermaidOutline.boundary(of: state, shape: .rounded, toward: frame.center)
            ]
        )
    }

    func node(_ index: Int, frame: MermaidRect) -> MermaidStateDrawing.Node {
        let state = diagram.states[index]
        func text(_ string: String, line: Double, from top: Double) -> MermaidStateDrawing.Text {
            MermaidStateDrawing.Text(
                string: string,
                center: MermaidPoint(x: frame.midX, y: top + metric.lineHeight * (line + 0.5))
            )
        }
        guard state.kind == .state else {
            return MermaidStateDrawing.Node(
                kind: state.kind,
                frame: frame,
                texts: [],
                isComposite: false,
                ruleY: nil
            )
        }
        if state.isComposite {
            return MermaidStateDrawing.Node(
                kind: .state,
                frame: frame,
                texts: [text(state.title, line: 0, from: frame.y + Self.titlePad)],
                isComposite: true,
                ruleY: compositeLayouts[index]?.ruleY.map { frame.y + $0 }
            )
        }
        guard state.descriptions.count > 1 else {
            return MermaidStateDrawing.Node(
                kind: .state,
                frame: frame,
                texts: [MermaidStateDrawing.Text(string: state.title, center: frame.center)],
                isComposite: false,
                ruleY: nil
            )
        }
        let rule = frame.y + Self.padY + metric.lineHeight + Self.ruleGap
        return MermaidStateDrawing.Node(
            kind: .state,
            frame: frame,
            texts: [text(state.title, line: 0, from: frame.y + Self.padY)]
                + state.descriptions.dropFirst().enumerated().map {
                    text($1, line: Double($0), from: rule + Self.ruleGap)
                },
            isComposite: false,
            ruleY: rule
        )
    }

    /// The outline a line is clipped to.
    func shape(of state: Int) -> MermaidFlowchart.Shape {
        switch diagram.states[state].kind {
        case .start, .end: .circle
        case .choice: .diamond
        case .fork, .join: .rectangle
        case .state: .rounded
        }
    }

    /// The direction of the region a state is drawn in.
    func flow(of state: Int) -> MermaidFlowchart.Direction {
        scopeOf[state].owner.map { diagram.states[$0].insideDirection } ?? diagram.direction
    }

    /// The midpoint of the polyline's middle segment, the flowchart's rule for a label with no slot.
    static func middle(of points: [MermaidPoint]) -> MermaidPoint {
        let index = (points.count - 1) / 2
        let first = points[index]
        let second = points[min(index + 1, points.count - 1)]
        return MermaidPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }
}
