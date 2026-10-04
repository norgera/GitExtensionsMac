@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import Foundation
import AppKit



@MainActor
private final class DeterministicTestLifecycle: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return .terminateCancel
    }
}

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
    @MainActor private static let lifecycle = DeterministicTestLifecycle()
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Deterministic UI tests")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        AvatarService.shared.store = AvatarImageStore(transport: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        })
        application.delegate = lifecycle
        var completed = false
        Task { @MainActor in
            await run()
            completed = true
            application.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                application.postEvent(event, atStart: true)
            }
        }
        while !completed { application.run() }
    }

    @MainActor
    static func run() async {
        if CommandLine.arguments.contains("--backend-parity-only") {
            do { try await BackendParityTests.run() }
            catch { fatalError("BackendParityTests failed: \(error)") }
            return
        }
        if CommandLine.arguments.contains("--cli-only") {
            do { try await CommandLineTests.run() }
            catch { fatalError("CommandLineTests failed: \(error)") }
            return
        }
        if CommandLine.arguments.contains("--built-in-plugins-only") {
            do { try await BuiltInPluginTests.run() }
            catch { fatalError("BuiltInPluginTests failed: \(error)") }
            return
        }
        if CommandLine.arguments.contains("--build-adapters-only") {
            do { try await BuildServerAdapterTests.run() }
            catch { fatalError("BuildServerAdapterTests failed: \(error)") }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--graph-repository"),
           CommandLine.arguments.indices.contains(index + 1) {
            do {
                let module = GitRepositoryModule(repositoryURL: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
                let commits = try await GitRepositoryModuleTests.readRevisions(from: module)
                let graph = await Task.detached { RevisionGraphLayout.build(commits: commits) }.value
                expect(graph.rows.count == commits.count, "repository graph: every streamed revision is represented")
                let positions = Dictionary(uniqueKeysWithValues: graph.rows.enumerated().map { ($0.element.commitID, $0.offset) })
                for (child, parents) in graph.parentIDs {
                    for parent in parents {
                        if let childRow = positions[child], let parentRow = positions[parent] {
                            expect(childRow < parentRow, "repository graph: every loaded parent follows its child")
                        }
                    }
                }
                print("Repository graph read-only verification passed: \(graph.rows.count) revisions")
            } catch { fatalError("Repository graph verification failed: \(error.localizedDescription)") }
            return
        }
        if CommandLine.arguments.contains("--avatars-only") {
            do { try await AvatarProviderTests.run() }
            catch { fatalError("AvatarProviderTests failed: \(error)") }
            return
        }
        if CommandLine.arguments.contains("--output-history-only") {
            do { try await OutputHistoryTests.run() }
            catch { fatalError("OutputHistoryTests failed: \(error)") }
            return
        }
        if CommandLine.arguments.contains("--revision-compare-only") {
            do { try await RevisionComparisonTests.run() }
            catch { fatalError("RevisionComparisonTests failed: \(error.localizedDescription)") }
            return
        }
        if CommandLine.arguments.contains("--file-history-only") {
            do { try await FileHistoryTests.run() }
            catch { fatalError("FileHistoryTests failed: \(error.localizedDescription)") }
            return
        }
        if CommandLine.arguments.contains("--blame-only") {
            do { try await BlameTests.run() }
            catch { fatalError("BlameTests failed: \(error.localizedDescription)") }
            return
        }
        if CommandLine.arguments.contains("--file-status-only") {
            do { try await FileStatusTests.run() }
            catch { fatalError("FileStatusTests failed: \(error.localizedDescription)") }
            return
        }
        if CommandLine.arguments.contains("--commit-info-only") {
            do { try await CommitInfoTests.run() }
            catch { fatalError("CommitInfoTests failed: \(error.localizedDescription)") }
            return
        }
        if CommandLine.arguments.contains("--shell-only") {
            do { try await AppShellTests.run() }
            catch { fatalError("AppShellTests failed: \(error.localizedDescription)") }
            return
        }
        if CommandLine.arguments.contains("--browser-only") {
            do { try await BrowserTests.run() }
            catch { fatalError("BrowserTests failed: \(error.localizedDescription)") }
            return
        }
        if CommandLine.arguments.contains("--grid-only") {
            ContextMenuStateTests.run()
            AppSettingsTests.run()
            do { try await RevisionGridTests.run() }
            catch { fatalError("RevisionGridTests failed: \(error.localizedDescription)") }
            return
        }
        if CommandLine.arguments.contains("--hosts-only") {
            do { try await RepositoryHostingTests.run() }
            catch { fatalError("RepositoryHostingTests failed: \(error)") }
            return
        }
        if CommandLine.arguments.contains("--plugins-only") {
            do { try await ApplicationPluginsTests.run() }
            catch { fatalError("ApplicationPluginsTests failed: \(error)") }
            return
        }
        if CommandLine.arguments.contains("--scripts-only") {
            do { try await ApplicationScriptsTests.run() }
            catch { fatalError("ApplicationScriptsTests failed: \(error)") }
            return
        }
        if CommandLine.arguments.contains("--command-log-only") {
            do { try await CommandLogTests.run() }
            catch { fatalError("CommandLogTests failed: \(error)") }
            return
        }
        if CommandLine.arguments.contains("--settings-only") {
            AppSettingsTests.run()
            do { try await GitSettingsTests.run(); try await AppSettingsTests.runSettingsTree(); try await AppSettingsTests.runRepositoryScopes() }
            catch { fatalError("GitSettingsTests failed: \(error)") }
            return
        }
        if CommandLine.arguments.contains("--archive-only") {
            ContextMenuStateTests.run()
            do { try await GitArchiveTests.run() }
            catch { fatalError("GitArchiveTests failed: \(error)") }
            return
        }
        if CommandLine.arguments.contains("--patches-only") {
            do { try await GitPatchTests.run() }
            catch { fatalError("GitPatchTests failed: \(error)") }
            return
        }
        if CommandLine.arguments.contains("--file-viewer-only") {
            FileViewerTests.run()
            do {
                try await FileViewerParityTests.run()
                try await GitRepositoryModuleTests.runFileViewer()
            } catch {
                fatalError("FileViewerRepositoryTests failed: \(error.localizedDescription)")
            }
            return
        }
        if CommandLine.arguments.contains("--lost-objects-only") {
            do { try await RecoverLostObjectsTests.run() }
            catch { fatalError("RecoverLostObjectsTests failed: \(error.localizedDescription)") }
            return
        }
        if CommandLine.arguments.contains("--sparse-only") {
            do { try await SparseWorkingCopyTests.run() }
            catch { fatalError("SparseWorkingCopyTests failed: \(error.localizedDescription)") }
            return
        }
        if CommandLine.arguments.contains("--file-editors-only") {
            ContextMenuStateTests.run()
            do { try await RepositoryFileEditorTests.run() }
            catch { fatalError("RepositoryFileEditorTests failed: \(error.localizedDescription)") }
            return
        }
        if CommandLine.arguments.contains("--left-panel-only") {
            ContextMenuStateTests.run()
            AppSettingsTests.run()
            do { try await LeftPanelTests.run() }
            catch { fatalError("LeftPanelTests failed: \(error.localizedDescription)") }
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
        if CommandLine.arguments.contains("--clean-only") {
            RepositoryChangedNotifierTests.run()
            do {
                try await GitCleanTests.run()
            } catch {
                fatalError("GitCleanTests failed: \(error.localizedDescription)")
            }
            return
        }
        if CommandLine.arguments.contains("--revert-only") {
            ContextMenuStateTests.run()
            RepositoryChangedNotifierTests.run()
            do {
                try await GitRevertTests.run()
            } catch {
                fatalError("GitRevertTests failed: \(error.localizedDescription)")
            }
            return
        }
        if CommandLine.arguments.contains("--bisect-only") {
            ContextMenuStateTests.run()
            RepositoryChangedNotifierTests.run()
            do {
                try await GitBisectTests.run()
            } catch {
                fatalError("GitBisectTests failed: \(error.localizedDescription)")
            }
            return
        }
        if CommandLine.arguments.contains("--reflog-only") {
            AppSettingsTests.run()
            do {
                try await GitReflogTests.run()
            } catch {
                fatalError("GitReflogTests failed: \(error.localizedDescription)")
            }
            return
        }
        if CommandLine.arguments.contains("--worktrees-only") {
            ContextMenuStateTests.run()
            RepositoryChangedNotifierTests.run()
            do { try await GitWorktreeTests.run() } catch { fatalError("GitWorktreeTests failed: \(error.localizedDescription)") }
            return
        }
        if CommandLine.arguments.contains("--submodules-only") {
            ContextMenuStateTests.run()
            RepositoryChangedNotifierTests.run()
            do { try await GitSubmoduleTests.run() } catch { fatalError("GitSubmoduleTests failed: \(error.localizedDescription)") }
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
        testGraphConfigurationAndOrdering()
        testUpstreamGraphParity()
        testLargeGraphBatches()
        await testDeepHistoryOnBackgroundTask()
        await testIncrementalGraphCache()
        testRevisionSelectionRestoration()
        testAuthorAvatarPresentation()
        if CommandLine.arguments.contains("--graph-only") {
            print("Revision graph focused tests passed")
            return
        }
        ContextMenuStateTests.run()
        RepositoryDetailModelTests.run()
        AppSettingsTests.run()
        RepositoryChangedNotifierTests.run()
        FileViewerTests.run()
        do {
            try await FileViewerParityTests.run()
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
            try await GitCleanTests.run()
            try await GitRevertTests.run()
            try await GitBisectTests.run()
            try await GitReflogTests.run()
            try await GitWorktreeTests.run()
            try await GitSubmoduleTests.run()
            try await GitPatchTests.run()
            try await GitArchiveTests.run()
            try await GitSettingsTests.run()
            try await AppSettingsTests.runSettingsTree()
            try await AppSettingsTests.runRepositoryScopes()
            try await CommandLogTests.run()
            try await OutputHistoryTests.run()
            try await AvatarProviderTests.run()
            try await ApplicationScriptsTests.run()
            try await ApplicationPluginsTests.run()
            try await RepositoryHostingTests.run()
            try await BuildServerAdapterTests.run()
            try await BuiltInPluginTests.run()
            try await CommandLineTests.run()
            try await BackendParityTests.run()
            try await RevisionGridTests.run()
            try await BrowserTests.run()
            try await AppShellTests.run()
            try await CommitInfoTests.run()
            try await FileStatusTests.run()
            try await LeftPanelTests.run()
            try await RepositoryFileEditorTests.run()
            try await SparseWorkingCopyTests.run()
            try await RecoverLostObjectsTests.run()
            try await BlameTests.run()
            try await FileHistoryTests.run()
            try await RevisionComparisonTests.run()
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
            row.nodeLane >= 0 && row.edges.allSatisfy { edge in
                    edge.centerLane >= 0
                        && (edge.topLane ?? 0) >= 0
                        && (edge.bottomLane ?? 0) >= 0
                }
        }, "octopus: logical lanes remain valid; only visible width is capped (offscreen geometry is clipped by AppKit)")
    }

    private static func testGraphConfigurationAndOrdering() {
        let commits = history([("merge", ["left", "right"]), ("left", ["root"]), ("right", ["root"]), ("root", [])])
        var configuration = RevisionGraphLayout.Configuration.gitExtensionsDefault
        configuration.highlightedRevision = testRevisionID("right")
        configuration.drawStyle = .highlightSelected
        configuration.colorCount = 4
        let highlighted = RevisionGraphLayout.build(commits: commits, configuration: configuration)
        expect(Set(highlighted.rows.filter(\.isRelative).map(\.commitID)) == Set([testRevisionID("right"), testRevisionID("root")]), "highlight: only selected ancestry is relative")
        expect(highlighted.rows.flatMap(\.edges).allSatisfy { (0..<4).contains($0.colorIndex) }, "theme: all lanes use the configured palette")
        let byID = Dictionary(uniqueKeysWithValues: commits.map { ($0.id, $0) })
        expect(RevisionGridPresentation.laneInfo(layout: highlighted, row: 0, lane: highlighted.rows[0].nodeLane, commits: byID)
               .hasPrefix("* " + commits[0].objectID!.string), "tooltip: revision identity belongs to the located graph node")
        expect(RevisionGridPresentation.laneInfo(layout: highlighted, row: 0, lane: 100, commits: byID).isEmpty, "tooltip: empty lane has no information")
        configuration.onlyFirstParent = true
        let firstParent = RevisionGraphLayout.build(commits: commits, configuration: configuration)
        expect(firstParent.parentIDs[testRevisionID("merge")] == [testRevisionID("left")], "first parent: secondary merge edge omitted")
        let outOfOrder = RevisionGraphLayout.build(commits: [commits[3], commits[0], commits[1], commits[2]])
        let positions = Dictionary(uniqueKeysWithValues: outOfOrder.rows.enumerated().map { ($0.element.commitID, $0.offset) })
        for commit in commits {
            for parent in commit.parentIDs {
                expect(positions[commit.id]! < positions[.object(parent)]!, "score ordering: every child precedes its parent")
            }
        }
    }

    private static func testUpstreamGraphParity() {

        let limited = history([("c", ["unloaded"]), ("b", [])])
        let dangling = RevisionGraphLayout.build(commits: limited)
        expect(dangling.parentIDs[testRevisionID("c")] == [testRevisionID("unloaded")], "unloaded parent: segment kept")
        expect(dangling.rows[1].edges.contains { $0.role == .continuing } && dangling.rows[1].laneCount == 2,
               "unloaded parent: the lane continues through the following rows")


        let skewed = history([("tip", ["mid"]), ("base", []), ("mid", ["base"]), ("side", ["base"])])
        let order = RevisionGraphLayout.build(commits: skewed).rows.map(\.commitID)
        expect(order.firstIndex(of: testRevisionID("mid"))! < order.firstIndex(of: testRevisionID("base"))!
               && order.firstIndex(of: testRevisionID("side"))! < order.firstIndex(of: testRevisionID("base"))!,
               "score ordering: EnsureScoreIsAbove moves ancestors below late children")


        let head = testObjectID("anchor")
        var rows = history([("top", ["anchor"]), ("anchor", [])])
        rows += RevisionCommitBuilder.artificialRevisions(headID: testObjectID("filtered-head"), attachedTo: head)
        let inserted = RevisionGraphLayout.build(commits: rows)
        expect(inserted.rows.map(\.commitID) == [testRevisionID("top"), .workingDirectory, .index, .object(head)],
               "artificial: Insert places Working directory/Index before the anchor")
        expect(inserted.parentIDs[.index] == [] && inserted.parentIDs[.workingDirectory] == [.index],
               "artificial: inserted Index has no segment to the anchor")
        expect(!inserted.rows[1].isRelative && inserted.rows[1].nodeColorIndex != nil, "artificial: colored as ordinary non-relative nodes")


        let shared = history([("m", ["a", "b"]), ("a", ["r"]), ("b", ["r"]), ("x", ["r"]), ("r", [])])
        var normal = RevisionGraphLayout.Configuration.gitExtensionsDefault
        normal.drawStyle = .normal
        let normalEdges = RevisionGraphLayout.build(commits: shared, configuration: normal).rows.flatMap(\.edges).count
        let grayEdges = RevisionGraphLayout.build(commits: shared).rows.flatMap(\.edges).count
        expect(grayEdges >= normalEdges, "draw style: gray style draws secondary shared segments too")


        let isolated = RevisionGraphLayout.build(commits: history([("solo", [])]))
        expect(isolated.rows[0].nodeColorIndex == nil, "node: no lane info → non-relative color")
        let stashRef = RevisionReference(id: "stash@{1}", name: "stash@{1}", kind: .stash)
        let stashRow = RevisionGraphLayout.build(commits: history([("s", [])], refs: ["s": [stashRef]]))
        expect(!stashRow.rows[0].hasReferences, "node: only refs/stash (stash@{0}) makes a square node")


        var curvy = RevisionGraphLayout.Configuration.gitExtensionsDefault
        curvy.renderWithDiagonals = false
        expect(RevisionGraphLayout.build(commits: shared, configuration: curvy).configuration.renderWithDiagonals == false, "config: curvy rendering")


        let pr = RevisionGridPresentation.parseMergeMessage("Merge pull request #12 from user/feature", appendPullRequest: true)
        expect(pr.into == "master" && pr.with == "user/feature by pull request #12", "branch finder: pull request merge")
        let into = RevisionGridPresentation.parseMergeMessage("Merge branch 'topic' into develop", appendPullRequest: false)
        expect(into.into == "develop" && into.with == "topic", "branch finder: branch merged into")
        expect(RevisionGridPresentation.parseMergeMessage("Fix bug", appendPullRequest: true).into == nil, "branch finder: ordinary subject")
        let merge = history([("m2", ["main1", "topic1"]), ("topic1", ["base"]), ("main1", ["base"]), ("base", [])])
        let mergeLayout = RevisionGraphLayout.build(commits: merge)
        var merged = merge
        merged[0] = Commit(id: merge[0].id, shortID: "m2", subject: "Merge branch 'topic' into main", body: "", authorName: "", authorEmail: "",
                           authorDate: .distantPast, committerName: "", committerEmail: "", commitDate: .distantPast,
                           parentIDs: merge[0].parentIDs, references: [], kind: .revision)
        let byID = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
        let topicRow = mergeLayout.rows.firstIndex { $0.commitID == testRevisionID("topic1") }!
        let info = RevisionGridPresentation.laneInfo(layout: mergeLayout, row: topicRow, lane: mergeLayout.rows[topicRow].nodeLane, commits: byID)
        expect(info.contains("Branch: topic"), "lane tooltip: second-parent branch named by the merge message\n\(info)")
        let missing = RevisionGridPresentation.laneInfo(layout: dangling, row: 1, lane: 0, commits: Dictionary(uniqueKeysWithValues: limited.map { ($0.id, $0) }))
        expect(!missing.isEmpty, "lane tooltip: node lane resolves")
    }

    private static func testLargeGraphBatches() {
        let count = 3_000
        let commits = history((0..<count).map { ("large\($0)", $0 + 1 < count ? ["large\($0 + 1)"] : []) })
        let partial = RevisionGraphLayout.build(commits: Array(commits.prefix(200)))
        let complete = RevisionGraphLayout.build(commits: commits)
        expect(complete.rows.count == count && complete.maximumLaneCount == 1, "large history: linear batches stay in one lane")
        expect(partial.rows.map(\.commitID) == complete.rows.prefix(200).map(\.commitID), "large history: existing row identities retain batch order")
        expect(complete.rows.allSatisfy { $0.nodeLane == 0 }, "large history: node positions remain stable")
    }

    private static func testIncrementalGraphCache() async {
        let count = 2_000
        let commits = history((0..<count).map { index in
            let parents = index + 1 >= count ? [] : index % 100 == 0 && index + 4 < count
                ? ["cache\(index + 1)", "cache\(index + 3)", "cache\(index + 4)"] : ["cache\(index + 1)"]
            return ("cache\(index)", parents)
        })
        do {
            for merge in [true, false] {
                for diagonals in [true, false] {
                    let configuration = RevisionGraphLayout.Configuration(mergeCommonParentLanes: merge, straightenDiagonals: diagonals)
                    let full = RevisionGraphLayout.build(commits: commits, configuration: configuration)
                    let cache = RevisionGraphCache()
                    let first = try await cache.prepare(commits: Array(commits.prefix(100)), configuration: configuration, through: 30, completed: false)
                    expect(first.orderedIDs == commits.prefix(100).map(\.id), "cache: first page contains the complete ordered revision list")
                    expect(!first.layout.rows.isEmpty, "cache: first batch displays prepared lanes while future straightening remains pending")
                    let page = try await cache.prepare(commits: commits, configuration: configuration, through: 60, completed: false)
                    expect(page.preparedRowCount <= 121 && page.layout.rows.count <= 61, "cache: large history only prepares visible rows plus finite look-ahead")
                    expect(page.layout.rows == Array(full.rows.prefix(page.layout.rows.count)), "cache: first-page lanes/edges match the full graph (merge=\(merge), diagonals=\(diagonals))")
                    let unchanged = try await cache.prepare(commits: commits, configuration: configuration, through: 40, completed: false)
                    expect(unchanged.layout == page.layout && unchanged.preparedRowCount == page.preparedRowCount, "cache: scrolling back reuses prepared rows")
                    let next = try await cache.prepare(commits: commits, configuration: configuration, through: 250, completed: false)
                    expect(next.layout.rows == Array(full.rows.prefix(next.layout.rows.count)), "cache: scrolling forward extends stable lanes without changing earlier rows")
                    let complete = try await cache.prepare(commits: commits, configuration: configuration, through: .max, completed: true)
                    expect(complete.layout == full, "cache: completed graph matches full-layout fixtures")
                    let repeated = try await cache.prepare(commits: commits, configuration: configuration, through: .max, completed: true)
                    expect(repeated.layout == complete.layout, "cache: repeated EOF/scroll does not straighten lanes twice")
                    let late = history([("late-cache-child", ["cache0"])])[0]
                    let reordered = try await cache.prepare(commits: commits + [late], configuration: configuration, through: 60, completed: true)
                    let reorderedFull = RevisionGraphLayout.build(commits: commits + [late], configuration: configuration)
                    expect(reordered.orderedIDs == reorderedFull.rows.map(\.commitID), "cache: a late child propagates retained scores and invalidates changed row order")
                    expect(reordered.layout.rows == Array(reorderedFull.rows.prefix(reordered.layout.rows.count)), "cache: reordered prefix has correct lanes")
                }
            }
            let cache = RevisionGraphCache()
            let cancelled = Task { try await cache.prepare(commits: commits, through: .max, completed: true) }
            cancelled.cancel()
            do { _ = try await cancelled.value; expect(false, "cache: cancelled requests must not publish") }
            catch is CancellationError { }
            let restart = try await cache.prepare(commits: Array(commits.prefix(100)), through: 30, completed: true)
            expect(restart.orderedIDs == commits.prefix(100).map(\.id), "cache: cancellation/filter restart cannot reuse stale history")
            let artificial = [Commit(id: .workingDirectory, shortID: "", subject: "Working directory", body: "", authorName: "", authorEmail: "", authorDate: .distantPast, committerName: "", committerEmail: "", commitDate: .distantPast, parentIDs: [], references: [], kind: .workingDirectory),
                              Commit(id: .index, shortID: "", subject: "Commit index", body: "", authorName: "", authorEmail: "", authorDate: .distantPast, committerName: "", committerEmail: "", commitDate: .distantPast, parentIDs: [commits[10].objectID!], references: [], kind: .index)]
            let inserted = try await cache.prepare(commits: Array(commits.prefix(100)) + artificial, through: .max, completed: true)
            let insertedFull = RevisionGraphLayout.build(commits: Array(commits.prefix(100)) + artificial)
            expect(inserted.layout == insertedFull, "cache: artificial rows arriving at EOF invalidate/order/attach exactly like Insert")
            let leadingCache = RevisionGraphCache()
            _ = try await leadingCache.prepare(commits: artificial + Array(commits.prefix(100)), through: 30, completed: false)
            let leading = try await leadingCache.prepare(commits: artificial + commits, through: .max, completed: true)
            expect(leading.layout == RevisionGraphLayout.build(commits: artificial + commits), "cache: leading Working directory/Index rows retain graph semantics across batches")
        } catch { fatalError("Incremental graph cache failed: \(error)") }
    }



    private static func testDeepHistoryOnBackgroundTask() async {
        let count = 16_000
        let commits = history((0..<count).map { ("deep\($0)", $0 + 1 < count ? ["deep\($0 + 1)"] : []) })
        let graph = await Task.detached {
            RevisionGraphLayout.build(commits: commits,
                configuration: .init(mergeCommonParentLanes: true, straightenDiagonals: false))
        }.value
        expect(graph.rows.map(\.commitID) == commits.map(\.id), "deep history: background scoring preserves every row in order")
        expect(graph.maximumLaneCount == 1 && graph.rows.allSatisfy { $0.nodeLane == 0 }, "deep history: background graph stays in one lane")
        let lateChild = history([("late-deep-child", ["deep0"])])[0]
        let skewed = await Task.detached {
            RevisionGraphLayout.build(commits: commits + [lateChild],
                configuration: .init(mergeCommonParentLanes: true, straightenDiagonals: false))
        }.value
        expect(skewed.rows.map(\.commitID) == [lateChild.id] + commits.map(\.id), "deep history: late child raises the entire ancestor chain without recursive teardown")
        let partial = await Task.detached {
            RevisionGraphLayout.build(commits: Array(commits.dropLast()),
                configuration: .init(mergeCommonParentLanes: true, straightenDiagonals: false, onlyFirstParent: true))
        }.value
        expect(partial.rows.map(\.commitID) == commits.dropLast().map(\.id), "deep history: incomplete parent nodes also tear down safely in first-parent mode")
        let filtered = await Task.detached {
            RevisionGraphLayout.build(commits: [commits[0], commits[count - 1]], completeHistory: commits)
        }.value
        expect(filtered.parentIDs[commits[0].id] == [commits[count - 1].id], "deep history: hidden ancestor traversal is iterative and preserves visible parent identity")
        let cache = RevisionGraphCache()
        let running = Task.detached { try await cache.prepare(commits: commits, through: .max, completed: true) }
        try? await Task.sleep(for: .milliseconds(10))
        running.cancel()
        do {
            _ = try await running.value
            expect(false, "deep history: an executing graph worker must stop on cancellation")
        } catch is CancellationError { }
        catch { fatalError("Deep-history cancellation failed: \(error)") }
        do {
            let restarted = try await cache.prepare(commits: Array(commits.prefix(100)), through: .max, completed: true)
            expect(restarted.orderedIDs == commits.prefix(100).map(\.id), "deep history: cancelled partial cache does not leak into the next generation")
        } catch { fatalError("Deep-history restart failed: \(error)") }
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

    private static func history(_ specs: [(String, [String])], refs: [String: [RevisionReference]] = [:]) -> [Commit] {
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
                references: refs[spec.0] ?? []
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
