import Foundation

@main
private enum RevisionGraphLayoutTests {
    static func main() async {
        testLinearHistory()
        testRelativeGraphState()
        testRelativeTraversalContinuesAfterMergeDiamond()
        testExplicitTrackingRelationships()
        testMergeAndLaneReuse()
        testDetachedRevisionUsesRightLane()
        testFilteredHistoryConnectsVisibleAncestors()
        testCommonParentSharing()
        testUpstreamStraighteningFixture()
        testUpstreamIncomingMergeFixture()
        testUpstreamReducedCrossingFixture()
        testUpstreamDiagonalCrossingFixture()
        testOctopusMergeIsCappedAndDeterministic()
        testRevisionSelectionRestoration()
        testAuthorAvatarPresentation()
        ContextMenuStateTests.run()
        RepositoryDetailModelTests.run()
        AppSettingsTests.run()
        do {
            try await GitRepositoryBrowsingDataSourceTests.run()
            try await GitRepositoryMutationTests.runCheckout()
            try await GitRepositoryMutationTests.runStaging()
            try await GitRepositoryMutationTests.runCommitAndAmend()
            try await GitRepositoryMutationTests.runStash()
            try await GitRepositoryMutationTests.runCherryPick()
            try await GitRepositoryMutationTests.runMerge()
            try await GitRepositoryMutationTests.runRebase()
            try await GitRepositoryMutationTests.runRemoteManagement()
            try await GitPullTests.run()
            try await GitPushTests.run()
            if let flagIndex = CommandLine.arguments.firstIndex(of: "--verify-mutations"),
               CommandLine.arguments.indices.contains(flagIndex + 1) {
                try await GitRepositoryMutationTests.verifyDisposableClone(
                    at: URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1], isDirectory: true)
                )
            }
        } catch {
            fatalError("GitRepositoryBrowsingDataSourceTests failed: \(error.localizedDescription)")
        }
        print("RevisionGraphLayoutTests: passed")
    }

    private static func testLinearHistory() {
        let commits = history([
            ("a", ["b"]),
            ("b", ["c"]),
            ("c", [])
        ])
        let graph = RevisionGraphLayout.build(
            commits: commits,
            configuration: .init(mergeCommonParentLanes: true, straightenDiagonals: false)
        )

        expect(graph.rows.count == 3, "linear: row count")
        expect(graph.maximumLaneCount == 1, "linear: one lane")
        expect(graph.rows.allSatisfy { $0.nodeLane == 0 && $0.laneCount == 1 }, "linear: nodes stay in lane zero")
        expect(graph.rows[1].edges.contains { $0.role == .incoming && $0.topLane == 0 }, "linear: incoming segment survives")
        expect(graph.rows[1].edges.contains { $0.role == .parent(primary: true) && $0.bottomLane == 0 }, "linear: primary parent continues")
    }

    private static func testExplicitTrackingRelationships() {
        let local = RevisionReference(
            id: "local",
            name: "feature/topic",
            kind: .localBranch,
            trackingRemote: "upstream",
            mergeWith: "review/topic"
        )
        let tracked = RevisionReference(id: "tracked", name: "upstream/review/topic", kind: .remoteBranch)
        let sameSuffixWrongRemote = RevisionReference(id: "wrong-remote", name: "origin/review/topic", kind: .remoteBranch)
        let sameRemoteWrongBranch = RevisionReference(id: "wrong-branch", name: "upstream/feature/topic", kind: .remoteBranch)

        expect(local.tracks(tracked), "refs: configured remote and merge target nest")
        expect(!local.tracks(sameSuffixWrongRemote), "refs: matching suffix does not override the configured remote")
        expect(!local.tracks(sameRemoteWrongBranch), "refs: matching remote does not override the configured merge target")
        expect(tracked.remoteName == "upstream" && tracked.localName == "review/topic", "refs: remote/local names are parsed once in the model")
    }

    private static func testRelativeGraphState() {
        let current = RevisionReference(id: "refs/heads/main", name: "main", kind: .currentBranch)
        let commits = [
            Commit(
                id: "head", shortID: "head", subject: "head", body: "", authorName: "Test", authorEmail: "test@example.com",
                authorDate: .distantPast, committerName: "Test", committerEmail: "test@example.com", commitDate: .distantPast,
                parentIDs: ["base"], references: [current]
            ),
            Commit(
                id: "side", shortID: "side", subject: "side", body: "", authorName: "Test", authorEmail: "test@example.com",
                authorDate: .distantPast, committerName: "Test", committerEmail: "test@example.com", commitDate: .distantPast,
                parentIDs: ["base"], references: []
            ),
            Commit(
                id: "base", shortID: "base", subject: "base", body: "", authorName: "Test", authorEmail: "test@example.com",
                authorDate: .distantPast, committerName: "Test", committerEmail: "test@example.com", commitDate: .distantPast,
                parentIDs: [], references: []
            )
        ]
        let graph = RevisionGraphLayout.build(commits: commits)

        expect(graph.rows[0].isRelative, "relative graph: HEAD is relative")
        expect(!graph.rows[1].isRelative, "relative graph: unrelated branch is not relative")
        expect(graph.rows[2].isRelative, "relative graph: HEAD parent is relative")
        expect(graph.rows[0].edges.contains { $0.isRelative }, "relative graph: HEAD path edge is relative")
        expect(graph.rows[1].edges.contains { !$0.isRelative }, "relative graph: unrelated path edge is non-relative")
    }

    private static func testRelativeTraversalContinuesAfterMergeDiamond() {
        let current = RevisionReference(id: "refs/heads/main", name: "main", kind: .currentBranch)
        func commit(_ id: String, _ parents: [String], refs: [RevisionReference] = []) -> Commit {
            Commit(
                id: id, shortID: id, subject: id, body: "", authorName: "Test", authorEmail: "test@example.com",
                authorDate: .distantPast, committerName: "Test", committerEmail: "test@example.com", commitDate: .distantPast,
                parentIDs: parents, references: refs
            )
        }
        let commits = [
            commit("head", ["left", "right"], refs: [current]),
            commit("right", ["right-a", "right-b"]),
            commit("right-a", ["base"]),
            commit("right-b", ["base"]),
            commit("left", ["left-parent"]),
            commit("left-parent", ["base"]),
            commit("base", [])
        ]
        let graph = RevisionGraphLayout.build(commits: commits)

        expect(graph.rows.allSatisfy(\.isRelative), "relative graph: a visited merge-diamond ancestor does not stop remaining parent traversal")
        expect(graph.rows.flatMap(\.edges).allSatisfy(\.isRelative), "relative graph: every HEAD-reachable merge path remains colored")
    }

    private static func testMergeAndLaneReuse() {
        let commits = history([
            ("a", ["b", "c"]),
            ("b", ["d"]),
            ("c", ["d"]),
            ("d", ["e"]),
            ("e", [])
        ])
        let graph = RevisionGraphLayout.build(
            commits: commits,
            configuration: .init(mergeCommonParentLanes: true, straightenDiagonals: false)
        )

        expect(graph.maximumLaneCount == 2, "merge: exactly two lanes")
        expect(graph.rows[0].edges.filter { if case .parent = $0.role { true } else { false } }.count == 2, "merge: both parents are emitted")
        expect(graph.rows[2].nodeLane == 1, "merge: side branch stays in its lane")
        expect(graph.rows[3].nodeLane == 0, "merge: common parent reuses the released left lane")
        expect(graph.rows[4].nodeLane == 0, "merge: history returns to one lane")
    }

    private static func testDetachedRevisionUsesRightLane() {
        let commits = history([
            ("a", ["c"]),
            ("b", []),
            ("c", [])
        ])
        let graph = RevisionGraphLayout.build(
            commits: commits,
            configuration: .init(mergeCommonParentLanes: true, straightenDiagonals: false)
        )

        expect(graph.rows[1].nodeLane == 1, "detached: independent node is appended on the right")
        expect(graph.rows[2].nodeLane == 0, "detached: carried history remains on the left")
    }

    private static func testFilteredHistoryConnectsVisibleAncestors() {
        let complete = history([
            ("a", ["b"]),
            ("b", ["c"]),
            ("c", [])
        ])
        let visible = [complete[0], complete[2]]
        let graph = RevisionGraphLayout.build(commits: visible, completeHistory: complete)

        expect(graph.maximumLaneCount == 1, "filter: hidden linear ancestor does not add lanes")
        expect(graph.rows[0].edges.contains { $0.bottomLane == 0 }, "filter: visible descendant connects to visible ancestor")
        expect(graph.rows[1].edges.contains { $0.topLane == 0 }, "filter: collapsed segment reaches the visible parent")
    }

    private static func testCommonParentSharing() {
        let commits = history([
            ("a", ["b", "c", "d"]),
            ("b", ["z"]),
            ("c", ["z"]),
            ("d", ["z"]),
            ("x", []),
            ("z", [])
        ])
        let graph = RevisionGraphLayout.build(
            commits: commits,
            configuration: .init(mergeCommonParentLanes: true, straightenDiagonals: false)
        )

        expect(graph.rows.last?.nodeLane == 0, "common parent: shared segments converge on the primary lane")
        expect(graph.maximumLaneCount <= 4, "common parent: shared crossings do not grow without bound")
        for row in graph.rows {
            let signatures = Set(row.edges.map { "\($0.topLane.map(String.init) ?? "-"):\($0.centerLane):\($0.bottomLane.map(String.init) ?? "-"):\($0.colorIndex)" })
            expect(signatures.count == row.edges.count, "common parent: shared edges are not drawn twice")
        }
    }

    private static func testUpstreamStraighteningFixture() {
        let commits = history([
            ("8", ["7", "2"]),
            ("7", ["5", "6"]),
            ("6", ["5"]),
            ("5", ["4"]),
            ("4", ["1", "3"]),
            ("3", ["1"]),
            ("2", ["1"]),
            ("1", [])
        ])
        let graph = RevisionGraphLayout.build(
            commits: commits,
            configuration: .init(mergeCommonParentLanes: true, straightenDiagonals: false)
        )

        expect(graph.rows.map(\.nodeLane) == [0, 0, 1, 0, 0, 1, 1, 0], "upstream fixture: node lanes")
        expect(graph.rows.map(\.laneCount) == [1, 2, 3, 3, 3, 3, 2, 1], "upstream fixture: row lane counts")
    }

    private static func testUpstreamIncomingMergeFixture() {
        let commits = history([
            ("8", ["7", "5"]),
            ("7", ["4", "6"]),
            ("6", ["4"]),
            ("5", ["2", "4"]),
            ("4", ["1", "3"]),
            ("3", ["1"]),
            ("2", ["1"]),
            ("1", [])
        ])
        let graph = RevisionGraphLayout.build(
            commits: commits,
            configuration: .init(mergeCommonParentLanes: true, straightenDiagonals: false)
        )

        let nodeLanes = graph.rows.map(\.nodeLane)
        let laneCounts = graph.rows.map(\.laneCount)
        expect(nodeLanes == [0, 0, 1, 2, 0, 1, 1, 0], "incoming fixture: node lanes \(nodeLanes)")
        expect(laneCounts == [1, 2, 3, 3, 3, 3, 2, 1], "incoming fixture: row lane counts \(laneCounts)")
    }

    private static func testUpstreamReducedCrossingFixture() {
        let commits = history([
            ("8", ["7", "5"]),
            ("7", ["4", "6"]),
            ("6", ["4"]),
            ("5", ["2", "4"]),
            ("4", ["1", "3"]),
            ("3", ["1"]),
            ("2", ["1"]),
            ("1", [])
        ])
        let graph = RevisionGraphLayout.build(
            commits: commits,
            configuration: .init(mergeCommonParentLanes: false, straightenDiagonals: false)
        )
        let nodeLanes = graph.rows.map(\.nodeLane)
        let laneCounts = graph.rows.map(\.laneCount)

        expect(nodeLanes == [0, 0, 1, 2, 0, 1, 2, 0], "reduced fixture: node lanes \(nodeLanes)")
        expect(laneCounts == [1, 2, 3, 3, 3, 3, 3, 1], "reduced fixture: row lane counts \(laneCounts)")
    }

    private static func testUpstreamDiagonalCrossingFixture() {
        let commits = history([
            ("0", ["1", "3"]),
            ("1", ["2"]),
            ("2", ["R", "5", "4"]),
            ("3", ["R"]),
            ("4", ["R"]),
            ("5", ["R"]),
            ("R", [])
        ])
        let graph = RevisionGraphLayout.build(
            commits: commits,
            configuration: .init(mergeCommonParentLanes: false, straightenDiagonals: true)
        )
        let nodeLanes = graph.rows.map(\.nodeLane)
        let laneCounts = graph.rows.map(\.laneCount)

        expect(nodeLanes == [0, 0, 0, 3, 1, 2, 0], "diagonal fixture: node lanes \(nodeLanes)")
        expect(laneCounts == [1, 2, 3, 4, 4, 4, 1], "diagonal fixture: row lane counts \(laneCounts)")
    }

    private static func testOctopusMergeIsCappedAndDeterministic() {
        let parentIDs = (0..<45).map { "p\($0)" }
        var specs: [(String, [String])] = [("head", parentIDs)]
        specs.append(contentsOf: parentIDs.map { ($0, ["root"]) })
        specs.append(("root", []))
        let commits = history(specs)

        let first = RevisionGraphLayout.build(commits: commits)
        let second = RevisionGraphLayout.build(commits: commits)
        expect(first == second, "octopus: graph layout is deterministic")
        expect(first.maximumLaneCount == RevisionGraphLayout.maximumVisibleLanes, "octopus: visible lane count is capped")
        expect(first.rows.allSatisfy { row in
            row.nodeLane < RevisionGraphLayout.maximumVisibleLanes
                && row.edges.allSatisfy { edge in
                    edge.centerLane < RevisionGraphLayout.maximumVisibleLanes
                        && (edge.topLane ?? 0) < RevisionGraphLayout.maximumVisibleLanes
                        && (edge.bottomLane ?? 0) < RevisionGraphLayout.maximumVisibleLanes
                }
        }, "octopus: no emitted geometry exceeds the cap")
    }

    private static func testRevisionSelectionRestoration() {
        let previous = history((0...600).map { index in
            ("r\(index)", index == 600 ? [] : ["r\(index + 1)"])
        })
        let refreshed = previous
        expect(
            RevisionSelectionRestorer.restoredID(
                requestedID: "r500",
                previousCommits: previous,
                refreshedCommits: refreshed
            ) == "r500",
            "refresh retains an existing selection hundreds of rows down"
        )

        let withoutSelected = refreshed.filter { $0.id != "r500" }
        expect(
            RevisionSelectionRestorer.restoredID(
                requestedID: "r500",
                previousCommits: previous,
                refreshedCommits: withoutSelected
            ) == "r501",
            "missing selection falls back to its nearest surviving parent"
        )

        let head = Commit(
            id: "new-head", shortID: "new", subject: "new", body: "", authorName: "Test", authorEmail: "test@example.com",
            authorDate: .distantPast, committerName: "Test", committerEmail: "test@example.com", commitDate: .distantPast,
            parentIDs: [], references: [RevisionReference(id: "HEAD", name: "main", kind: .head)]
        )
        expect(
            RevisionSelectionRestorer.restoredID(
                requestedID: "missing",
                previousCommits: [],
                refreshedCommits: [head]
            ) == "new-head",
            "unrelated missing selection falls back to checkout"
        )
    }

    private static func testAuthorAvatarPresentation() {
        expect(
            AuthorAvatarPresentation.make(name: "Albert Einstein", email: "albert@example.com").initials == "AE",
            "avatar uses first and last author initials"
        )
        expect(
            AuthorAvatarPresentation.make(name: "", email: "albert.einstein@example.com").initials == "AE",
            "avatar derives initials from the email local part"
        )
        let first = AuthorAvatarPresentation.make(name: "Albert Einstein", email: "albert@example.com")
        let second = AuthorAvatarPresentation.make(name: "Albert Einstein", email: "albert@example.com")
        expect(first == second, "avatar color and initials are deterministic")
    }

    private static func history(_ specs: [(String, [String])]) -> [Commit] {
        specs.enumerated().map { index, spec in
            Commit(
                id: spec.0,
                shortID: spec.0,
                subject: spec.0,
                body: "",
                authorName: "Test",
                authorEmail: "test@example.com",
                authorDate: Date(timeIntervalSince1970: TimeInterval(10_000 - index)),
                committerName: "Test",
                committerEmail: "test@example.com",
                commitDate: Date(timeIntervalSince1970: TimeInterval(10_000 - index)),
                parentIDs: spec.1,
                references: []
            )
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("RevisionGraphLayoutTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
