import GitExtensionsCore
import GitCommands
import Foundation

struct RevisionGraphLayout: Hashable, Sendable {
    static let laneWidth = 16
    static let maximumVisibleLanes = 40
    static let colorCount = 7

    struct Configuration: Hashable, Sendable {
        let mergeCommonParentLanes: Bool
        let straightenDiagonals: Bool

        var reduceGraphCrossings: Bool { !mergeCommonParentLanes }

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
        let role: Role
        let diagonal: Diagonal
        let previousDiagonal: Diagonal?
        let nextDiagonal: Diagonal?
    }

    struct Row: Hashable, Sendable {
        let commitID: RevisionID
        let nodeLane: Int
        let nodeColorIndex: Int
        let laneCount: Int
        let hasReferences: Bool
        let isHEAD: Bool
        let isRelative: Bool
        let commitKind: Commit.Kind
        let edges: [Edge]
    }

    let rows: [Row]
    let maximumLaneCount: Int

    static func build(
        commits: [Commit],
        completeHistory: [Commit]? = nil,
        configuration: Configuration = .gitExtensionsDefault
    ) -> RevisionGraphLayout {
        guard !commits.isEmpty else { return RevisionGraphLayout(rows: [], maximumLaneCount: 1) }

        let graph = GraphBuilder(
            commits: commits,
            completeHistory: completeHistory ?? commits,
            configuration: configuration
        )
        return graph.build()
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
    private static let straightenGraphSegmentsLimit = 80

    private let commits: [Commit]
    private let configuration: Layout.Configuration
    private let commitByID: [RevisionID: Commit]
    private let visibleIDs: Set<RevisionID>
    private let visibleParentsByID: [RevisionID: [RevisionID]]
    private let rowIndexByID: [RevisionID: Int]
    private let childCountByID: [RevisionID: Int]
    private let segmentsByChildID: [RevisionID: [Segment]]
    private let relativeIDs: Set<RevisionID>

    private var colorBySegment: [Segment: SegmentColor] = [:]
    private var rows: [RowState] = []

    init(commits: [Commit], completeHistory: [Commit], configuration: Layout.Configuration) {
        self.commits = commits
        self.configuration = configuration
        commitByID = Dictionary(uniqueKeysWithValues: completeHistory.map { ($0.id, $0) })
        visibleIDs = Set(commits.map(\.id))
        rowIndexByID = Dictionary(uniqueKeysWithValues: commits.enumerated().map { ($0.element.id, $0.offset) })

        var relatives: Set<RevisionID> = []
        var pending = completeHistory.filter(\.isHEAD).map(\.id)
        while let id = pending.popLast() {
            guard relatives.insert(id).inserted else { continue }
            pending.append(contentsOf: commitByID[id]?.graphParentIDs ?? [])
        }
        relativeIDs = relatives

        var parents: [RevisionID: [RevisionID]] = [:]
        for commit in commits {
            parents[commit.id] = Self.visibleParents(
                of: commit,
                visibleIDs: visibleIDs,
                commitByID: commitByID
            )
        }
        visibleParentsByID = parents

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

    func build() -> Layout {
        buildOrderedRows()
        straightenLanes()
        if configuration.straightenDiagonals { straightenDiagonals() }

        var result: [Layout.Row] = []
        var maximumLaneCount = 1
        for index in rows.indices {
            let state = rows[index]
            let commit = commits[index]
            let previous = index > 0 ? rows[index - 1] : nil
            let next = index + 1 < rows.count ? rows[index + 1] : nil
            let edges = makeEdges(for: state, at: index, previous: previous, next: next)
            let nodeEdge = edges
                .filter { edge in
                    if case .continuing = edge.role { return false }
                    return true
                }
                .sorted { lhs, rhs in
                    lhs.isRelative == rhs.isRelative ? false : !lhs.isRelative && rhs.isRelative
                }
                .last
            let nodeColor = nodeEdge?.colorIndex
                ?? Self.chooseColor(seed: Self.objectIDHash(state.revisionID), avoiding: [])
            let laneCount = min(Layout.maximumVisibleLanes, max(1, state.laneCount))
            maximumLaneCount = max(maximumLaneCount, laneCount)
            result.append(
                Layout.Row(
                    commitID: commit.id,
                    nodeLane: min(state.revisionLane, Layout.maximumVisibleLanes - 1),
                    nodeColorIndex: nodeColor,
                    laneCount: laneCount,
                    hasReferences: !commit.references.isEmpty,
                    isHEAD: commit.isHEAD,
                    isRelative: relativeIDs.contains(commit.id),
                    commitKind: commit.kind,
                    edges: edges
                )
            )
        }
        return Layout(rows: result, maximumLaneCount: maximumLaneCount)
    }

    private func buildOrderedRows() {
        var secondarySharedSince: [Segment: Int] = [:]

        for index in commits.indices {
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

    private func straightenLanes() {
        guard rows.count > 2 else { return }
        var currentIndex = 1
        var goBackLimit = 1
        let lastStraightenIndex = rows.count - 2

        while currentIndex <= lastStraightenIndex {
            goBackLimit = max(goBackLimit, currentIndex - Self.straightenLanesLookAhead)
            let current = rows[currentIndex]
            guard current.segments.count <= Self.straightenGraphSegmentsLimit else {
                currentIndex += 2
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

    private func straightenDiagonals() {
        let lookAhead = Self.straightenLanesLookAhead / 2
        guard lookAhead > 0, rows.count > 2 else { return }

        var currentIndex = 1
        var goBackLimit = 1
        let lastStraightenIndex = rows.count - 2

        while currentIndex <= lastStraightenIndex {
            goBackLimit = max(goBackLimit, currentIndex - lookAhead)
            let lastLookAheadIndex = min(currentIndex + lookAhead, rows.count - 1)
            let current = rows[currentIndex]
            guard current.segments.count <= Self.straightenGraphSegmentsLimit else {
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
        guard rows.indices.contains(rowIndex),
              let current = rows[rowIndex].lane(for: segment),
              current.index < Layout.maximumVisibleLanes
        else {
            return nil
        }

        let row = rows[rowIndex]
        var topLane: Int?
        var bottomLane: Int?
        var isRevisionLane = false

        if segment.parentID == row.revisionID {
            topLane = rowIndex > 0 ? rows[rowIndex - 1].lane(for: segment)?.index : nil
            isRevisionLane = true
        } else if segment.childID == row.revisionID {
            bottomLane = rowIndex + 1 < rows.count ? rows[rowIndex + 1].lane(for: segment)?.index : nil
            isRevisionLane = true
        } else {
            topLane = rowIndex > 0 ? rows[rowIndex - 1].lane(for: segment)?.index : nil
            bottomLane = rowIndex + 1 < rows.count ? rows[rowIndex + 1].lane(for: segment)?.index : nil
        }

        let primaryBottomLane = bottomLane
        if current.sharing == .differentStart {
            bottomLane = nil
        }

        func visible(_ lane: Int?) -> Int? {
            guard let lane, lane < Layout.maximumVisibleLanes else { return nil }
            return lane
        }
        topLane = visible(topLane)
        bottomLane = visible(bottomLane)

        return SegmentLanes(
            topLane: topLane,
            centerLane: current.index,
            bottomLane: bottomLane,
            primaryBottomLane: visible(primaryBottomLane),
            isRevisionLane: isRevisionLane,
            drawsFromStart: topLane != nil,
            drawsToEnd: bottomLane != nil
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
        let bowOffset = CGFloat(Layout.laneWidth) / 6
        let junctionBowOffset: CGFloat = 2
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
                        * ((abs(endShift) != 1 || sameDirection) ? junctionBowOffset / 3 : bowOffset)
                }
            } else if abs(endShift) == 1 {
                centerToStartPerpendicularly = false
                if !sameDirection {
                    horizontalOffset = -CGFloat(startShift.signum()) * junctionBowOffset * 2 / 3
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

            guard current.topLane != nil || current.bottomLane != nil else { continue }
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
                        ?? Self.chooseColor(seed: Self.objectIDHash(segment.childID), avoiding: []),
                    isRelative: relativeIDs.contains(segment.childID),
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
            index: Self.chooseColor(seed: seed, avoiding: forbidden),
            startScore: rowIndexByID[startID] ?? Int.max
        )
    }

    private static func visibleParents(
        of commit: Commit,
        visibleIDs: Set<RevisionID>,
        commitByID: [RevisionID: Commit]
    ) -> [RevisionID] {
        var result: [RevisionID] = []
        var emitted: Set<RevisionID> = []

        func appendVisibleAncestors(_ id: RevisionID, visited: inout Set<RevisionID>) {
            guard visited.insert(id).inserted else { return }
            if visibleIDs.contains(id) {
                if emitted.insert(id).inserted { result.append(id) }
                return
            }
            guard let hiddenCommit = commitByID[id] else { return }
            for parentID in hiddenCommit.graphParentIDs {
                appendVisibleAncestors(parentID, visited: &visited)
            }
        }

        for parentID in commit.graphParentIDs {
            var visited: Set<RevisionID> = []
            appendVisibleAncestors(parentID, visited: &visited)
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

    private static func chooseColor(seed: Int32, avoiding forbidden: Set<Int>) -> Int {
        var value = seed
        for _ in 0..<Layout.colorCount {
            let color = value == .min
                ? 0
                : Int(Swift.abs(value) % Int32(Layout.colorCount))
            if !forbidden.contains(color) { return color }
            value &+= 1
        }
        return 0
    }
}
