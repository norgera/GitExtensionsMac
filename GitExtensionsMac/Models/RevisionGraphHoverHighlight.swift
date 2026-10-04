import GitExtensionsCore
import GitCommands
import Foundation

struct RevisionGraphHoverRef: Hashable, Sendable {
    let completeName: String
    let isHead: Bool
    let isRemote: Bool
    let remote: String
    let localName: String
    let mergeWith: String
    let trackingRemote: String
    let isNestledVirtual: Bool
    let trackingBranchIsGone: Bool

    init(_ reference: RevisionReference) {
        completeName = reference.id
        isHead = reference.kind == .localBranch || reference.kind == .currentBranch
        isRemote = reference.kind == .remoteBranch
        remote = reference.remoteName ?? ""
        localName = reference.localName
        mergeWith = isHead ? reference.mergeWith ?? "" : ""
        trackingRemote = isHead ? reference.trackingRemote ?? "" : ""
        isNestledVirtual = false
        trackingBranchIsGone = false
    }

    init(nestled source: RevisionReference, completeName: String, trackingBranchIsGone: Bool) {
        let source = RevisionGraphHoverRef(source)
        self.completeName = completeName
        isHead = source.isRemote
        isRemote = source.isHead
        remote = source.trackingRemote
        trackingRemote = source.remote
        mergeWith = source.localName
        localName = Self.localName(isRemote: source.isHead, remote: source.trackingRemote, name: Self.parseName(completeName))
        isNestledVirtual = true
        self.trackingBranchIsGone = trackingBranchIsGone
    }

    init?(hit: RevisionLabelHit) {
        guard !hit.isStash else { return nil }
        if let source = hit.virtualSource, let target = hit.virtualTarget {
            self.init(nestled: source, completeName: target, trackingBranchIsGone: hit.reference.name == AheadBehindData.goneSymbol)
        } else {
            self.init(hit.reference)
        }
    }

    func isTrackingRemote(_ other: RevisionGraphHoverRef) -> Bool {
        isHead && other.isRemote && mergeWith == other.localName && trackingRemote == other.remote
    }

    static func parseName(_ completeName: String) -> String {
        let name: Substring
        if completeName.hasPrefix("refs/heads/") {
            name = completeName.dropFirst("refs/heads/".count)
        } else if completeName.hasPrefix("refs/remotes/") {
            name = completeName.dropFirst("refs/remotes/".count)
        } else if completeName.hasPrefix("refs/tags/") {
            name = completeName.dropFirst("refs/tags/".count)
        } else if let range = completeName.range(of: "refs/") {
            name = completeName[range.upperBound...]
        } else {
            name = Substring(completeName)
        }
        return name.isEmpty ? completeName : String(name)
    }

    static func localName(isRemote: Bool, remote: String, name: String) -> String {
        guard isRemote, !remote.isEmpty, name.hasPrefix(remote + "/"), name.count > remote.count + 1 else { return name }
        return String(name.dropFirst(remote.count + 1))
    }
}

@MainActor
final class RevisionGraphHoverHighlight {
    static let debounce: Duration = .milliseconds(100)

    struct Graph {
        var rowIDs: [RevisionID]
        var segmentParentIDs: [[RevisionID]]
        var parentIDs: [RevisionID: [RevisionID]]
        var references: [RevisionID: [RevisionReference]]

        init(layout: RevisionGraphLayout, commits: [RevisionID: Commit]) {
            rowIDs = layout.rows.map(\.commitID)
            segmentParentIDs = layout.rows.map(\.segmentParentIDs)
            parentIDs = layout.parentIDs
            references = commits.mapValues(\.references)
        }
    }

    private let graph: () -> Graph
    private let visibleRange: () -> Range<Int>
    private var pending: Task<Void, Never>?
    private var generation = 0

    private(set) var highlightedIDs: Set<RevisionID>?
    private(set) var isDirty = false

    init(graph: @escaping () -> Graph, visibleRange: @escaping () -> Range<Int>) {
        self.graph = graph
        self.visibleRange = visibleRange
    }

    func consumeIsDirty() -> Bool {
        defer { isDirty = false }
        return isDirty
    }

    func clear() {
        guard highlightedIDs != nil else { return }
        highlightedIDs = nil
        isDirty = true
    }

    func cancel() {
        generation += 1
        pending?.cancel()
        pending = nil
    }

    func set(_ reference: RevisionGraphHoverRef?, row: Int = -1) async {
        cancel()
        let token = generation
        let task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.debounce) } catch { return }
            guard let self, token == self.generation else { return }
            self.compute(reference, row: row, isCancelled: { token != self.generation })
        }
        pending = task
        await task.value
    }

    @discardableResult
    func compute(_ reference: RevisionGraphHoverRef?, row rowIndex: Int, isCancelled: () -> Bool = { false }) -> Bool {
        guard let reference, rowIndex >= 0 else {
            clear()
            return true
        }
        if isCancelled() { return false }

        let graph = graph()
        let visibleRange = visibleRange()
        guard graph.rowIDs.indices.contains(rowIndex) else { return false }
        let hoveredID = graph.rowIDs[rowIndex]

        let maxChildrenAbove = max(50, visibleRange.count)
        var visibleIDs = Set<RevisionID>(minimumCapacity: maxChildrenAbove + 2 * visibleRange.count)
        func addIDAndParents(_ row: Int) -> RevisionID? {
            guard graph.rowIDs.indices.contains(row) else { return nil }
            let id = graph.rowIDs[row]
            visibleIDs.insert(id)
            visibleIDs.formUnion(graph.segmentParentIDs[row])
            return id
        }
        func isInBranchGroup(_ other: RevisionReference) -> Bool {
            let other = RevisionGraphHoverRef(other)
            return reference.isTrackingRemote(other) || other.isTrackingRemote(reference)
                || (reference.isNestledVirtual && !reference.trackingBranchIsGone && reference.completeName == other.completeName)
        }
        func hasBranchGroupRef(_ id: RevisionID) -> Bool {
            graph.references[id]?.contains(where: isInBranchGroup) == true
        }

        _ = addIDAndParents(rowIndex)

        let checkOtherRefs = reference.isNestledVirtual
            ? !reference.trackingBranchIsGone
            : (reference.isRemote || (reference.isHead && !reference.mergeWith.isEmpty)) && !hasBranchGroupRef(hoveredID)

        var belowID: RevisionID?
        let visibleTo = visibleRange.lowerBound + visibleRange.count - 1
        if rowIndex + 1 <= visibleTo {
            for row in (rowIndex + 1)...visibleTo {
                guard let id = addIDAndParents(row) else { return false }
                if checkOtherRefs && hasBranchGroupRef(id) { belowID = id }
            }
        }

        var ancestorIDs = Set<RevisionID>()
        walkAncestors(hoveredID, into: &ancestorIDs, visibleIDs: visibleIDs, parents: graph.parentIDs)
        if let belowID {
            walkAncestors(belowID, into: &ancestorIDs, visibleIDs: visibleIDs, parents: graph.parentIDs)
        } else if checkOtherRefs {
            let searchFrom = max(0, visibleRange.lowerBound - maxChildrenAbove)
            if rowIndex - 1 >= searchFrom {
                for row in stride(from: rowIndex - 1, through: searchFrom, by: -1) {
                    guard let id = addIDAndParents(row) else { return false }
                    if hasBranchGroupRef(id) {
                        walkAncestors(id, into: &ancestorIDs, visibleIDs: visibleIDs, parents: graph.parentIDs)
                        break
                    }
                }
            }
        }

        let highlighted: Set<RevisionID>? = ancestorIDs.isEmpty ? nil : ancestorIDs
        if highlighted == highlightedIDs { return false }
        if isCancelled() { return false }
        highlightedIDs = highlighted
        isDirty = true
        return true
    }

    private func walkAncestors(_ start: RevisionID, into result: inout Set<RevisionID>, visibleIDs: Set<RevisionID>,
                               parents: [RevisionID: [RevisionID]]) {
        var stack = [start]
        var visited = Set<RevisionID>()
        while let current = stack.popLast() {
            guard visited.insert(current).inserted, !result.contains(current) else { continue }
            if visibleIDs.contains(current) { result.insert(current) }
            stack.append(contentsOf: (parents[current] ?? []).reversed())
        }
    }
}
