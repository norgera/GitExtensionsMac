import Foundation

enum GitRepositoryMutationTests {
    static func runCheckout() async throws {
        let fixture = try MutationGitFixture.make()
        defer { fixture.remove() }

        try await testLocalAndDetachedCheckout(fixture)
        try await testRemoteTrackingCheckout(fixture)
        try await testDirtyCheckoutFailure(fixture)
        print("GitRepositoryMutationTests.checkout: passed")
    }

    static func runStaging() async throws {
        let fixture = try MutationGitFixture.make()
        defer { fixture.remove() }

        try await testFileStaging(fixture)
        try await testHunkStaging(fixture)
        print("GitRepositoryMutationTests.staging: passed")
    }

    static func runCommitAndAmend() async throws {
        let fixture = try MutationGitFixture.make()
        defer { fixture.remove() }

        try await testNormalCommit(fixture)
        try await testCommitValidation(fixture)
        try await testAmendModes(fixture)
        print("GitRepositoryMutationTests.commit: passed")
    }

    static func runStash() async throws {
        let fixture = try MutationGitFixture.make()
        defer { fixture.remove() }

        try await testStashCreationOptions(fixture)
        try await testStashLifecycle(fixture)
        try await testStashConflict(fixture)
        print("GitRepositoryMutationTests.stash: passed")
    }

    static func runCherryPick() async throws {
        let fixture = try MutationGitFixture.make()
        defer { fixture.remove() }

        try await testCherryPickOrderingAndOptions(fixture)
        try await testCherryPickMergeMainline(fixture)
        try await testCherryPickConflictContinue(fixture)
        try await testCherryPickConflictAbort(fixture)
        print("GitRepositoryMutationTests.cherryPick: passed")
    }

    static func runRebase() async throws {
        let fixture = try MutationGitFixture.make()
        defer { fixture.remove() }

        try await testOrdinaryRebaseAndAutoStash(fixture)
        try await testInteractiveRebasePlan(fixture)
        try await testInteractiveRebaseEdit(fixture)
        try await testRebaseConflictContinue(fixture)
        try await testRebaseConflictSkip(fixture)
        try await testRebaseConflictAbort(fixture)
        print("GitRepositoryMutationTests.rebase: passed")
    }

    static func runRemoteManagement() async throws {
        let fixture = try MutationGitFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.clone(named: "Remote management repo")
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()

        var remotes = try await source.loadRemoteConfigurations()
        try require(remotes.contains { $0.name == "origin" && !$0.isDisabled }, "remotes: existing active remote loads")

        let fetchURL = fixture.templateURL.path
        let pushURL = fixture.rootURL.appendingPathComponent("Push target.git").path
        _ = try await source.saveRemote(RepositoryRemoteSaveRequest(
            originalName: nil,
            name: "backup",
            fetchURL: fetchURL,
            pushURL: pushURL,
            puttyKeyFile: "/tmp/test key.ppk",
            color: "#12AB34",
            prefix: "John/"
        ))
        remotes = try await source.loadRemoteConfigurations()
        let added = try required(remotes.first(where: { $0.name == "backup" }), "remotes: added remote loads")
        try require(added.fetchURL == fetchURL && added.pushURL == pushURL && added.puttyKeyFile == "/tmp/test key.ppk", "remotes: typed fields persist")
        try require(added.color == "#12AB34" && added.prefix == "John/", "remotes: color and prefix persist")

        _ = try await source.saveRemote(RepositoryRemoteSaveRequest(
            originalName: "backup",
            name: "upstream",
            fetchURL: fetchURL,
            pushURL: fetchURL,
            puttyKeyFile: nil,
            color: nil,
            prefix: nil
        ))
        remotes = try await source.loadRemoteConfigurations()
        let renamed = try required(remotes.first(where: { $0.name == "upstream" }), "remotes: renamed remote loads")
        try require(renamed.pushURL == nil, "remotes: push URL equal to fetch URL is normalized away")
        try require(!remotes.contains(where: { $0.name == "backup" }), "remotes: old name is removed")
        let advertisedBranches = try await source.loadRemoteBranchNames(named: "upstream")
        try require(advertisedBranches.contains("main") && advertisedBranches.contains("topic"), "remotes: branch query is scoped to the selected remote")

        _ = try await source.setRemote(named: "upstream", disabled: true)
        remotes = try await source.loadRemoteConfigurations()
        let disabled = try required(remotes.first(where: { $0.name == "upstream" }), "remotes: disabled remote loads")
        try require(disabled.isDisabled && disabled.fetchURL == fetchURL, "remotes: disabling retains configuration")
        try require(try fixture.git(["config", "--local", "--get", "--", "-remote.upstream.url"], in: repository).trimmed == fetchURL, "remotes: disabled section matches Git Extensions")

        _ = try await source.setRemote(named: "upstream", disabled: false)
        remotes = try await source.loadRemoteConfigurations()
        try require(remotes.contains { $0.name == "upstream" && !$0.isDisabled && $0.fetchURL == fetchURL }, "remotes: activation round trip retains URL")

        _ = try await source.setBranchTracking(RepositoryBranchTrackingConfiguration(branchName: "main", remoteName: "upstream", mergeBranch: "topic"))
        try require(try fixture.git(["config", "--local", "--get", "branch.main.remote"], in: repository).trimmed == "upstream", "remotes: tracking remote persists")
        try require(try fixture.git(["config", "--local", "--get", "branch.main.merge"], in: repository).trimmed == "refs/heads/topic", "remotes: merge branch persists")

        _ = try await source.deleteRemote(named: "upstream", disabled: false)
        remotes = try await source.loadRemoteConfigurations()
        try require(!remotes.contains(where: { $0.name == "upstream" }), "remotes: deletion removes configuration")

        do {
            _ = try await source.saveRemote(RepositoryRemoteSaveRequest(
                originalName: nil,
                name: "origin",
                fetchURL: fetchURL,
                pushURL: nil,
                puttyKeyFile: nil,
                color: nil,
                prefix: nil
            ))
            throw MutationFixtureError("remotes: duplicate name was accepted")
        } catch RepositoryRemoteManagementError.duplicateName(let name) {
            try require(name == "origin", "remotes: duplicate error retains its name")
        }
        print("GitRepositoryMutationTests.remotes: passed")
    }

    static func verifyDisposableClone(at repository: URL) async throws {
        let helper = try MutationGitFixture.make()
        defer { helper.remove() }
        try helper.configureIdentity(in: repository)
        let originalHead = try helper.git(["rev-parse", "HEAD"], in: repository).trimmed
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let dailyBranch = "codex-phase3-daily-\(suffix)"
        let cherryBranch = "codex-phase3-cherry-\(suffix)"
        let targetBranch = "codex-phase3-target-\(suffix)"
        let rebaseBranch = "codex-phase3-rebase-\(suffix)"
        let markerPath = "codex-phase3-\(suffix).txt"
        let cherryPath = "codex-phase3-cherry-\(suffix).txt"
        let targetPath = "codex-phase3-target-\(suffix).txt"
        let rebaseAPath = "codex-phase3-rebase-a-\(suffix).txt"
        let rebaseBPath = "codex-phase3-rebase-b-\(suffix).txt"

        try helper.git(["branch", dailyBranch, originalHead], in: repository)
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()
        var result = try await source.checkout(RepositoryCheckoutRequest(
            target: .localBranch(dailyBranch),
            localChanges: .keep
        ))
        try require(result.snapshot.branches.contains { $0.name == dailyBranch && $0.isCurrent }, "external fixture: typed checkout switches to disposable branch")

        try helper.write((1...24).map { "line \($0)" }.joined(separator: "\n") + "\n", to: repository.appendingPathComponent(markerPath))
        _ = try await source.stage(paths: [markerPath])
        _ = try await source.unstage(paths: [markerPath])
        _ = try await source.stage(paths: [markerPath])
        result = try await source.commit(RepositoryCommitRequest(
            message: "Phase 3 disposable commit",
            mode: .normal,
            stageAllBeforeCommit: false,
            allowEmpty: false,
            signOff: false,
            author: nil,
            resetAuthor: false
        ))
        try require(result.outcome == .completed, "external fixture: typed commit completes")

        var markerLines = (1...24).map { "line \($0)" }
        markerLines[1] = "line 2 staged hunk"
        markerLines[20] = "line 21 remains unstaged"
        try helper.write(markerLines.joined(separator: "\n") + "\n", to: repository.appendingPathComponent(markerPath))
        var snapshot = try await source.loadSnapshot()
        let worktree = try required(snapshot.commits.first(where: { $0.kind == .workingDirectory }), "external fixture: worktree revision exists")
        let details = try await source.loadRevisionDetails(for: worktree)
        let markerFile = try required(details.files.first(where: { $0.path == markerPath }), "external fixture: marker diff exists")
        let markerDiff = try required(try await source.loadDiff(for: worktree, file: markerFile), "external fixture: marker patch loads lazily")
        let selectedLine = try required(markerDiff.lines.first(where: { $0.kind == .addition && $0.text == "line 2 staged hunk" }), "external fixture: first hunk is selectable")
        _ = try await source.applyHunk(RepositoryHunkSelection(file: markerFile, diff: markerDiff, lineID: selectedLine.id, direction: .stage))
        let stagedPatch = try helper.git(["diff", "--cached", "--", markerPath], in: repository)
        try require(stagedPatch.contains("line 2 staged hunk") && !stagedPatch.contains("line 21 remains unstaged"), "external fixture: typed hunk staging isolates the selected hunk")
        _ = try await source.stageAll()
        _ = try await source.commit(RepositoryCommitRequest(
            message: "Phase 3 hunk commit",
            mode: .normal,
            stageAllBeforeCommit: false,
            allowEmpty: false,
            signOff: false,
            author: nil,
            resetAuthor: false
        ))
        _ = try await source.commit(RepositoryCommitRequest(
            message: "Phase 3 amended hunk commit",
            mode: .amendMessageOnly,
            stageAllBeforeCommit: false,
            allowEmpty: false,
            signOff: false,
            author: nil,
            resetAuthor: false
        ))
        try require(try helper.git(["log", "-1", "--format=%s"], in: repository).trimmed == "Phase 3 amended hunk commit", "external fixture: typed amend updates the message")

        try helper.write("stashed disposable content\n", to: repository.appendingPathComponent(markerPath))
        result = try await source.createStash(RepositoryStashCreateRequest(
            message: "Phase 3 disposable stash",
            includeUntracked: false,
            keepIndex: false,
            stagedOnly: false
        ))
        let stash = try required(result.snapshot.stashes.first, "external fixture: typed stash create produces a stash")
        _ = try await source.applyStash(stash)
        try helper.git(["restore", "--staged", "--worktree", "--", markerPath], in: repository)
        _ = try await source.popStash(stash)
        try helper.git(["restore", "--staged", "--worktree", "--", markerPath], in: repository)
        try helper.write("drop this stash\n", to: repository.appendingPathComponent(markerPath))
        result = try await source.createStash(RepositoryStashCreateRequest(
            message: "Phase 3 disposable drop",
            includeUntracked: false,
            keepIndex: false,
            stagedOnly: false
        ))
        _ = try await source.dropStash(try required(result.snapshot.stashes.first, "external fixture: drop stash exists"))

        let dailyHead = try helper.git(["rev-parse", "HEAD"], in: repository).trimmed
        try helper.git(["checkout", "-b", cherryBranch, dailyHead], in: repository)
        try helper.write("cherry\n", to: repository.appendingPathComponent(cherryPath))
        try helper.git(["add", "--all", "--"], in: repository)
        try helper.git(["commit", "-m", "Phase 3 cherry source"], in: repository)
        let cherryCommit = try helper.git(["rev-parse", "HEAD"], in: repository).trimmed
        try helper.git(["checkout", dailyBranch], in: repository)
        _ = try await source.loadSnapshot()
        result = try await source.cherryPick(RepositoryCherryPickRequest(
            items: [RepositoryCherryPickItem(commitID: cherryCommit, mainlineParent: nil)],
            options: RepositoryCherryPickOptions(automaticallyCommit: true, addReference: true)
        ))
        try require(result.outcome == .completed && FileManager.default.fileExists(atPath: repository.appendingPathComponent(cherryPath).path), "external fixture: typed cherry-pick applies the source commit")

        let rebaseBase = try helper.git(["rev-parse", "HEAD"], in: repository).trimmed
        try helper.git(["checkout", "-b", targetBranch, rebaseBase], in: repository)
        try helper.write("target\n", to: repository.appendingPathComponent(targetPath))
        try helper.git(["add", "--all", "--"], in: repository)
        try helper.git(["commit", "-m", "Phase 3 rebase target"], in: repository)
        let targetCommit = try helper.git(["rev-parse", "HEAD"], in: repository).trimmed
        try helper.git(["checkout", "-b", rebaseBranch, rebaseBase], in: repository)
        for (subject, path) in [("Phase 3 rebase A", rebaseAPath), ("Phase 3 rebase B", rebaseBPath)] {
            try helper.write("\(subject)\n", to: repository.appendingPathComponent(path))
            try helper.git(["add", "--all", "--"], in: repository)
            try helper.git(["commit", "-m", subject], in: repository)
        }
        snapshot = try await source.loadSnapshot()
        let plan = try await source.loadInteractiveRebasePlan(upstream: targetCommit)
        try require(plan.count == 2, "external fixture: interactive rebase plan contains the disposable commits")
        result = try await source.interactiveRebase(RepositoryInteractiveRebaseRequest(
            upstream: targetCommit,
            items: [
                RepositoryRebaseTodoItem(commitID: plan[1].commitID, subject: plan[1].subject, action: .pick),
                RepositoryRebaseTodoItem(commitID: plan[0].commitID, subject: plan[0].subject, action: .reword("Phase 3 rebase A rewritten"))
            ],
            autoStash: false
        ))
        try require(result.outcome == .completed, "external fixture: typed interactive rebase completes")
        let rebasedSubjects = try helper.git(["log", "--reverse", "--format=%s", "\(targetCommit)..HEAD"], in: repository)
            .split(separator: "\n").map(String.init)
        try require(rebasedSubjects == ["Phase 3 rebase B", "Phase 3 rebase A rewritten"], "external fixture: interactive reorder and reword are preserved")

        print("MUTATION_VERIFY path=\(repository.path) base=\(originalHead.prefix(12)) checkout=true files=true hunks=true commit=true amend=true stash=true cherryPick=true rebase=true")
    }

    private static func testLocalAndDetachedCheckout(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Local checkout repo")
        try fixture.git(["branch", "local-topic", "origin/topic"], in: repository)
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()

        let switched = try await source.checkout(RepositoryCheckoutRequest(
            target: .localBranch("local-topic"),
            localChanges: .keep
        ))
        try require(switched.snapshot.branches.contains { $0.name == "local-topic" && $0.isCurrent }, "checkout: local branch becomes current")
        try require(switched.selectedCommitID == switched.snapshot.commits.first(where: \.isHEAD)?.id, "checkout: selection follows the new HEAD")

        do {
            _ = try await source.checkout(RepositoryCheckoutRequest(target: .localBranch("local-topic"), localChanges: .keep))
            throw MutationFixtureError("checkout: current branch was accepted")
        } catch RepositoryMutationError.currentBranch(let name) {
            try require(name == "local-topic", "checkout: current branch error retains its name")
        }

        let mainID = try fixture.git(["rev-parse", "main"], in: repository).trimmed
        let detached = try await source.checkout(RepositoryCheckoutRequest(target: .revision(mainID), localChanges: .keep))
        let state = try await source.loadMutationState()
        try require(state.currentBranch == nil && state.headID == mainID, "checkout: revision produces detached HEAD")
        try require(detached.snapshot.commits.contains { $0.id == mainID && $0.isHEAD }, "checkout: detached HEAD is visible after refresh")
    }

    private static func testRemoteTrackingCheckout(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Remote checkout repo")
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()

        let result = try await source.checkout(RepositoryCheckoutRequest(
            target: .remoteBranch(remote: "origin", branch: "topic", mode: .createTracking(localBranch: "topic-local")),
            localChanges: .keep
        ))
        let upstream = try fixture.git(["rev-parse", "--abbrev-ref", "topic-local@{upstream}"], in: repository).trimmed
        try require(upstream == "origin/topic", "checkout: remote checkout creates explicit tracking")
        try require(result.snapshot.branches.contains { $0.name == "topic-local" && $0.isCurrent && $0.remoteName == "origin" }, "checkout: tracking branch refreshes into the snapshot")

        do {
            _ = try await source.checkout(RepositoryCheckoutRequest(
                target: .remoteBranch(remote: "origin", branch: "topic", mode: .createTracking(localBranch: "bad name")),
                localChanges: .keep
            ))
            throw MutationFixtureError("checkout: invalid branch name was accepted")
        } catch RepositoryMutationError.invalidBranchName(let name) {
            try require(name == "bad name", "checkout: invalid branch name is reported")
        }
    }

    private static func testDirtyCheckoutFailure(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Dirty checkout repo")
        try fixture.git(["branch", "local-topic", "origin/topic"], in: repository)
        try fixture.write("dirty main\n", to: repository.appendingPathComponent("shared.txt"))
        let beforeBranch = try fixture.git(["branch", "--show-current"], in: repository).trimmed
        let beforeHead = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()

        do {
            _ = try await source.checkout(RepositoryCheckoutRequest(target: .localBranch("local-topic"), localChanges: .keep))
            throw MutationFixtureError("checkout: conflicting dirty worktree unexpectedly switched")
        } catch let error as GitError {
            try require(error.errorDescription?.contains("would be overwritten by checkout") == true, "checkout: dirty failure retains Git stderr")
        }

        try require(try fixture.git(["branch", "--show-current"], in: repository).trimmed == beforeBranch, "checkout: dirty failure preserves branch")
        try require(try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed == beforeHead, "checkout: dirty failure preserves HEAD")
        try require(try String(contentsOf: repository.appendingPathComponent("shared.txt"), encoding: .utf8) == "dirty main\n", "checkout: dirty failure preserves worktree content")
    }

    private static func testFileStaging(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "File staging repo")
        try fixture.write("changed main\n", to: repository.appendingPathComponent("shared.txt"))
        try fixture.write("new file\n", to: repository.appendingPathComponent("new file.txt"))
        try FileManager.default.removeItem(at: repository.appendingPathComponent("main.txt"))
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        var snapshot = try await source.loadSnapshot()
        let worktree = try required(snapshot.commits.first(where: { $0.kind == .workingDirectory }), "staging: worktree revision exists")
        let worktreeDetails = try await source.loadRevisionDetails(for: worktree)
        try require(Set(worktreeDetails.files.map(\.path)).isSuperset(of: ["shared.txt", "new file.txt", "main.txt"]), "staging: worktree lists modified, untracked, and deleted paths")

        var result = try await source.stage(paths: ["shared.txt", "new file.txt", "main.txt"])
        let cached = try fixture.git(["diff", "--cached", "--name-only"], in: repository)
        try require(cached.contains("shared.txt") && cached.contains("new file.txt") && cached.contains("main.txt"), "staging: selected paths include additions and deletion")
        snapshot = result.snapshot
        let index = try required(snapshot.commits.first(where: { $0.kind == .index }), "staging: refreshed index revision exists")
        let indexDetails = try await source.loadRevisionDetails(for: index)
        try require(Set(indexDetails.files.map(\.path)).isSuperset(of: ["shared.txt", "new file.txt", "main.txt"]), "staging: index artificial revision refreshes")

        result = try await source.unstage(paths: ["new file.txt", "main.txt"])
        let remaining = try fixture.git(["diff", "--cached", "--name-only"], in: repository)
        try require(remaining.trimmed == "shared.txt", "staging: selected unstage leaves unrelated index entries")
        try require(result.selectedCommitID == "$index", "staging: unstage retains index selection intent")

        _ = try await source.stageAll()
        let stagedAll = try fixture.git(["diff", "--cached", "--name-only"], in: repository)
        try require(stagedAll.contains("new file.txt") && stagedAll.contains("main.txt"), "staging: stage all includes untracked and deleted paths")
        _ = try await source.unstageAll()
        try require(try fixture.git(["diff", "--cached", "--name-only"], in: repository).trimmed.isEmpty, "staging: unstage all clears the index diff")
        let state = try await source.loadMutationState()
        try require(!state.hasStagedChanges && state.hasUnstagedChanges && state.hasUntrackedFiles, "staging: worktree remains intact after unstage all")
    }

    private static func testHunkStaging(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Hunk staging repo")
        var lines = (1...20).map { "line \($0)" }
        lines[1] = "line 2 changed"
        lines[17] = "line 18 changed"
        try fixture.write(lines.joined(separator: "\n") + "\n", to: repository.appendingPathComponent("hunks.txt"))
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        var snapshot = try await source.loadSnapshot()
        var worktree = try required(snapshot.commits.first(where: { $0.kind == .workingDirectory }), "hunks: worktree revision exists")
        var details = try await source.loadRevisionDetails(for: worktree)
        let file = try required(details.files.first(where: { $0.path == "hunks.txt" }), "hunks: modified file is present")
        let diff = try required(try await source.loadDiff(for: worktree, file: file), "hunks: worktree patch is parsed lazily")
        let firstChangedLine = try required(diff.lines.first(where: { $0.kind == .addition && $0.text == "line 2 changed" }), "hunks: first changed line exists")

        var result = try await source.applyHunk(RepositoryHunkSelection(file: file, diff: diff, lineID: firstChangedLine.id, direction: .stage))
        let cached = try fixture.git(["diff", "--cached", "--", "hunks.txt"], in: repository)
        let unstaged = try fixture.git(["diff", "--", "hunks.txt"], in: repository)
        try require(cached.contains("line 2 changed") && !cached.contains("line 18 changed"), "hunks: stage applies only the selected hunk")
        try require(!unstaged.contains("line 2 changed") && unstaged.contains("line 18 changed"), "hunks: unselected hunk stays in the worktree")

        snapshot = result.snapshot
        let index = try required(snapshot.commits.first(where: { $0.kind == .index }), "hunks: index revision exists after stage")
        details = try await source.loadRevisionDetails(for: index)
        let stagedFile = try required(details.files.first(where: { $0.path == "hunks.txt" }), "hunks: staged file is present")
        let stagedDiff = try required(try await source.loadDiff(for: index, file: stagedFile), "hunks: staged patch is parsed lazily")
        let stagedLine = try required(stagedDiff.lines.first(where: { $0.kind == .addition && $0.text == "line 2 changed" }), "hunks: staged line exists")
        result = try await source.applyHunk(RepositoryHunkSelection(file: stagedFile, diff: stagedDiff, lineID: stagedLine.id, direction: .unstage))
        try require(try fixture.git(["diff", "--cached", "--", "hunks.txt"], in: repository).trimmed.isEmpty, "hunks: reverse apply unstages selected hunk")
        try require(result.snapshot.commits.contains { $0.kind == .workingDirectory }, "hunks: both artificial revisions survive refresh")
        worktree = try required(result.snapshot.commits.first(where: { $0.kind == .workingDirectory }), "hunks: refreshed worktree exists")
        let refreshed = try await source.loadRevisionDetails(for: worktree)
        try require(refreshed.files.contains { $0.path == "hunks.txt" }, "hunks: worktree detail reloads after unstage")
    }

    private static func testNormalCommit(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Normal commit repo")
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()

        try fixture.write("staged main\n", to: repository.appendingPathComponent("main.txt"))
        _ = try await source.stage(paths: ["main.txt"])
        try fixture.write("staged main\nunstaged tail\n", to: repository.appendingPathComponent("main.txt"))
        try fixture.write("untracked\n", to: repository.appendingPathComponent("untracked.txt"))

        let result = try await source.commit(RepositoryCommitRequest(
            message: "Normal commit\n\nBody text",
            mode: .normal,
            stageAllBeforeCommit: false,
            allowEmpty: false,
            signOff: true,
            author: "Phase Three <phase3@example.com>",
            resetAuthor: false
        ))

        let head = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try require(result.selectedCommitID == head, "commit: refreshed selection follows the new HEAD")
        try require(try fixture.git(["show", "HEAD:main.txt"], in: repository) == "staged main\n", "commit: normal commit records only the index")
        try require(try String(contentsOf: repository.appendingPathComponent("main.txt"), encoding: .utf8) == "staged main\nunstaged tail\n", "commit: unstaged changes remain in the worktree")
        try require(FileManager.default.fileExists(atPath: repository.appendingPathComponent("untracked.txt").path), "commit: untracked files remain untouched")
        try require(try fixture.git(["log", "-1", "--format=%s"], in: repository).trimmed == "Normal commit", "commit: subject is preserved")
        let body = try fixture.git(["log", "-1", "--format=%b"], in: repository)
        try require(body.contains("Body text") && body.contains("Signed-off-by: Mutation Fixture <mutation@example.com>"), "commit: body and committer signoff are preserved")
        try require(try fixture.git(["log", "-1", "--format=%an <%ae>"], in: repository).trimmed == "Phase Three <phase3@example.com>", "commit: author override is applied")
        let state = try await source.loadMutationState()
        try require(!state.hasStagedChanges && state.hasUnstagedChanges && state.hasUntrackedFiles, "commit: refreshed artificial revisions reflect remaining worktree state")
    }

    private static func testCommitValidation(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Commit validation repo")
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()
        let before = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed

        do {
            _ = try await source.commit(RepositoryCommitRequest(
                message: " \n\t",
                mode: .normal,
                stageAllBeforeCommit: false,
                allowEmpty: false,
                signOff: false,
                author: nil,
                resetAuthor: false
            ))
            throw MutationFixtureError("commit: an empty message was accepted")
        } catch RepositoryMutationError.emptyCommitMessage {
            // Expected.
        }
        try require(try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed == before, "commit: empty-message validation preserves HEAD")

        do {
            _ = try await source.commit(RepositoryCommitRequest(
                message: "Nothing staged",
                mode: .normal,
                stageAllBeforeCommit: false,
                allowEmpty: false,
                signOff: false,
                author: nil,
                resetAuthor: false
            ))
            throw MutationFixtureError("commit: a normal commit without staged changes was accepted")
        } catch RepositoryMutationError.nothingStaged {
            // Expected.
        }
        try require(try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed == before, "commit: nothing-staged validation preserves HEAD")
    }

    private static func testAmendModes(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Amend repo")
        try fixture.write("second\n", to: repository.appendingPathComponent("second.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Second commit"], in: repository)
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()

        let parentBefore = try fixture.git(["rev-parse", "HEAD^"], in: repository).trimmed
        let countBefore = try fixture.git(["rev-list", "--count", "HEAD"], in: repository).trimmed
        try fixture.write("amended main\n", to: repository.appendingPathComponent("main.txt"))
        _ = try await source.stage(paths: ["main.txt"])
        let amended = try await source.commit(RepositoryCommitRequest(
            message: "Amended commit",
            mode: .amend,
            stageAllBeforeCommit: false,
            allowEmpty: false,
            signOff: false,
            author: nil,
            resetAuthor: false
        ))
        try require(try fixture.git(["rev-list", "--count", "HEAD"], in: repository).trimmed == countBefore, "amend: history length is unchanged")
        try require(try fixture.git(["rev-parse", "HEAD^"], in: repository).trimmed == parentBefore, "amend: original parent is retained")
        try require(try fixture.git(["show", "HEAD:main.txt"], in: repository) == "amended main\n", "amend: staged tree change is included")
        try require(amended.selectedCommitID == fixture.git(["rev-parse", "HEAD"], in: repository).trimmed, "amend: selection follows rewritten HEAD")

        try fixture.write("staged after amend\n", to: repository.appendingPathComponent("shared.txt"))
        _ = try await source.stage(paths: ["shared.txt"])
        let treeBeforeMessageOnly = try fixture.git(["rev-parse", "HEAD^{tree}"], in: repository).trimmed
        _ = try await source.commit(RepositoryCommitRequest(
            message: "Message-only amend\n\nRetains the index",
            mode: .amendMessageOnly,
            stageAllBeforeCommit: false,
            allowEmpty: false,
            signOff: false,
            author: nil,
            resetAuthor: false
        ))
        try require(try fixture.git(["rev-parse", "HEAD^{tree}"], in: repository).trimmed == treeBeforeMessageOnly, "amend message only: HEAD tree is unchanged")
        try require(try fixture.git(["diff", "--cached", "--name-only"], in: repository).trimmed == "shared.txt", "amend message only: staged changes remain staged")
        try require(try fixture.git(["log", "-1", "--format=%s"], in: repository).trimmed == "Message-only amend", "amend message only: commit message is updated")
    }

    private static func testStashCreationOptions(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Stash options repo")
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()

        try fixture.write("staged main\n", to: repository.appendingPathComponent("main.txt"))
        _ = try await source.stage(paths: ["main.txt"])
        try fixture.write("unstaged shared\n", to: repository.appendingPathComponent("shared.txt"))
        try fixture.write("untracked stash\n", to: repository.appendingPathComponent("untracked stash.txt"))
        let created = try await source.createStash(RepositoryStashCreateRequest(
            message: "options fixture",
            includeUntracked: true,
            keepIndex: true,
            stagedOnly: false
        ))
        try require(created.snapshot.stashes.count == 1, "stash: create refreshes stash refs")
        try require(created.snapshot.stashes[0].subject.contains("options fixture"), "stash: optional message is parsed into the stash model")
        try require(try fixture.git(["diff", "--cached", "--name-only"], in: repository).trimmed == "main.txt", "stash: keep-index retains staged changes")
        try require(try fixture.git(["show", "HEAD:shared.txt"], in: repository) == String(contentsOf: repository.appendingPathComponent("shared.txt"), encoding: .utf8), "stash: tracked unstaged content is restored")
        try require(!FileManager.default.fileExists(atPath: repository.appendingPathComponent("untracked stash.txt").path), "stash: include-untracked removes the saved untracked file")

        let stagedRepository = try fixture.clone(named: "Stash staged repo")
        let stagedSource = GitRepositoryBrowsingDataSource(repositoryURL: stagedRepository)
        _ = try await stagedSource.loadSnapshot()
        try fixture.write("staged only\n", to: stagedRepository.appendingPathComponent("main.txt"))
        _ = try await stagedSource.stage(paths: ["main.txt"])
        try fixture.write("unstaged remains\n", to: stagedRepository.appendingPathComponent("shared.txt"))
        let stagedResult = try await stagedSource.createStash(RepositoryStashCreateRequest(
            message: "",
            includeUntracked: false,
            keepIndex: false,
            stagedOnly: true
        ))
        try require(stagedResult.snapshot.stashes.count == 1, "stash staged: creates a stash")
        try require(try fixture.git(["diff", "--cached", "--name-only"], in: stagedRepository).trimmed.isEmpty, "stash staged: removes saved index changes")
        try require(try String(contentsOf: stagedRepository.appendingPathComponent("shared.txt"), encoding: .utf8) == "unstaged remains\n", "stash staged: leaves unrelated unstaged changes")
    }

    private static func testStashLifecycle(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Stash lifecycle repo")
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()

        try fixture.write("older stash\n", to: repository.appendingPathComponent("shared.txt"))
        _ = try await source.createStash(RepositoryStashCreateRequest(message: "older", includeUntracked: false, keepIndex: false, stagedOnly: false))
        try fixture.write("latest stash\n", to: repository.appendingPathComponent("main.txt"))
        var snapshot = try await source.createStash(RepositoryStashCreateRequest(message: "latest", includeUntracked: false, keepIndex: false, stagedOnly: false)).snapshot
        try require(snapshot.stashes.count == 2, "stash lifecycle: two stashes are newest-first")

        let older = snapshot.stashes[1]
        var result = try await source.applyStash(older)
        try require(try String(contentsOf: repository.appendingPathComponent("shared.txt"), encoding: .utf8) == "older stash\n", "stash apply: selected stash content is restored")
        try require(result.snapshot.stashes.count == 2, "stash apply: stash remains in the reflog")
        try fixture.git(["restore", "--staged", "--worktree", "--", "shared.txt"], in: repository)

        snapshot = result.snapshot
        let latest = snapshot.stashes[0]
        result = try await source.popStash(latest)
        try require(try String(contentsOf: repository.appendingPathComponent("main.txt"), encoding: .utf8) == "latest stash\n", "stash pop: selected stash content is restored")
        try require(result.snapshot.stashes.count == 1 && result.snapshot.stashes[0].commitID == older.commitID, "stash pop: successful selected stash is removed")
        try fixture.git(["restore", "--staged", "--worktree", "--", "main.txt"], in: repository)

        result = try await source.dropStash(result.snapshot.stashes[0])
        try require(result.snapshot.stashes.isEmpty, "stash drop: selected stash is removed")
        do {
            _ = try await source.applyStash(older)
            throw MutationFixtureError("stash: a stale stash selector was accepted")
        } catch RepositoryMutationError.invalidStash(let selector) {
            try require(selector == older.selector, "stash: stale selection reports its original selector")
        }
    }

    private static func testStashConflict(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Stash conflict repo")
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()
        try fixture.write("stashed side\n", to: repository.appendingPathComponent("shared.txt"))
        var result = try await source.createStash(RepositoryStashCreateRequest(message: "conflict", includeUntracked: false, keepIndex: false, stagedOnly: false))
        let stash = try required(result.snapshot.stashes.first, "stash conflict: stash exists")

        try fixture.write("current side\n", to: repository.appendingPathComponent("shared.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Conflicting current change"], in: repository)
        result = try await source.applyStash(stash)
        guard case .conflicts(let paths) = result.outcome else {
            throw MutationFixtureError("stash conflict: apply did not return a conflict outcome")
        }
        try require(paths == ["shared.txt"], "stash conflict: conflicted path is reported")
        try require(result.snapshot.stashes.contains { $0.commitID == stash.commitID }, "stash conflict: stash remains available")
        try require(try fixture.git(["diff", "--name-only", "--diff-filter=U"], in: repository).trimmed == "shared.txt", "stash conflict: repository retains Git's unmerged index state")
    }

    private static func testCherryPickOrderingAndOptions(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Cherry pick ordering repo")
        try fixture.git(["checkout", "-b", "pick-sequence"], in: repository)
        try fixture.write("one\n", to: repository.appendingPathComponent("pick-one.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Pick one"], in: repository)
        let first = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.write("two\n", to: repository.appendingPathComponent("pick-two.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Pick two"], in: repository)
        let second = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "main"], in: repository)

        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()
        let beforeCount = Int(try fixture.git(["rev-list", "--count", "HEAD"], in: repository).trimmed) ?? 0
        let result = try await source.cherryPick(RepositoryCherryPickRequest(
            items: [
                RepositoryCherryPickItem(commitID: first, mainlineParent: nil),
                RepositoryCherryPickItem(commitID: second, mainlineParent: nil)
            ],
            options: RepositoryCherryPickOptions(automaticallyCommit: true, addReference: true)
        ))
        let subjects = try fixture.git(["log", "-2", "--reverse", "--format=%s"], in: repository)
            .split(separator: "\n").map(String.init)
        try require(subjects == ["Pick one", "Pick two"], "cherry-pick: multiple revisions are applied oldest to newest")
        let afterCount = Int(try fixture.git(["rev-list", "--count", "HEAD"], in: repository).trimmed) ?? 0
        try require(afterCount == beforeCount + 2, "cherry-pick: automatic mode creates one commit per revision")
        let bodies = try fixture.git(["log", "-2", "--format=%b"], in: repository)
        try require(bodies.contains("cherry picked from commit \(first)") && bodies.contains("cherry picked from commit \(second)"), "cherry-pick: -x adds both source references")
        try require(result.selectedCommitID == fixture.git(["rev-parse", "HEAD"], in: repository).trimmed, "cherry-pick: successful selection follows HEAD")

        let noCommitRepository = try fixture.clone(named: "Cherry pick no commit repo")
        let noCommitSource = GitRepositoryBrowsingDataSource(repositoryURL: noCommitRepository)
        _ = try await noCommitSource.loadSnapshot()
        let headBefore = try fixture.git(["rev-parse", "HEAD"], in: noCommitRepository).trimmed
        let topic = try fixture.git(["rev-parse", "origin/topic"], in: noCommitRepository).trimmed
        let noCommit = try await noCommitSource.cherryPick(RepositoryCherryPickRequest(
            items: [RepositoryCherryPickItem(commitID: topic, mainlineParent: nil)],
            options: RepositoryCherryPickOptions(automaticallyCommit: false, addReference: false)
        ))
        try require(try fixture.git(["rev-parse", "HEAD"], in: noCommitRepository).trimmed == headBefore, "cherry-pick --no-commit: HEAD is unchanged")
        try require(!fixture.git(["diff", "--cached", "--name-only"], in: noCommitRepository).trimmed.isEmpty, "cherry-pick --no-commit: changes are staged")
        try require(noCommit.selectedCommitID == "$index", "cherry-pick --no-commit: refreshed selection targets Commit index")
    }

    private static func testCherryPickMergeMainline(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Cherry pick merge repo")
        try fixture.write("main side\n", to: repository.appendingPathComponent("main-side.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Main side"], in: repository)
        try fixture.git(["checkout", "-b", "merge-topic"], in: repository)
        try fixture.write("topic side\n", to: repository.appendingPathComponent("merge-topic.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Merge topic side"], in: repository)
        try fixture.git(["checkout", "main"], in: repository)
        try fixture.write("main later\n", to: repository.appendingPathComponent("main-later.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Main later"], in: repository)
        let targetBase = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["merge", "--no-ff", "merge-topic", "-m", "Merge fixture"], in: repository)
        let merge = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "-b", "merge-target", targetBase], in: repository)
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()

        do {
            _ = try await source.cherryPick(RepositoryCherryPickRequest(
                items: [RepositoryCherryPickItem(commitID: merge, mainlineParent: nil)],
                options: RepositoryCherryPickOptions(automaticallyCommit: true, addReference: false)
            ))
            throw MutationFixtureError("cherry-pick: merge without a mainline was accepted")
        } catch RepositoryMutationError.invalidMainline(_, let parent, let count) {
            try require(parent == nil && count == 2, "cherry-pick: merge validation reports available parents")
        }

        _ = try await source.cherryPick(RepositoryCherryPickRequest(
            items: [RepositoryCherryPickItem(commitID: merge, mainlineParent: 1)],
            options: RepositoryCherryPickOptions(automaticallyCommit: true, addReference: false)
        ))
        try require(FileManager.default.fileExists(atPath: repository.appendingPathComponent("merge-topic.txt").path), "cherry-pick: selected merge mainline applies the other-parent change")
    }

    private static func testCherryPickConflictContinue(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Cherry pick continue repo")
        try fixture.git(["checkout", "-b", "conflicting-picks"], in: repository)
        try fixture.write("incoming conflict\n", to: repository.appendingPathComponent("shared.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Conflicting pick"], in: repository)
        let conflicting = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.write("queued\n", to: repository.appendingPathComponent("queued.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Queued pick"], in: repository)
        let queued = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "main"], in: repository)
        try fixture.write("current conflict\n", to: repository.appendingPathComponent("shared.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Current conflict"], in: repository)

        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()
        var result = try await source.cherryPick(RepositoryCherryPickRequest(
            items: [
                RepositoryCherryPickItem(commitID: conflicting, mainlineParent: nil),
                RepositoryCherryPickItem(commitID: queued, mainlineParent: nil)
            ],
            options: RepositoryCherryPickOptions(automaticallyCommit: true, addReference: false)
        ))
        guard case .conflicts(let paths) = result.outcome else {
            throw MutationFixtureError("cherry-pick continue: conflict was not reported")
        }
        try require(paths == ["shared.txt"], "cherry-pick continue: unmerged path is reported")
        let conflictedState = try await source.loadMutationState()
        try require(conflictedState.cherryPickInProgress, "cherry-pick continue: sequencer state is visible")

        try fixture.write("resolved content\n", to: repository.appendingPathComponent("shared.txt"))
        _ = try await source.stage(paths: ["shared.txt"])
        result = try await source.continueCherryPick()
        try require(result.outcome == .completed, "cherry-pick continue: resolved sequence completes")
        let continuedState = try await source.loadMutationState()
        try require(!continuedState.cherryPickInProgress, "cherry-pick continue: sequencer state is cleared")
        let subjects = try fixture.git(["log", "-2", "--reverse", "--format=%s"], in: repository)
            .split(separator: "\n").map(String.init)
        try require(subjects == ["Conflicting pick", "Queued pick"], "cherry-pick continue: queued selections resume in order")
        try require(FileManager.default.fileExists(atPath: repository.appendingPathComponent("queued.txt").path), "cherry-pick continue: pending commit is applied")
    }

    private static func testCherryPickConflictAbort(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Cherry pick abort repo")
        try fixture.git(["checkout", "-b", "abort-source"], in: repository)
        try fixture.write("abort incoming\n", to: repository.appendingPathComponent("shared.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Abort source"], in: repository)
        let incoming = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "main"], in: repository)
        try fixture.write("abort current\n", to: repository.appendingPathComponent("shared.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Abort current"], in: repository)
        let before = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed

        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()
        let conflicted = try await source.cherryPick(RepositoryCherryPickRequest(
            items: [RepositoryCherryPickItem(commitID: incoming, mainlineParent: nil)],
            options: RepositoryCherryPickOptions(automaticallyCommit: true, addReference: false)
        ))
        guard case .conflicts = conflicted.outcome else { throw MutationFixtureError("cherry-pick abort: conflict was not created") }
        let aborted = try await source.abortCherryPick()
        try require(try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed == before, "cherry-pick abort: original HEAD is restored")
        let abortedState = try await source.loadMutationState()
        try require(abortedState.conflictedPaths.isEmpty, "cherry-pick abort: conflict state is cleared")
        try require(aborted.selectedCommitID == before, "cherry-pick abort: selection returns to HEAD")
        try require(try String(contentsOf: repository.appendingPathComponent("shared.txt"), encoding: .utf8) == "abort current\n", "cherry-pick abort: original worktree content is restored")
    }

    private static func testOrdinaryRebaseAndAutoStash(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Ordinary rebase repo")
        try fixture.git(["checkout", "-b", "rebase-feature"], in: repository)
        try fixture.write("feature\n", to: repository.appendingPathComponent("feature.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Feature commit"], in: repository)
        let oldFeature = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "main"], in: repository)
        try fixture.write("target\n", to: repository.appendingPathComponent("target.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Target commit"], in: repository)
        let target = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "rebase-feature"], in: repository)
        try fixture.write("dirty but unrelated\n", to: repository.appendingPathComponent("main.txt"))

        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()
        do {
            _ = try await source.rebase(RepositoryRebaseRequest(upstream: target, autoStash: false))
            throw MutationFixtureError("rebase: dirty worktree was accepted without autostash")
        } catch let error as GitError {
            try require(error.errorDescription?.contains("unstaged changes") == true, "rebase: dirty failure retains Git stderr")
        }
        try require(try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed == oldFeature, "rebase: dirty failure preserves HEAD")
        try require(try String(contentsOf: repository.appendingPathComponent("main.txt"), encoding: .utf8) == "dirty but unrelated\n", "rebase: dirty failure preserves worktree")

        let result = try await source.rebase(RepositoryRebaseRequest(upstream: target, autoStash: true))
        try require(result.outcome == .completed, "rebase: autostash operation completes")
        let newFeature = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try require(newFeature != oldFeature, "rebase: feature commit is rewritten")
        try require(try fixture.git(["rev-parse", "HEAD^"], in: repository).trimmed == target, "rebase: rewritten feature is based on the target")
        try require(try String(contentsOf: repository.appendingPathComponent("main.txt"), encoding: .utf8) == "dirty but unrelated\n", "rebase: autostash restores dirty content")
        try require(result.selectedCommitID == newFeature, "rebase: selection follows rewritten HEAD")
    }

    private static func testInteractiveRebasePlan(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Interactive rebase repo")
        try fixture.git(["checkout", "-b", "interactive-feature"], in: repository)
        for (subject, path) in [("Interactive A", "a.txt"), ("Interactive B", "b.txt"), ("Interactive C", "c.txt"), ("Interactive D", "d.txt")] {
            try fixture.write("\(subject)\n", to: repository.appendingPathComponent(path))
            try fixture.git(["add", "--all", "--"], in: repository)
            try fixture.git(["commit", "-m", subject], in: repository)
        }
        try fixture.git(["checkout", "main"], in: repository)
        try fixture.write("interactive target\n", to: repository.appendingPathComponent("interactive-target.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Interactive target"], in: repository)
        let target = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "interactive-feature"], in: repository)

        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()
        let plan = try await source.loadInteractiveRebasePlan(upstream: target)
        try require(plan.map(\.subject) == ["Interactive A", "Interactive B", "Interactive C", "Interactive D"], "interactive rebase: plan follows Git's oldest-to-newest order")
        let bySubject = Dictionary(uniqueKeysWithValues: plan.map { ($0.subject, $0) })
        let a = try required(bySubject["Interactive A"], "interactive rebase: A exists")
        let b = try required(bySubject["Interactive B"], "interactive rebase: B exists")
        let c = try required(bySubject["Interactive C"], "interactive rebase: C exists")
        let d = try required(bySubject["Interactive D"], "interactive rebase: D exists")
        let request = RepositoryInteractiveRebaseRequest(
            upstream: target,
            items: [
                RepositoryRebaseTodoItem(commitID: b.commitID, subject: b.subject, action: .pick),
                RepositoryRebaseTodoItem(commitID: a.commitID, subject: a.subject, action: .reword("Interactive A renamed")),
                RepositoryRebaseTodoItem(commitID: c.commitID, subject: c.subject, action: .squash),
                RepositoryRebaseTodoItem(commitID: d.commitID, subject: d.subject, action: .drop)
            ],
            autoStash: false
        )
        let result = try await source.interactiveRebase(request)
        try require(result.outcome == .completed, "interactive rebase: reorder/reword/squash/drop completes")
        let subjects = try fixture.git(["log", "--reverse", "--format=%s", "\(target)..HEAD"], in: repository)
            .split(separator: "\n").map(String.init)
        try require(subjects == ["Interactive B", "Interactive A renamed"], "interactive rebase: order, reword, and squash are reflected in history")
        try require(FileManager.default.fileExists(atPath: repository.appendingPathComponent("a.txt").path), "interactive rebase: reworded commit tree is retained")
        try require(FileManager.default.fileExists(atPath: repository.appendingPathComponent("c.txt").path), "interactive rebase: squashed commit tree is retained")
        try require(!FileManager.default.fileExists(atPath: repository.appendingPathComponent("d.txt").path), "interactive rebase: dropped commit tree is removed")
    }

    private static func testInteractiveRebaseEdit(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Interactive edit repo")
        try fixture.git(["checkout", "-b", "edit-feature"], in: repository)
        try fixture.write("edit me\n", to: repository.appendingPathComponent("edit.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Edit stop"], in: repository)
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()
        let target = try fixture.git(["rev-parse", "HEAD^"], in: repository).trimmed
        let plan = try await source.loadInteractiveRebasePlan(upstream: target)
        let item = try required(plan.first, "interactive edit: plan has a commit")
        var result = try await source.interactiveRebase(RepositoryInteractiveRebaseRequest(
            upstream: target,
            items: [RepositoryRebaseTodoItem(commitID: item.commitID, subject: item.subject, action: .edit)],
            autoStash: false
        ))
        guard case .paused = result.outcome else { throw MutationFixtureError("interactive edit: rebase did not pause") }
        let pausedState = try await source.loadMutationState()
        try require(pausedState.rebaseInProgress, "interactive edit: rebase state is visible while paused")
        try fixture.write("edited during pause\n", to: repository.appendingPathComponent("edit.txt"))
        _ = try await source.stage(paths: ["edit.txt"])
        _ = try await source.commit(RepositoryCommitRequest(
            message: "Edited commit",
            mode: .amend,
            stageAllBeforeCommit: false,
            allowEmpty: false,
            signOff: false,
            author: nil,
            resetAuthor: false
        ))
        result = try await source.continueRebase()
        try require(result.outcome == .completed, "interactive edit: continue completes")
        try require(try fixture.git(["log", "-1", "--format=%s"], in: repository).trimmed == "Edited commit", "interactive edit: amended commit survives continue")
        let continuedState = try await source.loadMutationState()
        try require(!continuedState.rebaseInProgress, "interactive edit: rebase state clears after continue")
    }

    private static func testRebaseConflictContinue(_ fixture: MutationGitFixture) async throws {
        let setup = try makeRebaseConflictRepository(fixture, name: "Rebase continue repo")
        let source = GitRepositoryBrowsingDataSource(repositoryURL: setup.repository)
        _ = try await source.loadSnapshot()
        var result = try await source.rebase(RepositoryRebaseRequest(upstream: setup.target, autoStash: false))
        guard case .conflicts(let paths) = result.outcome else { throw MutationFixtureError("rebase continue: conflict was not reported") }
        try require(paths == ["shared.txt"], "rebase continue: conflicted path is reported")
        try fixture.write("resolved rebase\n", to: setup.repository.appendingPathComponent("shared.txt"))
        _ = try await source.stage(paths: ["shared.txt"])
        result = try await source.continueRebase()
        try require(result.outcome == .completed, "rebase continue: resolved operation completes")
        try require(try fixture.git(["rev-parse", "HEAD^"], in: setup.repository).trimmed == setup.target, "rebase continue: rewritten commit is based on target")
        try require(try fixture.git(["log", "-1", "--format=%s"], in: setup.repository).trimmed == "Feature conflict", "rebase continue: original subject is preserved")
    }

    private static func testRebaseConflictSkip(_ fixture: MutationGitFixture) async throws {
        let setup = try makeRebaseConflictRepository(fixture, name: "Rebase skip repo")
        let source = GitRepositoryBrowsingDataSource(repositoryURL: setup.repository)
        _ = try await source.loadSnapshot()
        let conflicted = try await source.rebase(RepositoryRebaseRequest(upstream: setup.target, autoStash: false))
        guard case .conflicts = conflicted.outcome else { throw MutationFixtureError("rebase skip: conflict was not created") }
        let skipped = try await source.skipRebase()
        try require(skipped.outcome == .completed, "rebase skip: operation completes")
        try require(try fixture.git(["rev-parse", "HEAD"], in: setup.repository).trimmed == setup.target, "rebase skip: conflicting commit is omitted")
        try require(try String(contentsOf: setup.repository.appendingPathComponent("shared.txt"), encoding: .utf8) == "target conflict\n", "rebase skip: target content remains")
    }

    private static func testRebaseConflictAbort(_ fixture: MutationGitFixture) async throws {
        let setup = try makeRebaseConflictRepository(fixture, name: "Rebase abort repo")
        let source = GitRepositoryBrowsingDataSource(repositoryURL: setup.repository)
        _ = try await source.loadSnapshot()
        let conflicted = try await source.rebase(RepositoryRebaseRequest(upstream: setup.target, autoStash: false))
        guard case .conflicts = conflicted.outcome else { throw MutationFixtureError("rebase abort: conflict was not created") }
        let aborted = try await source.abortRebase()
        try require(aborted.outcome == .completed, "rebase abort: operation completes")
        try require(try fixture.git(["rev-parse", "HEAD"], in: setup.repository).trimmed == setup.originalHead, "rebase abort: original HEAD is restored")
        try require(try fixture.git(["branch", "--show-current"], in: setup.repository).trimmed == "conflict-feature", "rebase abort: original branch is restored")
        try require(try String(contentsOf: setup.repository.appendingPathComponent("shared.txt"), encoding: .utf8) == "feature conflict\n", "rebase abort: original worktree is restored")
        let abortedState = try await source.loadMutationState()
        try require(!abortedState.rebaseInProgress, "rebase abort: state is cleared")
    }

    private static func makeRebaseConflictRepository(
        _ fixture: MutationGitFixture,
        name: String
    ) throws -> (repository: URL, target: String, originalHead: String) {
        let repository = try fixture.clone(named: name)
        try fixture.git(["checkout", "-b", "conflict-feature"], in: repository)
        try fixture.write("feature conflict\n", to: repository.appendingPathComponent("shared.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Feature conflict"], in: repository)
        let originalHead = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "main"], in: repository)
        try fixture.write("target conflict\n", to: repository.appendingPathComponent("shared.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Target conflict"], in: repository)
        let target = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "conflict-feature"], in: repository)
        return (repository, target, originalHead)
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw MutationFixtureError(message) }
    }

    private static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw MutationFixtureError(message) }
        return value
    }
}

struct MutationFixtureError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class MutationGitFixture {
    let rootURL: URL
    let templateURL: URL

    private init(rootURL: URL, templateURL: URL) {
        self.rootURL = rootURL
        self.templateURL = templateURL
    }

    static func make() throws -> MutationGitFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitExtensionsMac-mutation-tests-\(UUID().uuidString)", isDirectory: true)
        let template = root.appendingPathComponent("Mutation template", isDirectory: true)
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        let fixture = MutationGitFixture(rootURL: root, templateURL: template)
        try fixture.git(["init", "--initial-branch=main"], in: template)
        try fixture.configureIdentity(in: template)
        try fixture.write("base\n", to: template.appendingPathComponent("shared.txt"))
        try fixture.write("main\n", to: template.appendingPathComponent("main.txt"))
        try fixture.write((1...20).map { "line \($0)" }.joined(separator: "\n") + "\n", to: template.appendingPathComponent("hunks.txt"))
        try fixture.git(["add", "--all", "--"], in: template)
        try fixture.git(["commit", "-m", "Initial"], in: template)
        try fixture.git(["checkout", "-b", "topic"], in: template)
        try fixture.write("topic\n", to: template.appendingPathComponent("shared.txt"))
        try fixture.write("topic file\n", to: template.appendingPathComponent("topic.txt"))
        try fixture.git(["add", "--all", "--"], in: template)
        try fixture.git(["commit", "-m", "Topic change"], in: template)
        try fixture.git(["checkout", "main"], in: template)
        return fixture
    }

    func clone(named name: String) throws -> URL {
        let destination = rootURL.appendingPathComponent(name, isDirectory: true)
        try git(["clone", "--no-hardlinks", templateURL.path, destination.path], in: rootURL)
        try configureIdentity(in: destination)
        return destination
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL, environment additions: [String: String] = [:]) throws -> String {
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
        additions.forEach { environment[$0.key] = $0.value }
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw MutationFixtureError("Fixture git \(arguments.joined(separator: " ")) failed: \(String(decoding: error, as: UTF8.self))")
        }
        return String(decoding: output, as: UTF8.self)
    }

    func configureIdentity(in directory: URL) throws {
        try git(["config", "user.name", "Mutation Fixture"], in: directory)
        try git(["config", "user.email", "mutation@example.com"], in: directory)
    }

    func write(_ string: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(string.utf8).write(to: url, options: .atomic)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
