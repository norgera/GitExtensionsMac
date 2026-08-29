@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import Foundation

enum GitPullTests {
    static func run() async throws {
        try testCommandConstruction()
        try await testFetchAndRemoteBranchDiscovery()
        try await testUnshallowFetch()
        try await testFastForwardAndAlreadyCurrentPull()
        try await testMergePull()
        try await testRebasePullAndUnsafeMergeDetection()
        try await testMergeConflict()
        try await testAbortMergeConflict()
        try await testRebaseConflict()
        try await testTagsAndPrune()
        try await testFetchAllAndPruneAll()
        try await testSubmoduleUpdateAfterPull()
        try await testTrackingDetachedAndValidation()
        try await testAutoStashAndFailurePreservation()
        try await testStreamingCancellation()
        try await testGitProcessCancellation()
        print("GitPullTests: passed")
    }

    private static func testCommandConstruction() throws {
        let fetch = RepositoryPullRequest(
            source: .remote("origin"),
            mode: .fetch,
            localBranch: "local branch",
            remoteBranch: "+some branch",
            tagMode: .noTags,
            unshallow: true,
            prune: true,
            pruneTags: true
        )
        try require(
            try GitPullCommandBuilder.arguments(for: fetch, configureFetchParallel: true, configureSubmoduleFetchJobs: true) == [
                "-c", "fetch.parallel=0", "-c", "submodule.fetchjobs=0",
                "fetch", "--progress", "origin", "+somebranch:refs/heads/localbranch",
                "--no-tags", "--unshallow", "--prune", "--force", "--prune-tags"
            ],
            "command builder: Fetch matches Git Extensions argument ordering"
        )

        let pull = RepositoryPullRequest(
            source: .url("/tmp/a remote"),
            mode: .rebase,
            localBranch: "must-not-be-used",
            remoteBranch: "topic",
            tagMode: .allTags
        )
        try require(
            try GitPullCommandBuilder.arguments(for: pull, configureFetchParallel: true, configureSubmoduleFetchJobs: true) == [
                "-c", "fetch.parallel=0", "-c", "submodule.fetchjobs=0",
                "pull", "--rebase", "--progress", "/tmp/a remote", "+topic", "--tags"
            ],
            "command builder: Pull uses Git-level fetch options and never appends a local refspec"
        )

        do {
            _ = try GitPullCommandBuilder.arguments(
                for: RepositoryPullRequest(source: .allRemotes, mode: .merge),
                configureFetchParallel: false,
                configureSubmoduleFetchJobs: false
            )
            throw PullFixtureError("command builder: Pull accepted [ All ]")
        } catch RepositoryPullError.allRemotesRequireFetch {
            // Expected.
        }
    }

    private static func testFetchAndRemoteBranchDiscovery() async throws {
        let fixture = try PullGitFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.clone(named: "Fetch client")
        try fixture.git(["remote", "add", "upstream", fixture.upstreamURL.path], in: repository)
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()

        let branches = try await source.loadRemoteBranchNames(named: "upstream")
        try require(branches.contains("main") && branches.contains("upstream-only"), "fetch: branch discovery is scoped to the selected remote")
        try require(!branches.contains("origin-only"), "fetch: another remote's branch is not leaked")

        let events = PullTestOutputRecorder()
        let result = try await source.performPull(
            RepositoryPullRequest(source: .remote("upstream"), mode: .fetch),
            output: { event in events.append(event) }
        )
        try require(result.outcome == .completed, "fetch: initial fetch completes")
        try require(
            result.command.arguments.starts(with: ["-c", "fetch.parallel=0", "-c", "submodule.fetchjobs=0"]),
            "fetch: undefined parallel settings receive Git Extensions' Git-level overrides"
        )
        try require(try fixture.refExists("refs/remotes/upstream/upstream-only", in: repository), "fetch: initial fetch creates remote-tracking refs")
        try require(!events.events.isEmpty, "fetch: process output is streamed")

        try fixture.git(["config", "fetch.parallel", "2"], in: repository)
        try fixture.git(["config", "submodule.fetchjobs", "3"], in: repository)
        let second = try await source.performPull(
            RepositoryPullRequest(source: .remote("upstream"), mode: .fetch),
            output: { _ in }
        )
        try require(second.outcome == .completed, "fetch: already up-to-date fetch completes")
        try require(
            !second.command.arguments.contains("fetch.parallel=0") && !second.command.arguments.contains("submodule.fetchjobs=0"),
            "fetch: explicit parallel settings suppress Git Extensions' fallback overrides"
        )

        let mapped = try await source.performPull(
            RepositoryPullRequest(source: .remote("upstream"), mode: .fetch, localBranch: "imported branch", remoteBranch: "upstream-only"),
            output: { _ in }
        )
        try require(mapped.outcome == .completed, "fetch: explicit remote-to-local refspec completes")
        try require(try fixture.refExists("refs/heads/importedbranch", in: repository), "fetch: spaces are removed and the selected local branch is updated")
        try require(
            try fixture.git(["rev-parse", "refs/heads/importedbranch"], in: repository).trimmed
                == fixture.git(["rev-parse", "refs/remotes/upstream/upstream-only"], in: repository).trimmed,
            "fetch: local refspec points at the selected remote head"
        )
    }

    private static func testUnshallowFetch() async throws {
        let fixture = try PullGitFixture.make()
        defer { fixture.remove() }
        let peer = try fixture.clone(named: "Unshallow peer")
        try fixture.commit("second\n", path: "second.txt", message: "Second", in: peer)
        try fixture.git(["push", "origin", "main"], in: peer)
        let repository = try fixture.shallowClone(named: "Shallow client")
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let initialState = try await source.loadPullState()
        try require(initialState.isShallow, "unshallow: fixture starts shallow")
        let result = try await source.performPull(
            RepositoryPullRequest(source: .remote("origin"), mode: .fetch, unshallow: true),
            output: { _ in }
        )
        try require(result.outcome == .completed, "unshallow: Fetch completes")
        let state = try await source.loadPullState()
        try require(!state.isShallow, "unshallow: shallow marker is removed")
        try require(Int(try fixture.git(["rev-list", "--count", "HEAD"], in: repository).trimmed) ?? 0 >= 2, "unshallow: complete history is available")
    }

    private static func testFastForwardAndAlreadyCurrentPull() async throws {
        let fixture = try PullGitFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.clone(named: "Fast forward client")
        let peer = try fixture.clone(named: "Fast forward peer")
        try fixture.commit("remote fast-forward\n", path: "remote.txt", message: "Remote fast-forward", in: peer)
        try fixture.git(["push", "origin", "main"], in: peer)

        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let result = try await source.performPull(
            RepositoryPullRequest(source: .remote("origin"), mode: .merge),
            output: { _ in }
        )
        try require(result.outcome == .completed, "pull: fast-forward completes")
        try require(try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed == fixture.git(["rev-parse", "origin/main"], in: repository).trimmed, "pull: HEAD fast-forwards to the remote")
        let repositoryState = try await source.loadRepositoryState()
        try require(
            result.selectedCommitID == repositoryState.identity.headID.map(RevisionID.object),
            "pull: refreshed HEAD is selected"
        )

        let alreadyCurrent = try await source.performPull(
            RepositoryPullRequest(source: .remote("origin"), mode: .merge),
            output: { _ in }
        )
        try require(alreadyCurrent.outcome == .completed, "pull: already up-to-date Pull completes")
    }

    private static func testMergePull() async throws {
        let fixture = try PullGitFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.clone(named: "Merge client")
        let peer = try fixture.clone(named: "Merge peer")
        try fixture.commit("local\n", path: "local-divergence.txt", message: "Local divergence", in: repository)
        try fixture.commit("remote\n", path: "remote-divergence.txt", message: "Remote divergence", in: peer)
        try fixture.git(["push", "origin", "main"], in: peer)

        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let result = try await source.performPull(
            RepositoryPullRequest(source: .remote("origin"), mode: .merge, remoteBranch: "main"),
            output: { _ in }
        )
        try require(result.outcome == .completed, "pull merge: diverged history completes")
        let parents = try fixture.git(["show", "-s", "--format=%P", "HEAD"], in: repository).trimmed.split(separator: " ")
        try require(parents.count == 2, "pull merge: Git creates a merge commit")
        try require(FileManager.default.fileExists(atPath: repository.appendingPathComponent("local-divergence.txt").path), "pull merge: local content remains")
        try require(FileManager.default.fileExists(atPath: repository.appendingPathComponent("remote-divergence.txt").path), "pull merge: remote content is integrated")
    }

    private static func testRebasePullAndUnsafeMergeDetection() async throws {
        let fixture = try PullGitFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.clone(named: "Rebase client")
        let peer = try fixture.clone(named: "Rebase peer")
        try fixture.commit("local\n", path: "local-rebase.txt", message: "Local rebase", in: repository)
        try fixture.commit("remote\n", path: "remote-rebase.txt", message: "Remote rebase", in: peer)
        try fixture.git(["push", "origin", "main"], in: peer)

        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let result = try await source.performPull(
            RepositoryPullRequest(source: .remote("origin"), mode: .rebase, remoteBranch: "main"),
            output: { _ in }
        )
        try require(result.outcome == .completed, "pull rebase: diverged history rebases")
        try require(try fixture.git(["log", "-1", "--format=%s"], in: repository).trimmed == "Local rebase", "pull rebase: local commit remains at HEAD")
        try require(try fixture.git(["rev-list", "--merges", "origin/main..HEAD"], in: repository).trimmed.isEmpty, "pull rebase: local result is linear")

        try fixture.git(["checkout", "-b", "merge-side"], in: repository)
        try fixture.commit("side\n", path: "side.txt", message: "Side", in: repository)
        try fixture.git(["checkout", "main"], in: repository)
        try fixture.commit("main\n", path: "main-after-rebase.txt", message: "Main after rebase", in: repository)
        try fixture.git(["merge", "--no-ff", "merge-side", "-m", "Unpushed merge"], in: repository)
        let hasUnpushedMerge = try await source.hasUnpushedMergeCommit(remote: "origin", branch: "main")
        try require(hasUnpushedMerge, "pull rebase: unpushed merge warning matches upstream no-walk check")
    }

    private static func testMergeConflict() async throws {
        let fixture = try PullGitFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.clone(named: "Merge conflict client")
        let peer = try fixture.clone(named: "Merge conflict peer")
        try fixture.commit("local conflict\n", path: "shared.txt", message: "Local conflict", in: repository)
        try fixture.commit("remote conflict\n", path: "shared.txt", message: "Remote conflict", in: peer)
        try fixture.git(["push", "origin", "main"], in: peer)
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()

        let result = try await source.performPull(
            RepositoryPullRequest(source: .remote("origin"), mode: .merge, remoteBranch: "main"),
            output: { _ in }
        )
        guard case .conflicts(kind: .merge, let paths) = result.outcome else {
            throw PullFixtureError("pull merge conflict: conflict outcome was not returned")
        }
        try require(paths.contains("shared.txt"), "pull merge conflict: conflicted path is retained")
        try require(FileManager.default.fileExists(atPath: repository.appendingPathComponent(".git/MERGE_HEAD").path), "pull merge conflict: merge state remains available to resolver")
        try fixture.write("resolved\n", to: repository.appendingPathComponent("shared.txt"))
        _ = try await source.stage(paths: ["shared.txt"])
        let committed = try await source.commit(RepositoryCommitRequest(
            message: "Resolve pulled merge",
            mode: .normal,
            stageAllBeforeCommit: false,
            allowEmpty: false,
            signOff: false,
            author: nil,
            resetAuthor: false
        ))
        try require(committed.outcome == .completed, "pull merge conflict: solved conflicts can enter the typed commit workflow")
        let parents = try fixture.git(["show", "-s", "--format=%P", "HEAD"], in: repository).trimmed.split(separator: " ")
        try require(parents.count == 2, "pull merge conflict: completing the merge creates a two-parent commit")
        try require(!FileManager.default.fileExists(atPath: repository.appendingPathComponent(".git/MERGE_HEAD").path), "pull merge conflict: successful commit clears merge state")
    }

    private static func testAbortMergeConflict() async throws {
        let fixture = try PullGitFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.clone(named: "Abort merge conflict client")
        let peer = try fixture.clone(named: "Abort merge conflict peer")
        let originalHead = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.commit("local conflict\n", path: "shared.txt", message: "Local conflict", in: repository)
        let localHead = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.commit("remote conflict\n", path: "shared.txt", message: "Remote conflict", in: peer)
        try fixture.git(["push", "origin", "main"], in: peer)
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let result = try await source.performPull(
            RepositoryPullRequest(source: .remote("origin"), mode: .merge, remoteBranch: "main"),
            output: { _ in }
        )
        guard case .conflicts(kind: .merge, _) = result.outcome else {
            throw PullFixtureError("pull merge abort: conflict outcome was not returned")
        }
        let aborted = try await source.abortMerge()
        try require(aborted.outcome == .completed, "pull merge abort: typed abort completes")
        try require(try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed == localHead, "pull merge abort: local pre-Pull HEAD is restored")
        try require(try fixture.git(["merge-base", originalHead, "HEAD"], in: repository).trimmed == originalHead, "pull merge abort: unrelated base history is unchanged")
        try require(!FileManager.default.fileExists(atPath: repository.appendingPathComponent(".git/MERGE_HEAD").path), "pull merge abort: merge state is cleared")
    }

    private static func testRebaseConflict() async throws {
        let fixture = try PullGitFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.clone(named: "Rebase conflict client")
        let peer = try fixture.clone(named: "Rebase conflict peer")
        try fixture.commit("local conflict\n", path: "shared.txt", message: "Local conflict", in: repository)
        try fixture.commit("remote conflict\n", path: "shared.txt", message: "Remote conflict", in: peer)
        try fixture.git(["push", "origin", "main"], in: peer)
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()

        let result = try await source.performPull(
            RepositoryPullRequest(source: .remote("origin"), mode: .rebase, remoteBranch: "main"),
            output: { _ in }
        )
        guard case .conflicts(kind: .rebase, let paths) = result.outcome else {
            throw PullFixtureError("pull rebase conflict: conflict outcome was not returned")
        }
        try require(paths.contains("shared.txt"), "pull rebase conflict: conflicted path is retained")
        let state = try await source.loadPullState()
        try require(state.rebaseInProgress, "pull rebase conflict: sequencer state remains available to continue/skip/abort")
    }

    private static func testTagsAndPrune() async throws {
        let fixture = try PullGitFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.clone(named: "Tags and prune client")
        let peer = try fixture.clone(named: "Tags and prune peer")
        try fixture.commit("tag target\n", path: "tag-target.txt", message: "Tag target", in: peer)
        try fixture.git(["tag", "pull-test-tag"], in: peer)
        try fixture.git(["push", "origin", "main"], in: peer)
        try fixture.git(["push", "origin", "pull-test-tag"], in: peer)

        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        _ = try await source.performPull(
            RepositoryPullRequest(source: .remote("origin"), mode: .fetch, tagMode: .noTags),
            output: { _ in }
        )
        try require(!(try fixture.refExists("refs/tags/pull-test-tag", in: repository)), "fetch tags: --no-tags does not import the new tag")
        _ = try await source.performPull(
            RepositoryPullRequest(source: .remote("origin"), mode: .fetch, tagMode: .allTags),
            output: { _ in }
        )
        try require(try fixture.refExists("refs/tags/pull-test-tag", in: repository), "fetch tags: --tags imports the new tag")
        try fixture.git(["push", "origin", ":refs/tags/pull-test-tag"], in: peer)
        _ = try await source.performPull(
            RepositoryPullRequest(source: .remote("origin"), mode: .fetch, tagMode: .allTags, pruneTags: true),
            output: { _ in }
        )
        try require(!(try fixture.refExists("refs/tags/pull-test-tag", in: repository)), "fetch tags: --prune-tags removes a locally stale remote tag")

        try fixture.git(["branch", "obsolete"], in: peer)
        try fixture.git(["push", "origin", "obsolete"], in: peer)
        _ = try await source.performPull(RepositoryPullRequest(source: .remote("origin"), mode: .fetch), output: { _ in })
        try require(try fixture.refExists("refs/remotes/origin/obsolete", in: repository), "fetch prune: setup remote-tracking branch exists")
        try fixture.git(["push", "origin", "--delete", "obsolete"], in: peer)
        _ = try await source.performPull(
            RepositoryPullRequest(source: .remote("origin"), mode: .fetch, prune: true),
            output: { _ in }
        )
        try require(!(try fixture.refExists("refs/remotes/origin/obsolete", in: repository)), "fetch prune: deleted remote branch is pruned")
    }

    private static func testFetchAllAndPruneAll() async throws {
        let fixture = try PullGitFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.clone(named: "Fetch all client")
        try fixture.git(["remote", "add", "upstream", fixture.upstreamURL.path], in: repository)
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let fetched = try await source.performPull(RepositoryPullRequest(source: .allRemotes, mode: .fetch), output: { _ in })
        try require(fetched.outcome == .completed, "fetch all: command completes")
        try require(try fixture.refExists("refs/remotes/origin/origin-only", in: repository), "fetch all: origin is fetched")
        try require(try fixture.refExists("refs/remotes/upstream/upstream-only", in: repository), "fetch all: upstream is fetched")

        try fixture.git(["branch", "to-prune"], in: fixture.seedURL)
        try fixture.git(["push", "origin", "to-prune"], in: fixture.seedURL)
        _ = try await source.performPull(RepositoryPullRequest(source: .allRemotes, mode: .fetch), output: { _ in })
        try fixture.git(["push", "origin", "--delete", "to-prune"], in: fixture.seedURL)
        let pruned = try await source.performPull(
            RepositoryPullRequest(source: .allRemotes, mode: .fetch, tagMode: .allTags, prune: true),
            output: { _ in }
        )
        try require(pruned.outcome == .completed, "fetch and prune all: command completes")
        try require(!(try fixture.refExists("refs/remotes/origin/to-prune", in: repository)), "fetch and prune all: stale origin ref is removed")
    }

    private static func testSubmoduleUpdateAfterPull() async throws {
        let fixture = try PullGitFixture.make()
        defer { fixture.remove() }
        let submoduleRemote = fixture.rootURL.appendingPathComponent("Pull Submodule Remote.git", isDirectory: true)
        let submoduleSeed = fixture.rootURL.appendingPathComponent("Pull Submodule Seed", isDirectory: true)
        try fixture.git(["init", "--bare", "--initial-branch=main", submoduleRemote.path], in: fixture.rootURL)
        try fixture.git(["init", "--initial-branch=main", submoduleSeed.path], in: fixture.rootURL)
        try fixture.configureIdentity(in: submoduleSeed)
        try fixture.commit("submodule v1\n", path: "version.txt", message: "Submodule v1", in: submoduleSeed)
        try fixture.git(["remote", "add", "origin", submoduleRemote.path], in: submoduleSeed)
        try fixture.git(["push", "-u", "origin", "main"], in: submoduleSeed)

        try fixture.git(
            ["-c", "protocol.file.allow=always", "submodule", "add", submoduleRemote.path, "Modules/Child"],
            in: fixture.seedURL
        )
        try fixture.git(["commit", "-am", "Add submodule"], in: fixture.seedURL)
        try fixture.git(["push", "origin", "main"], in: fixture.seedURL)

        let repository = try fixture.clone(named: "Submodule pull client")
        try fixture.git(["-c", "protocol.file.allow=always", "submodule", "update", "--init", "--recursive"], in: repository)
        let initialSubmoduleHead = try fixture.git(["rev-parse", "HEAD"], in: repository.appendingPathComponent("Modules/Child")).trimmed

        try fixture.commit("submodule v2\n", path: "version.txt", message: "Submodule v2", in: submoduleSeed)
        try fixture.git(["push", "origin", "main"], in: submoduleSeed)
        let nextSubmoduleHead = try fixture.git(["rev-parse", "HEAD"], in: submoduleSeed).trimmed
        let seedSubmodule = fixture.seedURL.appendingPathComponent("Modules/Child")
        try fixture.git(["fetch", "origin"], in: seedSubmodule)
        try fixture.git(["checkout", nextSubmoduleHead], in: seedSubmodule)
        try fixture.git(["add", "Modules/Child"], in: fixture.seedURL)
        try fixture.git(["commit", "-m", "Update submodule"], in: fixture.seedURL)
        try fixture.git(["push", "origin", "main"], in: fixture.seedURL)

        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let result = try await source.performPull(
            RepositoryPullRequest(
                source: .remote("origin"),
                mode: .merge,
                remoteBranch: "main",
                updateSubmodulesAfterPull: true,
                environment: ["GIT_ALLOW_PROTOCOL": "file"]
            ),
            output: { _ in }
        )
        try require(result.outcome == .completed, "submodules: Pull and requested recursive update complete")
        try require(result.followUpCommands.count == 1 && result.followUpCommands[0].succeeded, "submodules: update is retained as a typed follow-up result")
        try require(
            try fixture.git(["rev-parse", "HEAD"], in: repository.appendingPathComponent("Modules/Child")).trimmed == nextSubmoduleHead,
            "submodules: initialized submodule advances to the pulled gitlink"
        )
        try require(initialSubmoduleHead != nextSubmoduleHead, "submodules: fixture exercises a real submodule transition")
    }

    private static func testTrackingDetachedAndValidation() async throws {
        let fixture = try PullGitFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.clone(named: "Tracking client")
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        var state = try await source.loadPullState()
        try require(state.currentBranch == "main" && state.configuredRemote == "origin" && state.configuredMergeBranch == "main", "pull state: configured tracking branch is represented")
        try fixture.git(["config", "--unset", "branch.main.remote"], in: repository)
        try fixture.git(["config", "--unset", "branch.main.merge"], in: repository)
        state = try await source.loadPullState()
        try require(state.configuredRemote == nil && state.configuredMergeBranch == nil, "pull state: no-upstream state is represented")

        let head = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "--detach", head], in: repository)
        state = try await source.loadPullState()
        try require(state.isDetached, "pull state: detached HEAD is represented")
        let detachedFetch = try await source.performPull(RepositoryPullRequest(source: .remote("origin"), mode: .fetch), output: { _ in })
        try require(detachedFetch.outcome == .completed, "pull state: Fetch remains available on detached HEAD")

        do {
            _ = try await source.performPull(RepositoryPullRequest(source: .remote("missing"), mode: .fetch), output: { _ in })
            throw PullFixtureError("validation: missing remote was accepted")
        } catch RepositoryPullError.missingRemote(let name) {
            try require(name == "missing", "validation: missing remote name is retained")
        }
        do {
            _ = try await source.performPull(
                RepositoryPullRequest(source: .remote("origin"), mode: .fetch, localBranch: "bad~branch", remoteBranch: "main"),
                output: { _ in }
            )
            throw PullFixtureError("validation: invalid local branch was accepted")
        } catch RepositoryPullError.invalidLocalBranch(let name) {
            try require(name == "bad~branch", "validation: invalid branch name is retained")
        }
        let invalidRemoteBranch = try await source.performPull(
            RepositoryPullRequest(source: .remote("origin"), mode: .fetch, remoteBranch: "definitely-missing"),
            output: { _ in }
        )
        try require(invalidRemoteBranch.outcome == .failed, "validation: nonexistent remote branch is reported as a Git failure")
        try require(invalidRemoteBranch.command.exitStatus != 0 && !invalidRemoteBranch.command.standardErrorString.isEmpty, "validation: nonexistent branch preserves Git status and stderr")
    }

    private static func testAutoStashAndFailurePreservation() async throws {
        let fixture = try PullGitFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.clone(named: "Autostash client")
        let peer = try fixture.clone(named: "Autostash peer")
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        try fixture.write("untracked only\n", to: repository.appendingPathComponent("untracked-only.txt"))
        let untrackedOnly = try await source.performPull(
            RepositoryPullRequest(
                source: .remote("origin"),
                mode: .merge,
                autoStash: true,
                includeUntrackedInAutoStash: true
            ),
            output: { _ in }
        )
        try require(!untrackedOnly.automaticStashCreated, "auto stash: upstream requires at least one tracked change before creating a stash")
        try require(FileManager.default.fileExists(atPath: repository.appendingPathComponent("untracked-only.txt").path), "auto stash: an untracked-only worktree is left untouched")
        try fixture.write("dirty tracked\n", to: repository.appendingPathComponent("shared.txt"))
        try fixture.commit("remote safe\n", path: "remote-safe.txt", message: "Remote safe", in: peer)
        try fixture.git(["push", "origin", "main"], in: peer)
        let result = try await source.performPull(
            RepositoryPullRequest(source: .remote("origin"), mode: .merge, remoteBranch: "main", autoStash: true, includeUntrackedInAutoStash: true),
            output: { _ in }
        )
        try require(result.outcome == .completed && result.automaticStashCreated, "auto stash: tracked dirt is saved before Pull")
        try require(
            !fixture.git(["stash", "list", "-1", "--format=%gs"], in: repository).contains("GitExtensionsMac"),
            "auto stash: Git's normal WIP subject is retained"
        )
        try require(try fixture.git(["status", "--porcelain"], in: repository).trimmed.isEmpty, "auto stash: stash remains until the UI applies the configured auto-pop decision")
        _ = try await source.popStash(nil)
        let restoredStatus = try fixture.git(["status", "--porcelain"], in: repository)
        try require(restoredStatus.contains("shared.txt") && restoredStatus.contains("untracked-only.txt"), "auto stash: typed stash pop restores tracked and configured untracked changes")

        let stderr = PullTestOutputRecorder()
        let failed = try await source.performPull(
            RepositoryPullRequest(source: .url(fixture.rootURL.appendingPathComponent("does-not-exist.git").path), mode: .fetch),
            output: { event in stderr.append(event) }
        )
        try require(failed.outcome == .failed, "failure: unreachable source is a typed failed outcome")
        try require(failed.command.exitStatus != 0, "failure: Git exit status is preserved")
        try require(!failed.command.standardErrorString.isEmpty && !stderr.standardError.isEmpty, "failure: stderr is retained and streamed")
        try require(failed.command.arguments.contains("fetch"), "failure: exact Git arguments are retained")
    }

    private static func testStreamingCancellation() async throws {
        let runner = CancellablePullRunner()
        let task = Task {
            try await runner.runStreaming(
                arguments: ["fetch", "--progress", "origin"],
                in: URL(fileURLWithPath: "/tmp"),
                standardInput: nil,
                environment: ["TEST": "1"],
                output: { _ in }
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            throw PullFixtureError("cancellation: cancelled streaming command completed")
        } catch is CancellationError {
            // Expected.
        }
        let observedCancellation = await runner.observedCancellation
        try require(observedCancellation, "cancellation: the runner observed cooperative cancellation")
    }

    private static func testGitProcessCancellation() async throws {
        let runner = GitProcess(executableURL: URL(fileURLWithPath: "/bin/sleep"))
        let started = Date()
        let task = Task {
            try await runner.runStreaming(
                arguments: ["10"],
                in: FileManager.default.temporaryDirectory,
                standardInput: nil,
                environment: [:],
                output: { _ in }
            )
        }
        try await Task.sleep(nanoseconds: 75_000_000)
        task.cancel()
        do {
            _ = try await task.value
            throw PullFixtureError("cancellation: the real child process completed")
        } catch is CancellationError {
            // Expected.
        }
        try require(Date().timeIntervalSince(started) < 2, "cancellation: the real child process is terminated promptly")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw PullFixtureError(message) }
    }
}

private final class PullTestOutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [GitOutputEvent] = []

    var events: [GitOutputEvent] {
        lock.withLock { recordedEvents }
    }

    var standardError: String {
        lock.withLock {
            recordedEvents
                .filter { $0.stream == .standardError }
                .map(\.text)
                .joined()
        }
    }

    func append(_ event: GitOutputEvent) {
        lock.withLock { recordedEvents.append(event) }
    }
}

private actor CancellablePullRunner: GitCommandRunning {
    private(set) var observedCancellation = false

    func run(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String]) async throws -> GitCommandResult {
        try await runStreaming(arguments: arguments, in: directory, standardInput: standardInput, environment: environment, output: { _ in })
    }

    func runStreaming(
        arguments: [String],
        in directory: URL,
        standardInput: Data?,
        environment: [String: String],
        output: @escaping GitOutputHandler
    ) async throws -> GitCommandResult {
        do {
            try await Task.sleep(nanoseconds: 10_000_000_000)
        } catch is CancellationError {
            observedCancellation = true
            throw CancellationError()
        }
        return GitCommandResult(arguments: arguments, standardOutput: Data(), standardError: Data(), exitStatus: 0)
    }
}

final class PullGitFixture {
    let rootURL: URL
    let originURL: URL
    let upstreamURL: URL
    let seedURL: URL

    private init(rootURL: URL, originURL: URL, upstreamURL: URL, seedURL: URL) {
        self.rootURL = rootURL
        self.originURL = originURL
        self.upstreamURL = upstreamURL
        self.seedURL = seedURL
    }

    static func make() throws -> PullGitFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitExtensionsMac-pull-tests-\(UUID().uuidString)", isDirectory: true)
        let origin = root.appendingPathComponent("Origin Remote.git", isDirectory: true)
        let upstream = root.appendingPathComponent("Upstream Remote.git", isDirectory: true)
        let seed = root.appendingPathComponent("Seed Repository", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = PullGitFixture(rootURL: root, originURL: origin, upstreamURL: upstream, seedURL: seed)
        try fixture.git(["init", "--bare", "--initial-branch=main", origin.path], in: root)
        try fixture.git(["init", "--bare", "--initial-branch=main", upstream.path], in: root)
        try fixture.git(["init", "--initial-branch=main", seed.path], in: root)
        try fixture.configureIdentity(in: seed)
        try fixture.write("base\n", to: seed.appendingPathComponent("shared.txt"))
        try fixture.git(["add", "--all", "--"], in: seed)
        try fixture.git(["commit", "-m", "Initial"], in: seed)
        try fixture.git(["branch", "origin-only"], in: seed)
        try fixture.git(["remote", "add", "origin", origin.path], in: seed)
        try fixture.git(["push", "origin", "main", "origin-only"], in: seed)
        try fixture.git(["tag", "fixture-v1"], in: seed)
        try fixture.git(["push", "origin", "fixture-v1"], in: seed)

        try fixture.git(["remote", "add", "upstream", upstream.path], in: seed)
        try fixture.git(["branch", "upstream-only"], in: seed)
        try fixture.git(["push", "upstream", "main", "upstream-only"], in: seed)
        return fixture
    }

    func clone(named name: String) throws -> URL {
        let destination = rootURL.appendingPathComponent(name, isDirectory: true)
        try git(["clone", "--no-hardlinks", originURL.path, destination.path], in: rootURL)
        try configureIdentity(in: destination)
        try git(["config", "pull.rebase", "false"], in: destination)
        return destination
    }

    func shallowClone(named name: String) throws -> URL {
        let destination = rootURL.appendingPathComponent(name, isDirectory: true)
        try git(["clone", "--no-hardlinks", "--no-local", "--depth=1", originURL.path, destination.path], in: rootURL)
        try configureIdentity(in: destination)
        try git(["config", "pull.rebase", "false"], in: destination)
        return destination
    }

    func commit(_ contents: String, path: String, message: String, in repository: URL) throws {
        try write(contents, to: repository.appendingPathComponent(path))
        try git(["add", "--all", "--"], in: repository)
        try git(["commit", "-m", message], in: repository)
    }

    func refExists(_ ref: String, in repository: URL) throws -> Bool {
        result(["show-ref", "--verify", "--quiet", ref], in: repository).status == 0
    }

    func remove() { try? FileManager.default.removeItem(at: rootURL) }

    @discardableResult
    func git(_ arguments: [String], in directory: URL) throws -> String {
        let value = result(arguments, in: directory)
        guard value.status == 0 else {
            throw PullFixtureError("Fixture git \(arguments.joined(separator: " ")) failed (\(value.status)): \(value.stderr)")
        }
        return value.stdout
    }

    func configureIdentity(in directory: URL) throws {
        try git(["config", "user.name", "Pull Fixture"], in: directory)
        try git(["config", "user.email", "pull@example.com"], in: directory)
    }

    func write(_ string: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(string.utf8).write(to: url, options: .atomic)
    }

    private func result(_ arguments: [String], in directory: URL) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = stdout
        process.standardError = stderr
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        return (
            process.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}

struct PullFixtureError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
