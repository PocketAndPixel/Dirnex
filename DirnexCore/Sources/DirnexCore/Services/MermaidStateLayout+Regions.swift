import Foundation

/// A region placed on its own, relative to its top-left corner (PLAN.md §M39 ▸ Slice 13).
struct MermaidStateRegionLayout {
    struct Link {
        let transition: Int
        /// The dummies' centers, from the transition's source to its target.
        let waypoints: [MermaidPoint]
        /// The center of the dummy sized to hold the label, when there is one.
        let labelCenter: MermaidPoint?
    }

    let size: MermaidSize
    /// The states drawn here, in first-mention order, with the arrays below aligned to them.
    let members: [Int]
    /// Each member's box — inside its slot, which also holds its notes and loops.
    let frames: [MermaidRect]
    /// Each member's notes' boxes, aligned with the state's own `notes`.
    let notes: [[MermaidRect]]
    let links: [Link]
    /// Per crossing transition leaving this region, the path from its member out to its port, and
    /// per one entering, from its port in to its member, the port included (`MermaidStatePort`).
    var exitPaths: [Int: [MermaidPoint]] = [:]
    var entryPaths: [Int: [MermaidPoint]] = [:]
}

/// One or more regions beside each other, under a title or not: a composite's inside, or the whole
/// diagram's.
struct MermaidStateBodyLayout {
    let size: MermaidSize
    /// Each region's corner, relative to the body's.
    let origins: [MermaidPoint]
    /// The dashed lines between regions, relative to the body's corner.
    let dividers: [[MermaidPoint]]
    /// Where the rule under the title runs, relative to the body's top, when there is a title.
    let ruleY: Double?
}

/// A state's room in its region: its box, its notes beside it and its loops around it.
struct MermaidStateSlot {
    let size: MermaidSize
    /// The state's box, relative to the slot's corner.
    let node: MermaidRect
    /// Its notes' boxes, aligned with the state's `notes`.
    let notes: [MermaidRect]
}

extension MermaidStatePass {
    static let standardSpacing = MermaidLayered.Spacing(rankGap: 16, crossGap: 20, margin: 10)
    /// Ordering and balancing sweeps, alternating down and up.
    static let sweeps = 8
    static let padX = 12.0
    static let padY = 8.0
    static let minimumWidth = 40.0
    static let dotSize = 14.0
    static let choiceSize = 24.0
    static let barLength = 60.0
    static let barThickness = 8.0
    static let ruleGap = 4.0
    static let titlePad = 4.0
    static let noteGap = 16.0
    static let notePadX = 8.0
    static let notePadY = 6.0
    static let noteStackGap = 8.0

    // MARK: - Bodies

    /// `scopes` laid out and set beside each other **across** the flow — side by side in a
    /// top-to-bottom body, stacked in a left-to-right one, as Mermaid sets concurrent regions — with
    /// a dashed line between each two, and a title band above them when `title` is given.
    mutating func layBody(
        _ scopes: [MermaidStateScope],
        direction: MermaidFlowchart.Direction,
        title: String?
    ) -> MermaidStateBodyLayout {
        let sizes = scopes.map { layRegion($0, direction: direction).size }
        let across = !direction.isHorizontal
        let bodyWidth = across
            ? sizes.map(\.width).reduce(0, +)
            : sizes.map(\.width).max() ?? 0
        let bodyHeight = across
            ? sizes.map(\.height).max() ?? 0
            : sizes.map(\.height).reduce(0, +)
        let band = title == nil ? 0 : metric.lineHeight + 2 * Self.titlePad
        let width = max(bodyWidth, title.map { metric.width($0) + 2 * Self.padX } ?? 0)
        let left = (width - bodyWidth) / 2

        var origins: [MermaidPoint] = []
        var dividers: [[MermaidPoint]] = []
        var offset = 0.0
        for (index, size) in sizes.enumerated() {
            if index > 0 {
                dividers.append(across
                    ? [
                        MermaidPoint(x: left + offset, y: band),
                        MermaidPoint(x: left + offset, y: band + bodyHeight)
                    ]
                    : [
                        MermaidPoint(x: left, y: band + offset),
                        MermaidPoint(x: left + bodyWidth, y: band + offset)
                    ])
            }
            origins.append(across
                ? MermaidPoint(x: left + offset, y: band + (bodyHeight - size.height) / 2)
                : MermaidPoint(x: left + (bodyWidth - size.width) / 2, y: band + offset))
            offset += across ? size.width : size.height
        }
        return MermaidStateBodyLayout(
            size: MermaidSize(width: width, height: band + bodyHeight),
            origins: origins,
            dividers: dividers,
            ruleY: title == nil ? nil : band
        )
    }

    // MARK: - Regions

    /// One region, ranked with a half-layer for every transition and placed, its composites laid
    /// out first so each takes part as one box of its finished size.
    mutating func layRegion(
        _ scope: MermaidStateScope,
        direction: MermaidFlowchart.Direction
    ) -> MermaidStateRegionLayout {
        if let done = regionLayouts[scope] { return done }
        let region = scope.owner.map { diagram.states[$0].regions[scope.index] }
            ?? diagram.regions[scope.index]
        let members = region.states
        let local = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($1, $0) })
        let slots = members.map { slot(for: $0, direction: direction) }
        let links = linksIn[scope] ?? []
        let ports = portsIn[scope] ?? []
        let ranking = Self.rank(members: members.count, local: local, links: links, ports: ports)
        var sizes = slots.map(\.size) + Array(
            repeating: MermaidSize(width: 1, height: 0),
            count: ranking.layerOf.count - members.count
        )
        var labelDummies: [Int: Int] = [:]
        for (position, link) in links.enumerated() {
            let chain = ranking.chains[position]
            guard !chain.isEmpty, let label = diagram.transitions[link.transition].label else {
                continue
            }
            let dummy = chain[chain.count / 2]
            sizes[dummy] = MermaidSize(
                width: metric.width(label) + 8,
                height: metric.lineHeight + 2
            )
            labelDummies[position] = dummy
        }
        // A state lines up by its own box, not by its slot: a note beside it would otherwise pull it
        // off the line its transitions run along.
        let anchors = slots.map { slot in
            direction.isHorizontal
                ? slot.node.midY - slot.size.height / 2
                : slot.node.midX - slot.size.width / 2
        } + Array(repeating: 0.0, count: sizes.count - slots.count)
        let placement = MermaidLayered.place(
            ranking.layers,
            sizes: sizes,
            direction: direction,
            spacing: spacing,
            balance: MermaidLayered.Balance(
                segments: ranking.segments,
                anchors: anchors,
                sweeps: Self.sweeps
            )
        )
        let corners = placement.frames.map { MermaidPoint(x: $0.x, y: $0.y) }
        var layout = MermaidStateRegionLayout(
            size: MermaidSize(width: placement.width, height: placement.height),
            members: members,
            frames: members.indices.map { slots[$0].node.offset(by: corners[$0]) },
            notes: members.indices.map { member in
                slots[member].notes.map { $0.offset(by: corners[member]) }
            },
            links: links.enumerated().map { position, link in
                MermaidStateRegionLayout.Link(
                    transition: link.transition,
                    waypoints: ranking.chains[position].map { placement.frames[$0].center },
                    labelCenter: labelDummies[position].map { placement.frames[$0].center }
                )
            }
        )
        for (offset, port) in ports.enumerated() {
            let path = Self.path(
                of: port,
                chain: ranking.chains[links.count + offset].map { placement.frames[$0].center },
                at: placement.frames[members.count + offset].center
            )
            if port.isExit {
                layout.exitPaths[port.transition] = path
            } else {
                layout.entryPaths[port.transition] = path
            }
        }
        regionLayouts[scope] = layout
        return layout
    }

    /// A region's members and ports ranked, the transitions between members first and then one
    /// edge for each port, which is one more node after the members, joined to the member that
    /// holds its end.
    private static func rank(
        members: Int,
        local: [Int: Int],
        links: [MermaidStateLink],
        ports: [MermaidStatePort]
    ) -> MermaidRanking {
        let portEdges = ports.enumerated().map { offset, port -> (from: Int, to: Int)? in
            guard let member = local[port.member] else { return nil }
            let node = members + offset
            return port.isSink ? (from: member, to: node) : (from: node, to: member)
        }
        return MermaidLayering.rank(
            count: members + ports.count,
            edges: links.map { link in
                guard let from = local[link.from], let to = local[link.to] else { return nil }
                return (from: from, to: to)
            } + portEdges,
            stride: 2,
            sweeps: sweeps,
            sources: Set(ports.indices.filter { !ports[$0].isSink }.map { members + $0 }),
            sinks: Set(ports.indices.filter { ports[$0].isSink }.map { members + $0 })
        )
    }

    /// A port's path the way its line runs: out from the member for an exit, in to it for an entry.
    /// The chain runs the way its ranking edge does — member to port into the far channel, port to
    /// member out of the near one.
    private static func path(
        of port: MermaidStatePort,
        chain: [MermaidPoint],
        at node: MermaidPoint
    ) -> [MermaidPoint] {
        let outward = port.isSink ? chain + [node] : Array(([node] + chain).reversed())
        return port.isExit ? outward : outward.reversed()
    }

    // MARK: - Slots

    /// A state's box, with its loops reserved around it and its notes set beside it — on the left
    /// or right of the page, whatever the flow, since that is what `left of` says to a reader.
    mutating func slot(for state: Int, direction: MermaidFlowchart.Direction) -> MermaidStateSlot {
        let box = size(of: state, flow: direction)
        let loops = (loopsOf[state] ?? []).map { diagram.transitions[$0].label }
        let inner = MermaidSelfLoops.slot(box, labels: loops, direction: direction, metric: metric)
        let notes = diagram.states[state].notes
        let noteSizes = notes.map { note in
            MermaidSize(
                width: (note.lines.map(metric.width).max() ?? 0) + 2 * Self.notePadX,
                height: metric.lineHeight * Double(note.lines.count) + 2 * Self.notePadY
            )
        }
        func column(_ side: MermaidStateDiagram.NoteSide) -> MermaidSize {
            let sizes = zip(notes, noteSizes).filter { $0.0.side == side }.map(\.1)
            guard !sizes.isEmpty else { return MermaidSize(width: 0, height: 0) }
            return MermaidSize(
                width: (sizes.map(\.width).max() ?? 0) + Self.noteGap,
                height: sizes.map(\.height).reduce(0, +) + Self.noteStackGap * Double(
                    sizes.count - 1
                )
            )
        }
        let left = column(.left)
        let right = column(.right)
        let height = max(inner.height, left.height, right.height)
        let innerCorner = MermaidPoint(x: left.width, y: (height - inner.height) / 2)
        var tops = [
            MermaidStateDiagram.NoteSide.left: (height - left.height) / 2,
            .right: (height - right.height) / 2
        ]
        let noteFrames = zip(notes, noteSizes).map { note, size -> MermaidRect in
            let top = tops[note.side] ?? 0
            tops[note.side] = top + size.height + Self.noteStackGap
            let x = note.side == .left
                ? left.width - Self.noteGap - size.width
                : left.width + inner.width + Self.noteGap
            return MermaidRect(x: x, y: top, width: size.width, height: size.height)
        }
        return MermaidStateSlot(
            size: MermaidSize(width: left.width + inner.width + right.width, height: height),
            node: MermaidRect(
                x: innerCorner.x + (inner.width - box.width) / 2,
                y: innerCorner.y + (inner.height - box.height) / 2,
                width: box.width,
                height: box.height
            ),
            notes: noteFrames
        )
    }

    /// A state's own box. A bar lies across the flow it sits in; a composite is as big as its inside.
    mutating func size(of index: Int, flow: MermaidFlowchart.Direction) -> MermaidSize {
        let state = diagram.states[index]
        switch state.kind {
        case .start, .end:
            return MermaidSize(width: Self.dotSize, height: Self.dotSize)
        case .choice:
            return MermaidSize(width: Self.choiceSize, height: Self.choiceSize)
        case .fork, .join:
            return flow.isHorizontal
                ? MermaidSize(width: Self.barThickness, height: Self.barLength)
                : MermaidSize(width: Self.barLength, height: Self.barThickness)
        case .state:
            if let box = boxes[index] { return box }
            guard state.isComposite else { return textBox(state.descriptions, id: state.id) }
            let body = layBody(
                state.regions.indices.map { MermaidStateScope(owner: index, index: $0) },
                direction: state.insideDirection,
                title: state.title
            )
            compositeLayouts[index] = body
            return body.size
        }
    }

    /// A simple state's box: one line, or a title over a rule with the rest under it.
    private func textBox(_ descriptions: [String], id: String) -> MermaidSize {
        let lines = descriptions.isEmpty ? [id] : descriptions
        let width = max((lines.map(metric.width).max() ?? 0) + 2 * Self.padX, Self.minimumWidth)
        let rule = lines.count > 1 ? 2 * Self.ruleGap : 0
        return MermaidSize(
            width: width,
            height: metric.lineHeight * Double(lines.count) + 2 * Self.padY + rule
        )
    }
}
