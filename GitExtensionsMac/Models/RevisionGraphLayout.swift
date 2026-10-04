import GitExtensionsCore
import GitCommands
import Foundation

struct RevisionGraphLayout: Hashable, Sendable {
    static let laneWidth = 16
    static let maximumVisibleLanes = 40
    static let colorCount = 7


    enum DrawStyle: Hashable, Sendable {
        case normal
        case drawNonRelativesGray
        case highlightSelected
    }


    struct Configuration: Hashable, Sendable {
        var mergeCommonParentLanes: Bool
        var straightenDiagonals: Bool

        var renderWithDiagonals = true

        var straightenSegmentsLimit = 80
        var drawStyle: DrawStyle = .drawNonRelativesGray

        var onlyFirstParent = false

        var highlightedRevision: RevisionID?

        var colorCount = RevisionGraphLayout.colorCount

        var reduceGraphCrossings: Bool { !mergeCommonParentLanes }

        var skipsSecondarySharedSegments: Bool { drawStyle == .normal }

        init(mergeCommonParentLanes: Bool, straightenDiagonals: Bool, renderWithDiagonals: Bool = true,
             drawStyle: DrawStyle = .drawNonRelativesGray, onlyFirstParent: Bool = false,
             highlightedRevision: RevisionID? = nil, colorCount: Int = RevisionGraphLayout.colorCount) {
            self.mergeCommonParentLanes = mergeCommonParentLanes
            self.straightenDiagonals = straightenDiagonals
            self.renderWithDiagonals = renderWithDiagonals
            self.drawStyle = drawStyle
            self.onlyFirstParent = onlyFirstParent
            self.highlightedRevision = highlightedRevision
            self.colorCount = max(1, colorCount)
        }

        static let gitExtensionsDefault = Configuration(
            mergeCommonParentLanes: true,
            straightenDiagonals: true
        )
    }

    struct Edge: Hashable, Sendable {
        enum Role: Hashable, Sendable {
            case continuing
            case incoming
            case parent(primary: Bool)
        }

        struct Diagonal: Hashable, Sendable {
            let drawsFromStart: Bool
            let drawsToEnd: Bool
            let centerToStartPerpendicularly: Bool
            let drawsCenter: Bool
            let centerPerpendicularly: Bool
            let centerToEndPerpendicularly: Bool
            let horizontalOffset: CGFloat
        }

        let topLane: Int?
        let centerLane: Int
        let bottomLane: Int?
        let colorIndex: Int
        let isRelative: Bool
        let childID: RevisionID
        let parentID: RevisionID
        let role: Role
        let diagonal: Diagonal
        let previousDiagonal: Diagonal?
        let nextDiagonal: Diagonal?
    }

    struct Row: Hashable, Sendable {
        let commitID: RevisionID

        let nodeLane: Int

        let nodeColorIndex: Int?
        let laneCount: Int
        let hasReferences: Bool
        let isHEAD: Bool
        let isRelative: Bool
        let commitKind: Commit.Kind
        let edges: [Edge]
        let segmentParentIDs: [RevisionID]
    }

    let rows: [Row]
    let maximumLaneCount: Int
    var configuration = Configuration.gitExtensionsDefault

    var laneNodes: [[LaneNode]] = []

    var parentIDs: [RevisionID: [RevisionID]] = [:]


    struct LaneNode: Hashable, Sendable {
        let lane: Int

        let revisionID: RevisionID
        let isAtNode: Bool

        let singleChildID: RevisionID?
    }


    func node(atRow row: Int, lane: Int) -> LaneNode? {
        guard laneNodes.indices.contains(row), lane >= 0 else { return nil }
        return laneNodes[row].first { $0.lane == lane }
    }

    static func build(
        commits: [Commit],
        completeHistory: [Commit]? = nil,
        configuration: Configuration = .gitExtensionsDefault
    ) -> RevisionGraphLayout {
        guard !commits.isEmpty else { return RevisionGraphLayout(rows: [], maximumLaneCount: 1, configuration: configuration) }

        let graph = try! GraphBuilder(
            commits: commits,
            completeHistory: completeHistory ?? commits,
            configuration: configuration
        )
        return try! graph.build()
    }
}



actor RevisionGraphCache {
    struct Snapshot: Sendable {
        let orderedIDs: [RevisionID]
        let relatives: Set<RevisionID>
        let layout: RevisionGraphLayout
        let preparedRowCount: Int
    }

    private var input: [Commit] = []
    private var history: [Commit] = []
    private var configuration: RevisionGraphLayout.Configuration?
    private var ordering: GraphBuilder.ScoreOrdering?
    private var builder: GraphBuilder?

    func prepare(commits: [Commit], completeHistory: [Commit]? = nil,
                 configuration: RevisionGraphLayout.Configuration = .gitExtensionsDefault,
                 through row: Int, completed: Bool) throws -> Snapshot {
        do {
            try Task.checkCancellation()
            let extending = self.configuration == configuration && commits.count >= input.count
                && commits.prefix(input.count).elementsEqual(input)
            if !extending {
                ordering = GraphBuilder.ScoreOrdering(onlyFirstParent: configuration.onlyFirstParent, cancellable: true)
                builder = nil
                input = []
            }
            let history = completeHistory ?? commits
            if commits.count != input.count || builder == nil || self.history != history {
                try ordering!.append(Array(commits.dropFirst(input.count)))
                let next = try GraphBuilder(commits: commits, completeHistory: completeHistory ?? commits,
                    configuration: configuration, ordered: ordering!.ordered(), cancellable: true)
                if let builder { next.reusePreparedRows(from: builder) }
                builder = next
                input = commits
                self.history = history
                self.configuration = configuration
            }
            let graph = builder!
            let layout = try graph.build(through: row, completed: completed)
            try Task.checkCancellation()
            return Snapshot(orderedIDs: graph.commits.map(\.id), relatives: graph.relativeIDs,
                            layout: layout, preparedRowCount: graph.preparedRowCount)
        } catch {


            input = []; history = []; self.configuration = nil; ordering = nil; builder = nil
            throw error
        }
    }
}

private final class GraphBuilder {
    typealias Layout = RevisionGraphLayout

    private struct Segment: Hashable {
        let childID: RevisionID
        let parentID: RevisionID
        let parentIndex: Int
    }

    private struct SegmentColor {
        let index: Int
        let startScore: Int
    }

    private enum LaneSharing: Hashable {
        case exclusiveOrPrimary
        case entire
        case differentStart
        case differentEnd
    }

    private struct Lane: Hashable {
        let index: Int
        let sharing: LaneSharing
    }

    private struct SegmentLanes {
        let topLane: Int?
        let centerLane: Int
        let bottomLane: Int?
        let primaryBottomLane: Int?
        let isRevisionLane: Bool
        let drawsFromStart: Bool
        let drawsToEnd: Bool
    }

    private final class RowState {
        let revisionID: RevisionID
        let rowIndex: Int
        let segments: [Segment]

        private(set) var lanes: [Segment: Lane] = [:]
        private(set) var laneCount = 0
        private(set) var revisionLane = -1
        private var gaps: Set<Int> = []

        init(
            revisionID: RevisionID,
            rowIndex: Int,
            segments: [Segment],
            mergeCommonParents: Bool,
            secondarySharedSince: inout [Segment: Int]
        ) {
            self.revisionID = revisionID
            self.rowIndex = rowIndex
            self.segments = segments
            buildSegmentLanes(
                mergeCommonParents: mergeCommonParents,
                secondarySharedSince: &secondarySharedSince
            )
        }

        func lane(for segment: Segment) -> Lane? {
            lanes[segment]
        }

        func firstParentOrSelf(_ segment: Segment) -> Segment {
            guard segment.parentID == revisionID,
                  lane(for: segment)?.sharing == .exclusiveOrPrimary
            else {
                return segment
            }
            return segments.first(where: { $0.childID == revisionID }) ?? segment
        }

        func moveLanesRight(fromLane: Int, by amount: Int = 1) {
            guard amount > 0 else { return }
            var lane = fromLane
            for _ in 0..<amount {
                moveLanesRight(fromLane: lane)
                lane += 1
            }
        }

        private func moveLanesRight(fromLane: Int) {
            let nextGap = gaps.filter { $0 > fromLane }.min() ?? Int.max

            if revisionLane >= fromLane, revisionLane < nextGap {
                revisionLane += 1
            }

            let moved = lanes.compactMap { segment, lane -> Segment? in
                lane.index >= fromLane && lane.index < nextGap ? segment : nil
            }
            guard !moved.isEmpty else { return }

            gaps.insert(fromLane)
            if nextGap < Int.max {
                gaps.remove(nextGap)
            } else {
                laneCount += 1
            }

            for segment in moved {
                guard let lane = lanes[segment] else { continue }
                lanes[segment] = Lane(index: lane.index + 1, sharing: lane.sharing)
            }
        }

        private func buildSegmentLanes(
            mergeCommonParents: Bool,
            secondarySharedSince: inout [Segment: Int]
        ) {
            var hasStart = false
            var hasEnd = false

            func createLane() -> Int {
                defer { laneCount += 1 }
                return laneCount
            }

            func nodeLane() -> Int {
                if revisionLane < 0 { revisionLane = createLane() }
                return revisionLane
            }

            func secondarySharing(for segment: Segment) -> LaneSharing {
                if let firstSharedRow = secondarySharedSince[segment], rowIndex > firstSharedRow {
                    return .entire
                }
                secondarySharedSince[segment] = min(secondarySharedSince[segment] ?? rowIndex, rowIndex)
                return .differentStart
            }

            for segment in segments {
                let assigned: Lane
                if segment.childID == revisionID {
                    let index = nodeLane()
                    secondarySharedSince.removeValue(forKey: segment)
                    assigned = Lane(index: index, sharing: hasStart ? .differentEnd : .exclusiveOrPrimary)
                    hasStart = true
                } else if segment.parentID == revisionID {
                    let index = nodeLane()
                    if hasEnd {
                        assigned = Lane(index: index, sharing: secondarySharing(for: segment))
                    } else {
                        secondarySharedSince.removeValue(forKey: segment)
                        assigned = Lane(index: index, sharing: .exclusiveOrPrimary)
                    }
                    hasEnd = true
                } else if mergeCommonParents,
                          let shared = lanes.first(where: {
                              $0.key.parentID == segment.parentID && $0.value.index != revisionLane
                          }) {
                    assigned = Lane(index: shared.value.index, sharing: secondarySharing(for: segment))
                } else {
                    secondarySharedSince.removeValue(forKey: segment)
                    assigned = Lane(index: createLane(), sharing: .exclusiveOrPrimary)
                }
                lanes[segment] = assigned
            }

            if revisionLane < 0 { revisionLane = createLane() }
        }
    }

    private static let orderSegmentsLookAhead = 50
    private static let straightenLanesLookAhead = 20

    let commits: [Commit]
    private let insertedArtificial: Set<RevisionID>
    private let configuration: Layout.Configuration
    private let commitByID: [RevisionID: Commit]
    private let visibleIDs: Set<RevisionID>
    private let visibleParentsByID: [RevisionID: [RevisionID]]
    private let rowIndexByID: [RevisionID: Int]
    private let childCountByID: [RevisionID: Int]
    private let segmentsByChildID: [RevisionID: [Segment]]
    let relativeIDs: Set<RevisionID>
    private let cancellable: Bool

    private var colorBySegment: [Segment: SegmentColor] = [:]
    private var rows: [RowState] = []
    private var secondarySharedSince: [Segment: Int] = [:]
    private var renderedRows: [Layout.Row] = []
    private var renderedLaneNodes: [[Layout.LaneNode]] = []
    private var maximumLaneCount = 1
    private var finalized = false
    var preparedRowCount: Int { rows.count }

    init(commits input: [Commit], completeHistory: [Commit], configuration: Layout.Configuration,
         ordered suppliedOrder: (commits: [Commit], inserted: Set<RevisionID>)? = nil,
         cancellable: Bool = false) throws {
        self.cancellable = cancellable
        let ordered = suppliedOrder ?? Self.orderedByScore(input, onlyFirstParent: configuration.onlyFirstParent)
        commits = ordered.commits
        insertedArtificial = ordered.inserted
        self.configuration = configuration
        commitByID = Dictionary(completeHistory.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        visibleIDs = Set(commits.map(\.id))
        rowIndexByID = Dictionary(commits.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })

        var parents: [RevisionID: [RevisionID]] = [:]
        for commit in commits {
            if cancellable { try Task.checkCancellation() }
            parents[commit.id] = insertedArtificial.contains(commit.id) && commit.kind == .index ? [] : try Self.graphParents(
                of: commit,
                visibleIDs: visibleIDs,
                commitByID: commitByID,
                onlyFirstParent: configuration.onlyFirstParent, cancellable: cancellable
            )
        }
        visibleParentsByID = parents


        var relatives: Set<RevisionID> = []
        let listed = Set(ordered.commits.map(\.id))
        var pending = configuration.highlightedRevision.map { listed.contains($0) ? [$0] : [] }
            ?? ordered.commits.filter(\.isHEAD).map(\.id)
        while let id = pending.popLast() {
            if cancellable { try Task.checkCancellation() }
            guard relatives.insert(id).inserted else { continue }
            pending.append(contentsOf: parents[id] ?? [])
        }
        relativeIDs = relatives

        var children: [RevisionID: Int] = [:]
        for parentIDs in parents.values {
            for parentID in parentIDs { children[parentID, default: 0] += 1 }
        }
        childCountByID = children

        var segments: [RevisionID: [Segment]] = [:]
        for commit in commits {
            segments[commit.id] = (parents[commit.id] ?? []).enumerated().map {
                Segment(childID: commit.id, parentID: $0.element, parentIndex: $0.offset)
            }
        }
        segmentsByChildID = segments
    }




    static func orderedByScore(_ commits: [Commit], onlyFirstParent: Bool) -> (commits: [Commit], inserted: Set<RevisionID>) {
        let ordering = ScoreOrdering(onlyFirstParent: onlyFirstParent)
        try! ordering.append(commits)
        return ordering.ordered()
    }



    final class ScoreOrdering {
        final class Node {
            var score: Int
            var parents: [RevisionID] = []
            init(score: Int) { self.score = score }
        }

        private var maxScore = 0
        private var nodes: [RevisionID: Node] = [:]
        private var incomplete: [RevisionID: Node] = [:]
        private var added: [Commit] = []
        private var artificial: [Commit] = []
        private var trailingArtificial = false
        private let onlyFirstParent: Bool
        private let cancellable: Bool

        init(onlyFirstParent: Bool, cancellable: Bool = false) {
            self.onlyFirstParent = onlyFirstParent
            self.cancellable = cancellable
        }


        private func ensureScoreIsAbove(_ node: Node, _ minimal: Int) throws -> Int {
            guard minimal > node.score else { return node.score }
            node.score = minimal
            guard !node.parents.isEmpty else { return node.score }
            var maxScore = node.score
            var stack: [Node] = [node]
            while let revision = stack.popLast() {
                if cancellable { try Task.checkCancellation() }
                var previous: Node?
                for id in revision.parents {
                    guard let parent = nodes[id] ?? incomplete[id], parent.score <= revision.score else { continue }
                    parent.score = revision.score + 1
                    maxScore = max(maxScore, parent.score)
                    if let current = previous {
                        if current.parents.count >= parent.parents.count {
                            stack.append(current)
                            previous = parent
                        } else {
                            stack.append(parent)
                        }
                    } else {
                        previous = parent
                    }
                }
                if let previous { stack.append(previous) }
            }
            return maxScore
        }

        func append(_ commits: [Commit]) throws {
            let hasReal = added.contains { !$0.isArtificial }
            let firstRealIndex = commits.firstIndex { !$0.isArtificial }
            let trails = (hasReal && commits.contains(where: \.isArtificial))
                || (firstRealIndex.map { commits[$0...].contains(where: \.isArtificial) } ?? false)
            if trails && !trailingArtificial && !artificial.isEmpty {


                let previous = added.filter { !$0.isArtificial }
                nodes = [:]; incomplete = [:]; added = []; maxScore = 0
                trailingArtificial = true
                try append(previous)
            }
            trailingArtificial = trailingArtificial || trails
            for commit in commits {
                if cancellable { try Task.checkCancellation() }
                if commit.isArtificial && !artificial.contains(where: { $0.id == commit.id }) { artificial.append(commit) }
                if nodes[commit.id] != nil || (trailingArtificial && commit.isArtificial) { continue }
                let node: Node
                if let existing = incomplete.removeValue(forKey: commit.id) {
                    maxScore += 1
                    existing.score = maxScore
                    node = existing
                } else {
                    maxScore += 1
                    node = Node(score: maxScore)
                }
                let parentIDs = onlyFirstParent ? Array(commit.graphParentIDs.prefix(1)) : commit.graphParentIDs
                for parentID in parentIDs {
                    maxScore += 1
                    if let known = incomplete[parentID] {
                        known.score = maxScore
                    } else if let known = nodes[parentID] {
                        maxScore = try ensureScoreIsAbove(known, maxScore)
                    } else {
                        incomplete[parentID] = Node(score: maxScore)
                    }
                    node.parents.append(parentID)
                }
                nodes[commit.id] = node
                added.append(commit)
            }
        }

        func ordered() -> (commits: [Commit], inserted: Set<RevisionID>) {
            var ordered = added.enumerated()
                .sorted { lhs, rhs in
                    let a = nodes[lhs.element.id]!.score, b = nodes[rhs.element.id]!.score
                    return a == b ? lhs.offset < rhs.offset : a < b
                }
                .map(\.element)
            guard trailingArtificial else { return (ordered, []) }

            let anchor = artificial.first { $0.kind == .index }?.parentIDs.first.map(RevisionID.object)
            let position = anchor.flatMap { id in ordered.firstIndex { $0.id == id } } ?? 0
            ordered.insert(contentsOf: artificial, at: position)
            return (ordered, Set(artificial.map(\.id)))
        }
    }



    func reusePreparedRows(from previous: GraphBuilder) {
        guard configuration == previous.configuration, commits.count >= previous.rows.count else { return }
        for index in previous.rows.indices {
            let id = previous.commits[index].id
            guard commits[index].id == id,
                  visibleParentsByID[id] == previous.visibleParentsByID[id],
                  orderedStartSegments(segmentsByChildID[id] ?? [], at: index)
                    == previous.orderedStartSegments(previous.segmentsByChildID[id] ?? [], at: index) else { return }
        }
        rows = previous.rows
        colorBySegment = previous.colorBySegment
        secondarySharedSince = previous.secondarySharedSince
        let lookAhead = 2 * (Self.straightenLanesLookAhead + (configuration.straightenDiagonals ? Self.straightenLanesLookAhead / 2 : 0))
        let retainedCount = commits.count == previous.commits.count ? previous.renderedRows.count
            : min(previous.renderedRows.count, max(0, previous.rows.count - lookAhead))
        if relativeIDs == previous.relativeIDs && commits.prefix(retainedCount).elementsEqual(previous.commits.prefix(retainedCount)) {
            renderedRows = Array(previous.renderedRows.prefix(retainedCount))
            renderedLaneNodes = Array(previous.renderedLaneNodes.prefix(retainedCount))
            maximumLaneCount = renderedRows.map(\.laneCount).max() ?? 1
        }
    }

    private func checkCancellation() throws {
        if cancellable { try Task.checkCancellation() }
    }

    func build(through requestedRow: Int = .max, completed: Bool = true) throws -> Layout {
        try checkCancellation()
        let diagonalLookAhead = configuration.straightenDiagonals ? Self.straightenLanesLookAhead / 2 : 0
        let lookAhead = 2 * (Self.straightenLanesLookAhead + diagonalLookAhead)
        let requested = requestedRow == .max ? commits.count - 1 : max(0, requestedRow) + lookAhead

        let available = commits.count - 1 - (!completed && configuration.reduceGraphCrossings ? Self.orderSegmentsLookAhead : 0)
        let last = min(requested, available)
        let start = rows.count
        let atEnd = completed && last == commits.count - 1
        if start <= last {
            try buildOrderedRows(through: last)
            try straightenLanes(start: max(1, start - Self.straightenLanesLookAhead),
                                last: atEnd ? last - 1 : last - Self.straightenLanesLookAhead)
            if configuration.straightenDiagonals {
                try straightenDiagonals(start: max(1, start - Self.straightenLanesLookAhead - diagonalLookAhead),
                    last: atEnd ? last - 1 : last - Self.straightenLanesLookAhead - diagonalLookAhead)
            }
        } else if completed && rows.count == commits.count && !finalized {

            try straightenLanes(start: max(1, rows.count - Self.straightenLanesLookAhead), last: rows.count - 2)
            if configuration.straightenDiagonals {
                try straightenDiagonals(start: max(1, rows.count - Self.straightenLanesLookAhead - diagonalLookAhead), last: rows.count - 2)
            }
        }
        finalized = completed && rows.count == commits.count

        let stableCount = completed && rows.count == commits.count ? rows.count : max(0, rows.count - lookAhead)
        for index in renderedRows.count..<stableCount {
            try checkCancellation()
            let row = renderRow(at: index)
            maximumLaneCount = max(maximumLaneCount, row.laneCount)
            renderedRows.append(row)
            renderedLaneNodes.append(laneNodesForRow(rows[index]))
        }



        let displayCount = max(stableCount, min(rows.count, requestedRow == .max ? rows.count : max(0, requestedRow) + 1))
        var displayed = renderedRows
        var laneNodes = renderedLaneNodes
        var displayMaximumLaneCount = maximumLaneCount
        for index in stableCount..<displayCount {
            try checkCancellation()
            let row = renderRow(at: index)
            displayed.append(row)
            laneNodes.append(laneNodesForRow(rows[index]))
            displayMaximumLaneCount = max(displayMaximumLaneCount, row.laneCount)
        }
        var layout = Layout(rows: displayed, maximumLaneCount: displayMaximumLaneCount, configuration: configuration)
        layout.laneNodes = laneNodes
        layout.parentIDs = visibleParentsByID
        return layout
    }

    private func renderRow(at index: Int) -> Layout.Row {
        let state = rows[index]
        let commit = commits[index]
        let previous = index > 0 ? rows[index - 1] : nil
        let next = index + 1 < rows.count ? rows[index + 1] : nil
        return Layout.Row(commitID: commit.id, nodeLane: state.revisionLane, nodeColorIndex: nodeColor(for: state),
            laneCount: min(Layout.maximumVisibleLanes, max(1, state.laneCount)),
            hasReferences: commit.references.contains { $0.kind != .stash || $0.name == "stash@{0}" },
            isHEAD: commit.isHEAD, isRelative: relativeIDs.contains(commit.id), commitKind: commit.kind,
            edges: makeEdges(for: state, at: index, previous: previous, next: next),
            segmentParentIDs: state.segments.map(\.parentID))
    }



    private func nodeColor(for row: RowState) -> Int? {
        let candidates = row.segments.reversed().filter { segment in
            guard segment.parentID == row.revisionID || segment.childID == row.revisionID,
                  let lane = row.lane(for: segment) else { return false }
            return !(configuration.skipsSecondarySharedSegments && lane.sharing == .entire)
        }
        let drawOrder = candidates.filter { !relativeIDs.contains($0.childID) } + candidates.filter { relativeIDs.contains($0.childID) }
        return drawOrder.last.map { colorBySegment[$0].map(\.index) ?? Self.chooseColor(seed: Self.objectIDHash($0.childID), avoiding: [], count: configuration.colorCount) }
    }


    private func laneNodesForRow(_ row: RowState) -> [Layout.LaneNode] {
        var result = [Layout.LaneNode(lane: max(0, row.revisionLane), revisionID: row.revisionID, isAtNode: true, singleChildID: nil)]
        var seen: Set<Int> = [max(0, row.revisionLane)]
        for segment in row.segments {
            guard let lane = row.lane(for: segment)?.index, seen.insert(lane).inserted else { continue }
            result.append(.init(lane: lane, revisionID: segment.parentID, isAtNode: false, singleChildID: segment.childID))
        }
        return result
    }

    private func buildOrderedRows(through last: Int) throws {
        guard rows.count <= last else { return }
        for index in rows.count...last {
            try checkCancellation()
            let commit = commits[index]
            let authoredSegments = segmentsByChildID[commit.id] ?? []
            let startSegments = configuration.reduceGraphCrossings
                ? orderedStartSegments(authoredSegments, at: index)
                : authoredSegments
            let rowSegments: [Segment]

            if index == 0 {
                rowSegments = startSegments
                assignNewColors(to: startSegments, left: nil, right: nil)
            } else {
                let previous = rows[index - 1]
                var carried: [Segment] = []
                carried.reserveCapacity(previous.segments.count + startSegments.count)
                var startsAdded = false

                for (previousIndex, segment) in previous.segments.enumerated() {
                    if segment.parentID == previous.revisionID { continue }
                    carried.append(segment)

                    guard segment.parentID == commit.id else { continue }
                    let nextSegment = previous.segments[(previousIndex + 1)...].first(where: {
                        $0.parentID != previous.revisionID && $0.parentID != commit.id
                    })
                    if !startsAdded {
                        startsAdded = true
                        carried.append(contentsOf: startSegments)
                    }

                    assignReplacementColors(
                        to: startSegments,
                        incoming: segment,
                        left: segment,
                        right: nextSegment
                    )
                }

                if !startsAdded {
                    let left = carried.last
                    carried.append(contentsOf: startSegments)
                    assignNewColors(to: startSegments, left: left, right: nil)
                }
                rowSegments = carried
            }

            rows.append(
                RowState(
                    revisionID: commit.id,
                    rowIndex: index,
                    segments: rowSegments,
                    mergeCommonParents: configuration.mergeCommonParentLanes,
                    secondarySharedSince: &secondarySharedSince
                )
            )
        }
    }

    private func orderedStartSegments(_ input: [Segment], at rowIndex: Int) -> [Segment] {
        guard input.count > 1 else { return input }

        let endIndex = min(rowIndex + Self.orderSegmentsLookAhead, commits.count)
        func relativeRow(of revisionID: RevisionID) -> Int {
            guard let index = rowIndexByID[revisionID], index > rowIndex, index < endIndex else {
                return Int.max
            }
            return index - rowIndex
        }

        func isAncestor(_ ancestorID: RevisionID, of childID: RevisionID, stopRow: Int, visited: inout Set<RevisionID>) -> Bool {
            guard visited.insert(childID).inserted else { return false }
            let parents = visibleParentsByID[childID] ?? []
            if parents.contains(ancestorID) { return true }
            for parentID in parents where relativeRow(of: parentID) < stopRow {
                if isAncestor(ancestorID, of: parentID, stopRow: stopRow, visited: &visited) { return true }
            }
            return false
        }

        func graphScore(_ segment: Segment, row: Int) -> Int {
            let parentCount = visibleParentsByID[segment.parentID]?.count ?? 0
            if parentCount == 0 { return row }
            if parentCount >= 2 { return -2_000_000_000 + row }
            if (childCountByID[segment.parentID] ?? 0) > 1 { return -1_000_000_000 + row }
            return row
        }

        return input.enumerated().sorted { lhs, rhs in
            let a = lhs.element
            let b = rhs.element
            let rowA = relativeRow(of: a.parentID)
            let rowB = relativeRow(of: b.parentID)

            if rowA != Int.max, rowB != Int.max {
                if rowA > rowB {
                    var visited: Set<RevisionID> = []
                    if isAncestor(a.parentID, of: b.parentID, stopRow: rowA, visited: &visited) { return true }
                } else if rowB > rowA {
                    var visited: Set<RevisionID> = []
                    if isAncestor(b.parentID, of: a.parentID, stopRow: rowB, visited: &visited) { return false }
                }
            }

            let scoreA = graphScore(a, row: rowA)
            let scoreB = graphScore(b, row: rowB)
            return scoreA == scoreB ? lhs.offset < rhs.offset : scoreA < scoreB
        }.map(\.element)
    }

    private func straightenLanes(start: Int, last lastStraightenIndex: Int) throws {
        guard rows.count > 2 else { return }
        var currentIndex = start
        var goBackLimit = start

        while currentIndex <= lastStraightenIndex {
            try checkCancellation()
            goBackLimit = max(goBackLimit, currentIndex - Self.straightenLanesLookAhead)
            let current = rows[currentIndex]
            guard current.segments.count <= configuration.straightenSegmentsLimit else {
                currentIndex += 1
                continue
            }

            let previous = rows[currentIndex - 1]
            var moved = false
            for segment in current.segments.prefix(Layout.maximumVisibleLanes) {
                guard let currentLane = current.lane(for: segment),
                      currentLane.sharing == .exclusiveOrPrimary,
                      let previousLane = previous.lane(for: segment)?.index,
                      previousLane > currentLane.index
                else {
                    continue
                }

                let desiredLane = currentLane.index + 1
                var lookAheadLane = currentLane.index
                var segmentOrAncestor = current.firstParentOrSelf(segment)
                let end = min(currentIndex + Self.straightenLanesLookAhead, rows.count - 1)
                if currentIndex + 1 <= end {
                    for lookAheadIndex in (currentIndex + 1)...end {
                        guard lookAheadLane == currentLane.index else { break }
                        let lookAhead = rows[lookAheadIndex]
                        lookAheadLane = lookAhead.lane(for: segmentOrAncestor)?.index ?? -1
                        if lookAheadLane == desiredLane
                            || (lookAheadLane > desiredLane && previousLane == desiredLane) {
                            for moveIndex in currentIndex..<lookAheadIndex {
                                rows[moveIndex].moveLanesRight(fromLane: currentLane.index)
                            }
                            moved = true
                            break
                        }
                        segmentOrAncestor = lookAhead.firstParentOrSelf(segmentOrAncestor)
                    }
                }
                if moved { break }
            }

            currentIndex = moved
                ? max(currentIndex - Self.straightenLanesLookAhead, goBackLimit)
                : currentIndex + 1
        }
    }

    private func straightenDiagonals(start: Int, last lastStraightenIndex: Int) throws {
        let lookAhead = Self.straightenLanesLookAhead / 2
        guard lookAhead > 0, rows.count > 2 else { return }

        var currentIndex = start
        var goBackLimit = start

        while currentIndex <= lastStraightenIndex {
            try checkCancellation()
            goBackLimit = max(goBackLimit, currentIndex - lookAhead)
            let lastLookAheadIndex = min(currentIndex + lookAhead, rows.count - 1)
            let current = rows[currentIndex]
            guard current.segments.count <= configuration.straightenSegmentsLimit else {
                currentIndex += 1
                continue
            }

            let previous = rows[currentIndex - 1]
            var moved = false
            for segment in current.segments.prefix(Layout.maximumVisibleLanes) {
                guard let assigned = current.lane(for: segment), assigned.sharing == .exclusiveOrPrimary else {
                    continue
                }
                var currentLane = assigned.index
                let previousLane = previous.lane(for: segment)?.index ?? -1

                if currentLane == previousLane - 1, currentIndex + 2 <= lastLookAheadIndex {
                    var segmentOrAncestor = current.firstParentOrSelf(segment)
                    let next = rows[currentIndex + 1]
                    let nextLane = next.lane(for: segmentOrAncestor)?.index ?? -1
                    if nextLane == currentLane {
                        segmentOrAncestor = next.firstParentOrSelf(segmentOrAncestor)
                        let endLane = rows[currentIndex + 2].lane(for: segmentOrAncestor)?.index ?? -1
                        if endLane >= 0,
                           endLane == nextLane - 1,
                           !isPreviousLaneDiagonal(
                               segment: segment,
                               at: currentIndex,
                               previousLane: previousLane
                           ) {
                            current.moveLanesRight(fromLane: currentLane)
                            currentLane += 1
                            moved = true
                            break
                        }
                    }
                }

                if turnCrossingIntoDiagonal(
                    segment: segment,
                    currentIndex: currentIndex,
                    currentLane: currentLane,
                    previousLane: previousLane,
                    lastLookAheadIndex: lastLookAheadIndex,
                    diagonalDelta: 1
                ) || turnCrossingIntoDiagonal(
                    segment: segment,
                    currentIndex: currentIndex,
                    currentLane: currentLane,
                    previousLane: previousLane,
                    lastLookAheadIndex: lastLookAheadIndex,
                    diagonalDelta: -1
                ) {
                    moved = true
                    break
                }

                let deltaPrevious = previousLane - currentLane
                guard previousLane >= 0, abs(deltaPrevious) >= 1 else { continue }
                var segmentOrAncestor = current.firstParentOrSelf(segment)
                let next = rows[currentIndex + 1]
                let nextLane = next.lane(for: segmentOrAncestor)?.index ?? -1
                let deltaNext = currentLane - nextLane
                guard nextLane >= 0,
                      deltaNext.signum() == deltaPrevious.signum(),
                      abs(deltaNext + deltaPrevious) >= 3,
                      !isPreviousLaneDiagonal(
                          segment: segment,
                          at: currentIndex,
                          previousLane: previousLane,
                          diagonalDelta: deltaPrevious.signum()
                      )
                else {
                    continue
                }

                var nextIsDiagonal = false
                if currentIndex + 2 <= lastLookAheadIndex {
                    segmentOrAncestor = next.firstParentOrSelf(segmentOrAncestor)
                    let nextNextLane = rows[currentIndex + 2].lane(for: segmentOrAncestor)?.index ?? -1
                    nextIsDiagonal = nextNextLane >= 0
                        && nextNextLane == nextLane - deltaNext.signum()
                }
                guard !nextIsDiagonal else { continue }

                let moveBy = deltaNext < 0 ? -deltaNext : deltaPrevious
                current.moveLanesRight(fromLane: currentLane, by: moveBy)
                moved = true
                break
            }

            currentIndex = moved ? max(currentIndex - lookAhead, goBackLimit) : currentIndex + 1
        }
    }

    private func isPreviousLaneDiagonal(
        segment: Segment,
        at rowIndex: Int,
        previousLane: Int,
        diagonalDelta: Int = 1
    ) -> Bool {
        guard rowIndex >= 2 else { return false }
        let previousPreviousLane = rows[rowIndex - 2].lane(for: segment)?.index ?? -1
        return previousPreviousLane >= 0 && previousPreviousLane == previousLane + diagonalDelta
    }

    private func turnCrossingIntoDiagonal(
        segment: Segment,
        currentIndex: Int,
        currentLane: Int,
        previousLane: Int,
        lastLookAheadIndex: Int,
        diagonalDelta: Int
    ) -> Bool {
        var moves: [(row: RowState, lane: Int, by: Int)] = []
        var segmentOrAncestor = segment
        var diagonalLane = previousLane >= 0 ? previousLane : currentLane

        for lookAheadIndex in currentIndex...lastLookAheadIndex {
            diagonalLane += diagonalDelta
            let endRow = rows[lookAheadIndex]
            guard let endLane = endRow.lane(for: segmentOrAncestor) else { return false }
            let moveBy = diagonalLane - endLane.index
            let lastChance = endLane.sharing == .differentStart
            guard moveBy >= 0,
                  endLane.sharing == .exclusiveOrPrimary || lastChance
            else {
                return false
            }

            if moveBy >= 2,
               moves.count == 2,
               lookAheadIndex == currentIndex + 3,
               moves[1].by == 1 {
                applyLaneMoves(moves.prefix(1))
                return true
            }

            if moveBy == 0, !moves.isEmpty {
                applyLaneMoves(moves)
                return true
            }
            if lastChance { return false }
            if moveBy > 0 { moves.append((endRow, endLane.index, moveBy)) }
            segmentOrAncestor = endRow.firstParentOrSelf(segmentOrAncestor)
        }
        return false
    }

    private func applyLaneMoves<S: Sequence>(_ moves: S)
    where S.Element == (row: RowState, lane: Int, by: Int) {
        for move in moves {
            move.row.moveLanesRight(fromLane: move.lane, by: move.by)
        }
    }


    private func segmentLanes(for segment: Segment, at rowIndex: Int) -> SegmentLanes? {
        guard rows.indices.contains(rowIndex), let current = rows[rowIndex].lane(for: segment) else {
            return nil
        }
        let maxLanes = Layout.maximumVisibleLanes

        if configuration.skipsSecondarySharedSegments && current.sharing == .entire {
            return SegmentLanes(topLane: nil, centerLane: current.index, bottomLane: nil, primaryBottomLane: nil,
                                isRevisionLane: false, drawsFromStart: false, drawsToEnd: false)
        }

        let row = rows[rowIndex]
        var topLane: Int?
        var bottomLane: Int?
        var isRevisionLane = true

        if segment.parentID == row.revisionID {
            topLane = rowIndex > 0 ? rows[rowIndex - 1].lane(for: segment)?.index : nil
        } else if segment.childID == row.revisionID {
            bottomLane = rowIndex + 1 < rows.count ? rows[rowIndex + 1].lane(for: segment)?.index : nil
        } else {
            topLane = rowIndex > 0 ? rows[rowIndex - 1].lane(for: segment)?.index : nil
            bottomLane = rowIndex + 1 < rows.count ? rows[rowIndex + 1].lane(for: segment)?.index : nil
            isRevisionLane = false
        }

        let primaryBottomLane = bottomLane
        if current.sharing == .differentStart
            && (configuration.skipsSecondarySharedSegments || !configuration.mergeCommonParentLanes) {
            bottomLane = nil
        }

        let center = current.index
        return SegmentLanes(
            topLane: topLane,
            centerLane: center,
            bottomLane: bottomLane,
            primaryBottomLane: primaryBottomLane,
            isRevisionLane: isRevisionLane,
            drawsFromStart: topLane.map { $0 <= maxLanes || center <= maxLanes } ?? false,
            drawsToEnd: bottomLane.map { $0 <= maxLanes || center <= maxLanes } ?? false
        )
    }

    private func diagonal(for lanes: SegmentLanes) -> Layout.Edge.Diagonal {
        let start = lanes.topLane ?? -1
        let center = lanes.centerLane
        let end = lanes.bottomLane ?? -1
        let primaryEnd = lanes.primaryBottomLane ?? -1
        let drawsFromStart = lanes.drawsFromStart
        let drawsToEnd = lanes.drawsToEnd
        let startShift = center - start
        var endShift = end - center
        let startIsDiagonal = abs(startShift) == 1
        let endIsDiagonal = abs(endShift) == 1
        let isBow = startIsDiagonal && endIsDiagonal && -startShift.signum() == endShift.signum()
        let laneLineWidth: CGFloat = 2
        let bowOffset = CGFloat(Layout.laneWidth / 6)
        let junctionBowOffset: CGFloat = configuration.mergeCommonParentLanes ? laneLineWidth : bowOffset
        var horizontalOffset = isBow ? -CGFloat(startShift.signum()) * junctionBowOffset : 0

        var centerToStartPerpendicularly = drawsFromStart
            && (startShift == 0 || (!startIsDiagonal && !lanes.isRevisionLane))
        var centerToEndPerpendicularly = drawsToEnd
            && (endShift == 0 || (!endIsDiagonal && !lanes.isRevisionLane))
        let centerPerpendicularly = isBow
        var drawsCenter = centerPerpendicularly || !drawsFromStart || !drawsToEnd
            || (!centerToStartPerpendicularly && !centerToEndPerpendicularly)

        if end < 0, primaryEnd >= 0, startShift != 0 {
            endShift = primaryEnd - center
            let sameDirection = endShift.signum() == startShift.signum()
            if startIsDiagonal {
                if !sameDirection || abs(endShift) > 1 {
                    centerToEndPerpendicularly = true
                    drawsCenter = false
                    horizontalOffset = -CGFloat(startShift.signum())
                        * ((abs(endShift) != 1 || sameDirection) ? CGFloat(Int(laneLineWidth) / 3) : bowOffset)
                }
            } else if abs(endShift) == 1 {
                centerToStartPerpendicularly = false
                if !sameDirection {
                    horizontalOffset = -CGFloat(startShift.signum()) * CGFloat(Int(laneLineWidth) * 2 / 3)
                }
            } else {
                centerToStartPerpendicularly = false
            }
        }

        return Layout.Edge.Diagonal(
            drawsFromStart: drawsFromStart,
            drawsToEnd: drawsToEnd,
            centerToStartPerpendicularly: centerToStartPerpendicularly,
            drawsCenter: drawsCenter,
            centerPerpendicularly: centerPerpendicularly,
            centerToEndPerpendicularly: centerToEndPerpendicularly,
            horizontalOffset: horizontalOffset
        )
    }

    private func makeEdges(for row: RowState, at index: Int, previous: RowState?, next: RowState?) -> [Layout.Edge] {
        var edges: [Layout.Edge] = []
        edges.reserveCapacity(row.segments.count)

        for segment in row.segments.reversed() {
            guard row.lane(for: segment) != nil,
                  let current = segmentLanes(for: segment, at: index)
            else {
                continue
            }

            let role: Layout.Edge.Role

            if segment.parentID == row.revisionID {
                role = .incoming
            } else if segment.childID == row.revisionID {
                role = .parent(primary: segment.parentIndex == 0)
            } else {
                role = .continuing
            }

            guard current.drawsFromStart || current.drawsToEnd else { continue }
            let previousDiagonal = index > 0
                ? segmentLanes(for: segment, at: index - 1).map(diagonal(for:))
                : nil
            let nextDiagonal = index + 1 < rows.count
                ? segmentLanes(for: segment, at: index + 1).map(diagonal(for:))
                : nil
            edges.append(
                Layout.Edge(
                    topLane: current.topLane,
                    centerLane: current.centerLane,
                    bottomLane: current.bottomLane,
                    colorIndex: colorBySegment[segment].map(\.index)
                        ?? Self.chooseColor(seed: Self.objectIDHash(segment.childID), avoiding: [], count: configuration.colorCount),
                    isRelative: relativeIDs.contains(segment.childID),
                    childID: segment.childID,
                    parentID: segment.parentID,
                    role: role,
                    diagonal: diagonal(for: current),
                    previousDiagonal: previousDiagonal,
                    nextDiagonal: nextDiagonal
                )
            )
        }
        return edges
    }

    private func assignReplacementColors(
        to segments: [Segment],
        incoming: Segment,
        left: Segment?,
        right: Segment?
    ) {
        guard !segments.isEmpty else { return }
        let incomingInfo = colorBySegment[incoming]
        let first = segments[0]
        if let incomingInfo,
           colorBySegment[first] == nil || colorBySegment[first]!.startScore > incomingInfo.startScore {
            colorBySegment[first] = incomingInfo
        } else if colorBySegment[first] == nil {
            colorBySegment[first] = makeColor(
                for: first,
                startID: first.childID,
                derivedFrom: nil,
                left: left,
                right: right
            )
        }

        var previous = first
        for segment in segments.dropFirst() where colorBySegment[segment] == nil {
            colorBySegment[segment] = makeColor(
                for: segment,
                startID: incomingInfo == nil ? segment.childID : segment.parentID,
                derivedFrom: incomingInfo?.index,
                left: previous,
                right: right
            )
            previous = segment
        }
    }

    private func assignNewColors(
        to segments: [Segment],
        left: Segment?,
        right: Segment?
    ) {
        var previous = left
        for segment in segments where colorBySegment[segment] == nil {
            colorBySegment[segment] = makeColor(
                for: segment,
                startID: segment.childID,
                derivedFrom: nil,
                left: previous,
                right: right
            )
            previous = segment
        }
    }

    private func makeColor(
        for segment: Segment,
        startID: RevisionID,
        derivedFrom: Int?,
        left: Segment?,
        right: Segment?
    ) -> SegmentColor {
        let startHash = Self.objectIDHash(startID)
        let seed = derivedFrom == nil ? startHash ^ Self.objectIDHash(segment.parentID) : startHash
        let forbidden = Set([
            left.flatMap { colorBySegment[$0]?.index },
            right.flatMap { colorBySegment[$0]?.index },
            derivedFrom
        ].compactMap { $0 })
        return SegmentColor(
            index: Self.chooseColor(seed: seed, avoiding: forbidden, count: configuration.colorCount),
            startScore: rowIndexByID[startID] ?? Int.max
        )
    }



    private static func graphParents(
        of commit: Commit,
        visibleIDs: Set<RevisionID>,
        commitByID: [RevisionID: Commit],
        onlyFirstParent: Bool, cancellable: Bool
    ) throws -> [RevisionID] {
        var result: [RevisionID] = []
        var emitted: Set<RevisionID> = []

        let parents = onlyFirstParent ? Array(commit.graphParentIDs.prefix(1)) : commit.graphParentIDs
        for parentID in parents {
            var visited: Set<RevisionID> = []
            var pending = [parentID]
            while let id = pending.popLast() {
                if cancellable { try Task.checkCancellation() }
                guard visited.insert(id).inserted else { continue }
                if visibleIDs.contains(id) {
                    if emitted.insert(id).inserted { result.append(id) }
                    continue
                }
                guard let hiddenCommit = commitByID[id] else {

                    if !commit.isArtificial, emitted.insert(id).inserted { result.append(id) }
                    continue
                }
                let parents = onlyFirstParent ? Array(hiddenCommit.graphParentIDs.prefix(1)) : hiddenCommit.graphParentIDs
                pending.append(contentsOf: parents.reversed())
            }
        }
        return result
    }

    private static func objectIDHash(_ revisionID: RevisionID) -> Int32 {
        let valueString = revisionID.description
        let prefix = valueString.prefix(8)
        guard prefix.count == 8,
              let value = UInt32(prefix, radix: 16)
        else {
            var value: UInt32 = 2_166_136_261
            for byte in valueString.utf8 {
                value ^= UInt32(byte)
                value &*= 16_777_619
            }
            return Int32(bitPattern: value)
        }
        let byte0 = value >> 24
        let byte1 = (value >> 16) & 0xFF
        let byte2 = (value >> 8) & 0xFF
        let byte3 = value & 0xFF
        return Int32(bitPattern: byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24))
    }


    private static func chooseColor(seed: Int32, avoiding forbidden: Set<Int>, count: Int) -> Int {
        var value = seed
        for _ in 0..<(count + forbidden.count + 1) {
            let color = value == .min
                ? 0
                : Int(Swift.abs(value) % Int32(count))
            if !forbidden.contains(color) { return color }
            value &+= 1
        }
        return 0
    }
}
