@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import Foundation

func testObjectID(_ label: String) -> ObjectID {
    var words: [UInt32] = [2_166_136_261, 2_166_136_263, 2_166_136_269, 2_166_136_283, 2_166_136_301]
    for byte in label.utf8 {
        for index in words.indices {
            words[index] ^= UInt32(byte) &+ UInt32(index)
            words[index] &*= 16_777_619
        }
    }
    let hexadecimal = words.map { String(format: "%08x", $0) }.joined()
    return try! ObjectID.parse(hexadecimal)
}

func testRevisionID(_ label: String) -> RevisionID { .object(testObjectID(label)) }

@main
private enum RevisionGraphLayoutTests {
    static func main() async {
        if CommandLine.arguments.contains("--file-viewer-only") {
            FileViewerTests.run()
            do {
                try await GitRepositoryModuleTests.runFileViewer()
            } catch {
                fatalError("FileViewerRepositoryTests failed: \(error.localizedDescription)")
            }
            return
        }
        if CommandLine.arguments.contains("--left-panel-only") {
            ContextMenuStateTests.run()
            AppSettingsTests.run()
            print("LeftPanelTests: passed")
            return
        }
        if CommandLine.arguments.contains("--architecture-h-only") {
            ContextMenuStateTests.run()
            RepositoryChangedNotifierTests.run()
            print("ArchitectureHBoundaryTests: passed")
            return
        }
        if CommandLine.arguments.contains("--object-id-only") {
            testObjectIdentity()
            testRevisionSelectionRestoration()
            print("ObjectIDTests: passed")
            return
        }
        if CommandLine.arguments.contains("--revision-reader-only") {
            do {
                testRevisionSelectionRestoration()
                try await GitRepositoryModuleTests.runRevisionReader()
                print("RevisionReaderTests: passed")
            } catch {
                fatalError("RevisionReaderTests failed: \(error.localizedDescription)")
            }
            return
        }
        if CommandLine.arguments.contains("--repository-state-only") {
            do {
                try await GitRepositoryModuleTests.run()
                print("RepositoryStateTests: passed")
            } catch {
                fatalError("RepositoryStateTests failed: \(error.localizedDescription)")
            }
            return
        }
        if CommandLine.arguments.contains("--tags-only") {
            ContextMenuStateTests.run()
            AppSettingsTests.run()
            do {
                try await GitRepositoryMutationTests.runTags()
                try await GitPushTests.run()
            } catch {
                fatalError("TagTests failed: \(error.localizedDescription)")
            }
            print("TagTests: passed")
            return
        }
        if CommandLine.arguments.contains("--remotes-only") {
            ContextMenuStateTests.run()
            AppSettingsTests.run()
            RepositoryChangedNotifierTests.run()
            do {
                try await GitRepositoryMutationTests.runRemoteManagement()
            } catch {
                fatalError("RemoteManagementTests failed: \(error.localizedDescription)")
            }
            print("RemoteManagementTests: passed")
            return
        }
        if CommandLine.arguments.contains("--conflict-resolver-only") {
            do {
                try await GitRepositoryMutationTests.runConflictResolver()
                try await GitRepositoryMutationTests.runMerge()
                try await GitRepositoryMutationTests.runCherryPick()
                try await GitRepositoryMutationTests.runRebase()
            } catch {
                fatalError("ConflictResolverTests failed: \(error.localizedDescription)")
            }
            print("ConflictResolverTests: passed")
            return
        }
        if CommandLine.arguments.contains("--repository-creation-only") {
            do {
                try await GitRepositoryCreationTests.run()
            } catch {
                fatalError("GitRepositoryCreationTests failed: \(error.localizedDescription)")
            }
            return
        }
        if CommandLine.arguments.contains("--reset-only") {
            ContextMenuStateTests.run()
            AppSettingsTests.run()
            RepositoryChangedNotifierTests.run()
            do {
                try await GitResetTests.run()
            } catch {
                fatalError("GitResetTests failed: \(error.localizedDescription)")
            }
            return
        }
        testObjectIdentity()
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
        RepositoryChangedNotifierTests.run()
        FileViewerTests.run()
        do {
            try await GitRepositoryModuleTests.run()
            try await GitRepositoryMutationTests.runCheckout()
            try await GitRepositoryMutationTests.runStaging()
            try await GitRepositoryMutationTests.runCommitAndAmend()
            try await GitRepositoryMutationTests.runStash()
            try await GitRepositoryMutationTests.runCherryPick()
            try await GitRepositoryMutationTests.runMerge()
            try await GitRepositoryMutationTests.runConflictResolver()
            try await GitRepositoryMutationTests.runRebase()
            try await GitRepositoryMutationTests.runRemoteManagement()
            try await GitRepositoryMutationTests.runTags()
            try await GitPullTests.run()
            try await GitPushTests.run()
            try await GitRepositoryCreationTests.run()
            try await GitResetTests.run()
            if let flagIndex = CommandLine.arguments.firstIndex(of: "--verify-mutations"),
               CommandLine.arguments.indices.contains(flagIndex + 1) {
                try await GitRepositoryMutationTests.verifyDisposableClone(
                    at: URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1], isDirectory: true)
                )
            }
        } catch {
            fatalError("GitRepositoryModuleTests failed: \(error.localizedDescription)")
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
                id: testRevisionID("head"), shortID: "head", subject: "head", body: "", authorName: "Test", authorEmail: "test@example.com",
                authorDate: .distantPast, committerName: "Test", committerEmail: "test@example.com", commitDate: .distantPast,
                parentIDs: [testObjectID("base")], references: [current]
            ),
            Commit(
                id: testRevisionID("side"), shortID: "side", subject: "side", body: "", authorName: "Test", authorEmail: "test@example.com",
                authorDate: .distantPast, committerName: "Test", committerEmail: "test@example.com", commitDate: .distantPast,
                parentIDs: [testObjectID("base")], references: []
            ),
            Commit(
                id: testRevisionID("base"), shortID: "base", subject: "base", body: "", authorName: "Test", authorEmail: "test@example.com",
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
                id: testRevisionID(id), shortID: id, subject: id, body: "", authorName: "Test", authorEmail: "test@example.com",
                authorDate: .distantPast, committerName: "Test", committerEmail: "test@example.com", commitDate: .distantPast,
                parentIDs: parents.map(testObjectID), references: refs
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

    private static func testObjectIdentity() {
        let sha1Text = "0123456789abcdef0123456789abcdef01234567"
        let sha256Text = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        let sha1 = try! ObjectID.parse(sha1Text)
        let sha256 = try! ObjectID.parse(sha256Text)
        let sameSHA1 = try! ObjectID.parse(sha1Text)

        expect(sha1.string == sha1Text, "object ID: SHA-1 round trips exactly")
        expect(sha256.string == sha256Text, "object ID: SHA-256 round trips exactly")
        expect(sha1 == sameSHA1, "object ID: equal hashes compare equally")
        expect(Set([sha1, sameSHA1, sha256]).count == 2, "object ID: hashing follows object identity")
        expect((try? ObjectID.parse("WORKTREE")) == nil, "object ID: artificial row names are rejected")
        expect((try? ObjectID.parse(String(repeating: "a", count: 39))) == nil, "object ID: abbreviated hashes are rejected")
        expect((try? ObjectID.parse(String(repeating: "A", count: 40))) == nil, "object ID: non-canonical uppercase hashes are rejected")

        let parent = testObjectID("parent")
        let referenceTarget = Branch(
            id: "refs/heads/main",
            name: "main",
            commitID: sha1,
            isCurrent: true,
            isRemote: false,
            remoteName: nil,
            ahead: 0,
            behind: 0
        )
        let revision = Commit(
            id: .object(sha1),
            shortID: sha1.shortString,
            subject: "Typed revision",
            body: "",
            authorName: "Test",
            authorEmail: "test@example.com",
            authorDate: .distantPast,
            committerName: "Test",
            committerEmail: "test@example.com",
            commitDate: .distantPast,
            parentIDs: [parent],
            references: []
        )
        expect(revision.objectID == sha1 && revision.parentIDs == [parent], "object ID: revisions and parents retain typed associations")
        expect(referenceTarget.commitID == sha1, "object ID: ref targets retain typed associations")
        expect(RevisionID.workingDirectory.objectID == nil, "object ID: Working directory has no Git object identity")
        expect(RevisionID.index.objectID == nil, "object ID: Commit index has no Git object identity")
        expect(RevisionID.workingDirectory != RevisionID.index, "object ID: artificial rows have distinct row identities")

        let command = GitCommand(
            arguments: ["show", "--format=", sha1.string],
            accessesRemote: false,
            changesRepositoryState: false
        )
        expect(command.arguments == ["show", "--format=", sha1Text], "object ID: Git argument conversion preserves the exact hash")
    }

    private static func testRevisionSelectionRestoration() {
        let previous = history((0...600).map { index in
            ("r\(index)", index == 600 ? [] : ["r\(index + 1)"])
        })
        let refreshed = previous
        expect(
            RevisionSelectionRestorer.restoredID(
                requestedID: testRevisionID("r500"),
                previousCommits: previous,
                refreshedCommits: refreshed
            ) == testRevisionID("r500"),
            "refresh retains an existing selection hundreds of rows down"
        )

        let withoutSelected = refreshed.filter { $0.id != testRevisionID("r500") }
        expect(
            RevisionSelectionRestorer.restoredID(
                requestedID: testRevisionID("r500"),
                previousCommits: previous,
                refreshedCommits: withoutSelected
            ) == testRevisionID("r501"),
            "missing selection falls back to its nearest surviving parent"
        )

        let head = Commit(
            id: testRevisionID("new-head"), shortID: "new", subject: "new", body: "", authorName: "Test", authorEmail: "test@example.com",
            authorDate: .distantPast, committerName: "Test", committerEmail: "test@example.com", commitDate: .distantPast,
            parentIDs: [], references: [RevisionReference(id: "HEAD", name: "main", kind: .head)]
        )
        expect(
            RevisionSelectionRestorer.restoredID(
                requestedID: testRevisionID("missing"),
                previousCommits: [],
                refreshedCommits: [head]
            ) == testRevisionID("new-head"),
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
                id: testRevisionID(spec.0),
                shortID: spec.0,
                subject: spec.0,
                body: "",
                authorName: "Test",
                authorEmail: "test@example.com",
                authorDate: Date(timeIntervalSince1970: TimeInterval(10_000 - index)),
                committerName: "Test",
                committerEmail: "test@example.com",
                commitDate: Date(timeIntervalSince1970: TimeInterval(10_000 - index)),
                parentIDs: spec.1.map(testObjectID),
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
