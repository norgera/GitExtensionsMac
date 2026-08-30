@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import Foundation

enum GitRepositoryMutationTests {
    static func runCheckout() async throws {
        try testBranchNameNormalization()
        let fixture = try MutationGitFixture.make()
        defer { fixture.remove() }

        try await testLocalAndDetachedCheckout(fixture)
        try await testRemoteTrackingCheckout(fixture)
        try await testDirtyCheckoutFailure(fixture)
        try await testStagedAndUntrackedCheckoutFailures(fixture)
        try await testCheckoutLocalChangeModes(fixture)
        try await testRemoteResetAndDetachedCheckout(fixture)
        try await testBranchCreationAndValidation(fixture)
        try await testOrphanBranchCreation(fixture)
        try await testBranchRename(fixture)
        try await testBareBranchRename(fixture)
        try await testBranchDeletionSafety(fixture)
        try await testBranchDeletionInLinkedWorktree(fixture)
        print("GitRepositoryMutationTests.checkout: passed")
    }

    private static func testBranchNameNormalization() throws {
        try require(
            RepositoryBranchNameNormalizer.normalize(" feature name ") == "_feature_name_",
            "branch names: spaces use the upstream replacement token"
        )
        try require(
            RepositoryBranchNameNormalizer.normalize("/foo//.bar..baz.lock") == "foo/_bar_baz_lock",
            "branch names: slash, dot, component and lock rules are normalized"
        )
        try require(
            RepositoryBranchNameNormalizer.normalize(#"topic@{one}\\two?[x]^:"#) == "topic_one}_two__x]__",
            "branch names: reflog and revision-special characters are normalized"
        )
        try require(
            RepositoryBranchNameNormalizer.normalize("équipe/二") == "équipe/二",
            "branch names: Unicode letters and digits are preserved"
        )
    }

    static func runStaging() async throws {
        let fixture = try MutationGitFixture.make()
        defer { fixture.remove() }

        try await testFileStaging(fixture)
        try await testHunkStaging(fixture)
        try await testSelectedLineStaging(fixture)
        try await testSelectedLineDeletion(fixture)
        try await testSelectedLineRenamedFile(fixture)
        try await testSelectedLineNoNewlineHandling(fixture)
        print("GitRepositoryMutationTests.staging: passed")
    }

    static func runCommitAndAmend() async throws {
        let fixture = try MutationGitFixture.make()
        defer { fixture.remove() }

        try await testNormalCommit(fixture)
        try await testCommitValidation(fixture)
        try await testAmendModes(fixture)
        try await testCommitOptionsAndState(fixture)
        try await testCommitHooksAndSigning(fixture)
        try await testCommitDetachedConflictAndReset(fixture)
        try await testCommitValidationFailuresAndConflict(fixture)
        try await testCommitCancellation(fixture)
        try await testCommitAndPushIntegration(fixture)
        print("GitRepositoryMutationTests.commit: passed")
    }

    static func runStash() async throws {
        let fixture = try MutationGitFixture.make()
        defer { fixture.remove() }

        try await testStashCreationOptions(fixture)
        try await testStashSelectedPaths(fixture)
        try await testStashLifecycle(fixture)
        try await testStashDropSelection(fixture)
        try await testStashConflict(fixture)
        try await testStashPopConflictPreservesStash(fixture)
        print("GitRepositoryMutationTests.stash: passed")
    }

    static func runCherryPick() async throws {
        let fixture = try MutationGitFixture.make()
        defer { fixture.remove() }

        try await testSingleCherryPickAndDetachedHead(fixture)
        try await testCherryPickOrderingAndOptions(fixture)
        try await testCherryPickSequentialOptionsAndPartialCancel(fixture)
        try await testCherryPickMergeMainline(fixture)
        try await testCherryPickConflictContinue(fixture)
        try await testCherryPickConflictAbort(fixture)
        try await testCherryPickNonConflictFailure(fixture)
        print("GitRepositoryMutationTests.cherryPick: passed")
    }

    static func runRebase() async throws {
        let fixture = try MutationGitFixture.make()
        defer { fixture.remove() }

        try await testOrdinaryRebaseAndAutoStash(fixture)
        try await testAlreadyUpToDateRebase(fixture)
        try await testRebaseAdvancedOptions(fixture)
        try await testRebaseMerges(fixture)
        try await testRebaseDateModes(fixture)
        try await testDetachedHeadAndInvalidRebase(fixture)
        try await testInteractiveAutosquash(fixture)
        try await testNativeInteractiveTodo(fixture)
        try await testNativeInteractiveRebaseMerges(fixture)
        try await testNativeInteractiveUpdateRefs(fixture)
        try await testInteractiveRebasePlan(fixture)
        try await testInteractiveRebaseEdit(fixture)
        try await testEditActiveRebaseTodo(fixture)
        try await testApplyBackendRebaseState(fixture)
        try await testRebaseConflictContinue(fixture)
        try await testRebaseConflictMergeTool(fixture)
        try await testRebaseConflictSkip(fixture)
        try await testRebaseConflictAbort(fixture)
        try await testRebaseCancellation(fixture)
        print("GitRepositoryMutationTests.rebase: passed")
    }

    static func runMerge() async throws {
        let fixture = try MutationGitFixture.make()
        defer { fixture.remove() }

        try testMergeCommandConstruction()
        try await testMergeFastForwardAndAlreadyUpToDate(fixture)
        try await testMergeCommitOptions(fixture)
        try await testMergeSquashAndNoCommit(fixture)
        try await testMergeAdvancedTargets(fixture)
        try await testMergeValidationAndDiagnostics(fixture)
        try await testMergeConflictContinue(fixture)
        try await testMergeConflictAbort(fixture)
        try await testMergeCancellation(fixture)
        print("GitRepositoryMutationTests.merge: passed")
    }

    static func runTags() async throws {
        try testTagCommandConstruction()
        let fixture = try MutationGitFixture.make()
        defer { fixture.remove() }

        try await testTagCreationAndDeletion(fixture)
        try await testTagValidationAndForce(fixture)
        try await testTagDetachedAndArbitraryTargets(fixture)
        try await testTagsInBareRepository(fixture)
        print("GitRepositoryMutationTests.tags: passed")
    }

    private static func testTagCommandConstruction() throws {
        let target = try ObjectID.parse("0123456789012345678901234567890123456789")
        let path = "/tmp/TAGMESSAGE"
        let lightweight = try GitTagCommandBuilder.create(RepositoryCreateTagRequest(
            name: "release",
            target: target,
            force: true
        ))
        try require(
            lightweight.arguments == ["tag", "-f", "release", "--", target.string],
            "tags: lightweight arguments preserve upstream order"
        )
        let annotated = try GitTagCommandBuilder.create(RepositoryCreateTagRequest(
            name: "release",
            target: target,
            operation: .annotated,
            message: "Release"
        ), messageFile: path)
        try require(
            annotated.arguments == ["tag", "-a", "-F", path, "release", "--", target.string],
            "tags: annotated arguments preserve upstream order"
        )
        let defaultSigned = try GitTagCommandBuilder.create(RepositoryCreateTagRequest(
            name: "release",
            target: target,
            operation: .signWithDefaultKey,
            message: "Release",
            force: true
        ), messageFile: path)
        try require(
            defaultSigned.arguments == ["tag", "-f", "-s", "-F", path, "release", "--", target.string],
            "tags: default signing arguments are constructed without requiring a private key"
        )
        let specificallySigned = try GitTagCommandBuilder.create(RepositoryCreateTagRequest(
            name: "release",
            target: target,
            operation: .signWithSpecificKey,
            message: "Release",
            signingKey: "A9876F",
            force: true
        ), messageFile: path)
        try require(
            specificallySigned.arguments == ["tag", "-f", "-u", "A9876F", "-F", path, "release", "--", target.string],
            "tags: specific-key signing arguments preserve upstream order"
        )
        do {
            _ = try GitTagCommandBuilder.create(RepositoryCreateTagRequest(
                name: "release",
                target: target,
                operation: .signWithSpecificKey,
                message: "Release"
            ), messageFile: path)
            throw MutationFixtureError("tags: specific-key signing accepted an empty key")
        } catch RepositoryTagError.missingSigningKey {
            // Expected without invoking GPG or requiring a private key.
        }
        try require(
            specificallySigned.accessesRemote == false && specificallySigned.changesRepositoryState,
            "tags: creation is a structured local mutation"
        )
        let deletion = try GitTagCommandBuilder.delete(name: "release")
        try require(
            deletion.arguments == ["tag", "-d", "release"] && deletion.changesRepositoryState,
            "tags: deletion is a structured local mutation"
        )
    }

    private static func testTagCreationAndDeletion(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Tag create delete repo")
        let source = GitRepositoryModule(repositoryURL: repository)
        let state = try await source.loadRepositoryState()
        let head = try required(state.identity.headID, "tags: repository has HEAD")

        let lightweight = try await source.createTag(RepositoryCreateTagRequest(name: "lightweight", target: head))
        try require(lightweight.selectedCommitID == .object(head), "tags: selection remains on tagged revision")
        try require(
            try fixture.git(["rev-parse", "refs/tags/lightweight"], in: repository).trimmed == head.string,
            "tags: lightweight ref points directly at the selected object"
        )

        _ = try await source.createTag(RepositoryCreateTagRequest(
            name: "annotated",
            target: head,
            operation: .annotated,
            message: "Annotated release message\n\nDetails"
        ))
        try require(
            try fixture.git(["cat-file", "-t", "refs/tags/annotated"], in: repository).trimmed == "tag",
            "tags: annotated creation writes a tag object"
        )
        try require(
            try fixture.git(["rev-parse", "refs/tags/annotated^{}"], in: repository).trimmed == head.string,
            "tags: annotated tag peels to the selected commit"
        )
        let message = try fixture.git(["for-each-ref", "--format=%(contents)", "refs/tags/annotated"], in: repository)
        try require(message.contains("Annotated release message") && message.contains("Details"), "tags: annotated message is preserved")

        _ = try await source.deleteTag(named: "lightweight")
        try require(
            (try? fixture.git(["show-ref", "--verify", "refs/tags/lightweight"], in: repository)) == nil,
            "tags: local deletion removes the tag ref"
        )
    }

    private static func testTagValidationAndForce(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Tag validation repo")
        let source = GitRepositoryModule(repositoryURL: repository)
        let state = try await source.loadRepositoryState()
        let original = try required(state.identity.headID, "tags: original HEAD exists")
        _ = try await source.createTag(RepositoryCreateTagRequest(name: "movable", target: original))

        do {
            _ = try await source.createTag(RepositoryCreateTagRequest(name: "movable", target: original))
            throw MutationFixtureError("tags: existing tag was overwritten without force")
        } catch is GitError {
            // Git preserves the existing tag unless Force is selected.
        }
        do {
            _ = try await source.createTag(RepositoryCreateTagRequest(name: "bad tag", target: original))
            throw MutationFixtureError("tags: invalid ref name was accepted")
        } catch RepositoryTagError.invalidName {
            // Expected.
        }
        do {
            _ = try await source.createTag(RepositoryCreateTagRequest(name: "   ", target: original))
            throw MutationFixtureError("tags: blank name was accepted")
        } catch RepositoryTagError.missingName {
            // Expected.
        }

        try fixture.write("new tag target\n", to: repository.appendingPathComponent("tag-target.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "New tag target"], in: repository)
        let updated = try ObjectID.parse(fixture.git(["rev-parse", "HEAD"], in: repository).trimmed)
        _ = try await source.createTag(RepositoryCreateTagRequest(name: "movable", target: updated, force: true))
        try require(
            try fixture.git(["rev-parse", "refs/tags/movable"], in: repository).trimmed == updated.string,
            "tags: Force updates an existing tag"
        )
    }

    private static func testTagDetachedAndArbitraryTargets(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Detached tag repo")
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        try fixture.write("detached head\n", to: repository.appendingPathComponent("detached-tag.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Detached tag head"], in: repository)
        let parent = try await source.resolveTagTarget("HEAD~1")
        try fixture.git(["checkout", "--detach", "HEAD"], in: repository)
        _ = try await source.createTag(RepositoryCreateTagRequest(name: "arbitrary-target", target: parent))
        try require(
            try fixture.git(["rev-parse", "refs/tags/arbitrary-target"], in: repository).trimmed == parent.string,
            "tags: detached HEAD permits an explicitly resolved arbitrary target"
        )
    }

    private static func testTagsInBareRepository(_ fixture: MutationGitFixture) async throws {
        let repository = fixture.rootURL.appendingPathComponent("Bare tags.git", isDirectory: true)
        try fixture.git(["clone", "--bare", fixture.templateURL.path, repository.path], in: fixture.rootURL)
        let source = GitRepositoryModule(repositoryURL: repository)
        let state = try await source.loadRepositoryState()
        try require(state.identity.currentRepository.isBare, "tags: fixture is bare")
        let head = try required(state.identity.headID, "tags: bare repository has HEAD")
        _ = try await source.createTag(RepositoryCreateTagRequest(name: "bare-tag", target: head))
        try require(
            try fixture.git(["rev-parse", "refs/tags/bare-tag"], in: repository).trimmed == head.string,
            "tags: local tag creation remains eligible in a bare repository"
        )
        _ = try await source.deleteTag(named: "bare-tag")
        try require(
            (try? fixture.git(["show-ref", "--verify", "refs/tags/bare-tag"], in: repository)) == nil,
            "tags: local tag deletion remains eligible in a bare repository"
        )
    }

    static func runRemoteManagement() async throws {
        let fixture = try MutationGitFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.clone(named: "Remote management repo")
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()

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
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        var result = try await source.checkout(RepositoryCheckoutRequest(
            target: .localBranch(dailyBranch),
            localChanges: .keep
        ))
        var repositoryState = try await source.loadRepositoryState()
        try require(repositoryState.references.branches.contains { $0.name == dailyBranch && $0.isCurrent }, "external fixture: typed checkout switches to disposable branch")

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
        var snapshot = try await source.loadRepositoryState()
        let worktree = try required(RevisionCommitBuilder.artificialRevisions(headID: snapshot.identity.headID).first(where: { $0.kind == .workingDirectory }), "external fixture: worktree revision exists")
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
        repositoryState = try await source.loadRepositoryState()
        let stash = try required(repositoryState.navigation.stashes.first, "external fixture: typed stash create produces a stash")
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
        repositoryState = try await source.loadRepositoryState()
        _ = try await source.dropStash(try required(repositoryState.navigation.stashes.first, "external fixture: drop stash exists"))

        let dailyHead = try helper.git(["rev-parse", "HEAD"], in: repository).trimmed
        try helper.git(["checkout", "-b", cherryBranch, dailyHead], in: repository)
        try helper.write("cherry\n", to: repository.appendingPathComponent(cherryPath))
        try helper.git(["add", "--all", "--"], in: repository)
        try helper.git(["commit", "-m", "Phase 3 cherry source"], in: repository)
        let cherryCommit = try helper.git(["rev-parse", "HEAD"], in: repository).trimmed
        try helper.git(["checkout", dailyBranch], in: repository)
        _ = try await source.loadRepositoryState()
        result = try await source.cherryPick(RepositoryCherryPickRequest(
            items: [RepositoryCherryPickItem(commitID: try ObjectID.parse(cherryCommit), mainlineParent: nil)],
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
        snapshot = try await source.loadRepositoryState()
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
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()

        let switched = try await source.checkout(RepositoryCheckoutRequest(
            target: .localBranch("local-topic"),
            localChanges: .keep
        ))
        var repositoryState = try await source.loadRepositoryState()
        try require(repositoryState.references.branches.contains { $0.name == "local-topic" && $0.isCurrent }, "checkout: local branch becomes current")
        try require(switched.selectedCommitID == repositoryState.identity.headID.map(RevisionID.object), "checkout: selection follows the new HEAD")

        let sameBranch = try await source.checkout(RepositoryCheckoutRequest(
            target: .localBranch("local-topic"),
            localChanges: .keep
        ))
        repositoryState = try await source.loadRepositoryState()
        try require(
            repositoryState.references.branches.contains { $0.name == "local-topic" && $0.isCurrent },
            "checkout: selecting the current branch remains a successful Git checkout"
        )

        let mainID = try fixture.git(["rev-parse", "main"], in: repository).trimmed
        let detached = try await source.checkout(RepositoryCheckoutRequest(target: .revision(mainID), localChanges: .keep))
        let state = try await source.loadMutationState()
        try require(state.currentBranch == nil && state.headID == ObjectID.parse(mainID), "checkout: revision produces detached HEAD")
        repositoryState = try await source.loadRepositoryState()
        try require(repositoryState.identity.headID == ObjectID.parse(mainID), "checkout: detached HEAD is visible after refresh")
    }

    private static func testRemoteTrackingCheckout(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Remote checkout repo")
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()

        let mainID = try fixture.git(["rev-parse", "main"], in: repository).trimmed
        let topicID = try fixture.git(["rev-parse", "origin/topic"], in: repository).trimmed
        let divergence = try await source.divergence(
            from: ObjectID.parse(mainID),
            to: ObjectID.parse(topicID)
        )
        try require(
            divergence == RepositoryRevisionDivergence(added: 0, removed: 1)
                && divergence.displayText == "(+0-1)",
            "checkout: selected-branch divergence matches Git Extensions display semantics"
        )

        let result = try await source.checkout(RepositoryCheckoutRequest(
            target: .remoteBranch(remote: "origin", branch: "topic", mode: .createTracking(localBranch: "topic-local")),
            localChanges: .keep
        ))
        let upstream = try fixture.git(["rev-parse", "--abbrev-ref", "topic-local@{upstream}"], in: repository).trimmed
        try require(upstream == "origin/topic", "checkout: remote checkout creates explicit tracking")
        let repositoryState = try await source.loadRepositoryState()
        try require(repositoryState.references.branches.contains { $0.name == "topic-local" && $0.isCurrent && $0.remoteName == "origin" }, "checkout: tracking branch refreshes into repository state")

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
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()

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

    private static func testCheckoutLocalChangeModes(_ fixture: MutationGitFixture) async throws {
        let mergeRepository = try fixture.clone(named: "Checkout merge changes repo")
        try fixture.git(["branch", "local-topic", "origin/topic"], in: mergeRepository)
        try fixture.write("local main edit\n", to: mergeRepository.appendingPathComponent("main.txt"))
        let mergeSource = GitRepositoryModule(repositoryURL: mergeRepository)
        _ = try await mergeSource.loadRepositoryState()
        _ = try await mergeSource.checkout(RepositoryCheckoutRequest(
            target: .localBranch("local-topic"),
            localChanges: .merge
        ))
        try require(try fixture.git(["branch", "--show-current"], in: mergeRepository).trimmed == "local-topic", "checkout merge: target becomes current")
        try require(try String(contentsOf: mergeRepository.appendingPathComponent("main.txt"), encoding: .utf8) == "local main edit\n", "checkout merge: local edit is preserved")

        let forceRepository = try fixture.clone(named: "Checkout force changes repo")
        try fixture.git(["branch", "local-topic", "origin/topic"], in: forceRepository)
        try fixture.write("discard me\n", to: forceRepository.appendingPathComponent("shared.txt"))
        let forceSource = GitRepositoryModule(repositoryURL: forceRepository)
        _ = try await forceSource.loadRepositoryState()
        _ = try await forceSource.checkout(RepositoryCheckoutRequest(
            target: .localBranch("local-topic"),
            localChanges: .force
        ))
        try require(try String(contentsOf: forceRepository.appendingPathComponent("shared.txt"), encoding: .utf8) == "topic\n", "checkout force: conflicting local edit is discarded")

        let stashRepository = try fixture.clone(named: "Checkout stash changes repo")
        try fixture.git(["branch", "local-topic", "origin/topic"], in: stashRepository)
        try fixture.write("stashed edit\n", to: stashRepository.appendingPathComponent("main.txt"))
        try fixture.write("untracked\n", to: stashRepository.appendingPathComponent("untracked checkout.txt"))
        let stashSource = GitRepositoryModule(repositoryURL: stashRepository)
        _ = try await stashSource.loadRepositoryState()
        _ = try await stashSource.checkout(RepositoryCheckoutRequest(
            target: .localBranch("local-topic"),
            localChanges: .stash(includeUntracked: true, reapply: true)
        ))
        try require(try fixture.git(["branch", "--show-current"], in: stashRepository).trimmed == "local-topic", "checkout stash: target becomes current")
        try require(FileManager.default.fileExists(atPath: stashRepository.appendingPathComponent("untracked checkout.txt").path), "checkout stash: included untracked file is reapplied")
        try require(try fixture.git(["stash", "list"], in: stashRepository).trimmed.isEmpty, "checkout stash: successful automatic pop removes stash")
    }

    private static func testStagedAndUntrackedCheckoutFailures(_ fixture: MutationGitFixture) async throws {
        let stagedRepository = try fixture.clone(named: "Staged checkout failure repo")
        try fixture.git(["branch", "local-topic", "origin/topic"], in: stagedRepository)
        try fixture.write("staged conflict\n", to: stagedRepository.appendingPathComponent("shared.txt"))
        try fixture.git(["add", "shared.txt"], in: stagedRepository)
        let stagedSource = GitRepositoryModule(repositoryURL: stagedRepository)
        _ = try await stagedSource.loadRepositoryState()
        do {
            _ = try await stagedSource.checkout(RepositoryCheckoutRequest(target: .localBranch("local-topic"), localChanges: .keep))
            throw MutationFixtureError("checkout: conflicting staged change unexpectedly switched")
        } catch let error as GitError {
            try require(error.errorDescription?.contains("would be overwritten by checkout") == true, "checkout: staged failure preserves Git diagnostics")
        }
        try require(try fixture.git(["diff", "--cached", "--name-only"], in: stagedRepository).trimmed == "shared.txt", "checkout: staged failure preserves index")

        let untrackedRepository = try fixture.clone(named: "Untracked checkout failure repo")
        try fixture.git(["branch", "local-topic", "origin/topic"], in: untrackedRepository)
        try fixture.write("obstructing untracked\n", to: untrackedRepository.appendingPathComponent("topic.txt"))
        let untrackedSource = GitRepositoryModule(repositoryURL: untrackedRepository)
        _ = try await untrackedSource.loadRepositoryState()
        do {
            _ = try await untrackedSource.checkout(RepositoryCheckoutRequest(target: .localBranch("local-topic"), localChanges: .keep))
            throw MutationFixtureError("checkout: obstructing untracked file unexpectedly switched")
        } catch let error as GitError {
            try require(error.errorDescription?.contains("untracked working tree files would be overwritten") == true, "checkout: untracked collision preserves Git diagnostics")
        }
        try require(try String(contentsOf: untrackedRepository.appendingPathComponent("topic.txt"), encoding: .utf8) == "obstructing untracked\n", "checkout: untracked failure preserves file")
    }

    private static func testRemoteResetAndDetachedCheckout(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Remote reset checkout repo")
        try fixture.git(["checkout", "-b", "tracked-topic", "--track", "origin/topic"], in: repository)
        try fixture.git(["reset", "--hard", "main"], in: repository)
        try fixture.git(["checkout", "main"], in: repository)
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()

        _ = try await source.checkout(RepositoryCheckoutRequest(
            target: .remoteBranch(remote: "origin", branch: "topic", mode: .resetTracking(localBranch: "tracked-topic")),
            localChanges: .keep
        ))
        let resetLocal = try fixture.git(["rev-parse", "tracked-topic"], in: repository).trimmed
        let resetRemote = try fixture.git(["rev-parse", "origin/topic"], in: repository).trimmed
        try require(resetLocal == resetRemote, "remote reset: local ref resets to remote")
        try require(try fixture.git(["rev-parse", "--abbrev-ref", "tracked-topic@{upstream}"], in: repository).trimmed == "origin/topic", "remote reset: existing tracking configuration remains")

        try fixture.git(["checkout", "main"], in: repository)
        _ = try await source.loadRepositoryState()
        _ = try await source.checkout(RepositoryCheckoutRequest(
            target: .remoteBranch(remote: "origin", branch: "topic", mode: .detached),
            localChanges: .keep
        ))
        let state = try await source.loadMutationState()
        let remoteID = try fixture.git(["rev-parse", "origin/topic"], in: repository).trimmed
        try require(state.currentBranch == nil && state.headID == ObjectID.parse(remoteID), "remote checkout: detached mode checks out the remote ref")

        _ = try await source.checkout(RepositoryCheckoutRequest(target: .localBranch("main"), localChanges: .keep))
        try require(try fixture.git(["symbolic-ref", "--short", "HEAD"], in: repository).trimmed == "main", "checkout: local branch restores symbolic HEAD from detached state")
    }

    private static func testBranchCreationAndValidation(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Branch creation repo")
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let main = try fixture.git(["rev-parse", "main"], in: repository).trimmed
        let topic = try fixture.git(["rev-parse", "origin/topic"], in: repository).trimmed

        _ = try await source.createBranch(RepositoryCreateBranchRequest(
            name: "created-at-head",
            sourceRevision: nil,
            checkoutAfterCreation: false,
            mode: .normal
        ))
        try require(try fixture.git(["rev-parse", "created-at-head"], in: repository).trimmed == main, "create branch: no-checkout branch points at HEAD")
        try require(try fixture.git(["branch", "--show-current"], in: repository).trimmed == "main", "create branch: no-checkout leaves HEAD unchanged")

        _ = try await source.createBranch(RepositoryCreateBranchRequest(
            name: "created-at-topic",
            sourceRevision: topic,
            checkoutAfterCreation: true,
            mode: .normal
        ))
        try require(try fixture.git(["branch", "--show-current"], in: repository).trimmed == "created-at-topic", "create branch: create-and-checkout updates symbolic HEAD")
        try require(try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed == topic, "create branch: selected source revision is honored")

        do {
            _ = try await source.createBranch(RepositoryCreateBranchRequest(name: "bad name", sourceRevision: main, checkoutAfterCreation: false, mode: .normal))
            throw MutationFixtureError("create branch: invalid name was accepted")
        } catch RepositoryMutationError.invalidBranchName(let name) {
            try require(name == "bad name", "create branch: invalid name is preserved")
        }
        do {
            _ = try await source.createBranch(RepositoryCreateBranchRequest(name: "created-at-head", sourceRevision: main, checkoutAfterCreation: false, mode: .normal))
            throw MutationFixtureError("create branch: existing name was accepted")
        } catch let error as GitError {
            try require(error.errorDescription?.contains("already exists") == true, "create branch: collision preserves Git diagnostics")
        }
    }

    private static func testOrphanBranchCreation(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Orphan branch repo")
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        _ = try await source.createBranch(RepositoryCreateBranchRequest(
            name: "orphan-docs",
            sourceRevision: "HEAD",
            checkoutAfterCreation: true,
            mode: .orphan(clearWorkingDirectoryAndIndex: true)
        ))
        try require(try fixture.git(["branch", "--show-current"], in: repository).trimmed == "orphan-docs", "orphan branch: symbolic HEAD uses new name")
        try require(try fixture.git(["status", "--porcelain"], in: repository).trimmed.isEmpty, "orphan branch: clearing removes tracked index/worktree files")

        let unborn = fixture.rootURL.appendingPathComponent("Unborn branch repo", isDirectory: true)
        try FileManager.default.createDirectory(at: unborn, withIntermediateDirectories: true)
        try fixture.git(["init", "--initial-branch=main"], in: unborn)
        try fixture.configureIdentity(in: unborn)
        let unbornSource = GitRepositoryModule(repositoryURL: unborn)
        _ = try await unbornSource.loadRepositoryState()
        let unbornState = try await unbornSource.loadMutationState()
        try require(unbornState.headID == nil, "orphan branch: empty repository is detected as unborn")
        _ = try await unbornSource.createBranch(RepositoryCreateBranchRequest(
            name: "first-branch",
            sourceRevision: nil,
            checkoutAfterCreation: true,
            mode: .orphan(clearWorkingDirectoryAndIndex: false)
        ))
        try require(
            try fixture.git(["symbolic-ref", "--short", "HEAD"], in: unborn).trimmed == "first-branch",
            "orphan branch: empty repository changes its unborn symbolic HEAD"
        )
    }

    private static func testBranchRename(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Branch rename repo")
        try fixture.git(["branch", "rename-me"], in: repository)
        try fixture.git(["branch", "collision"], in: repository)
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        _ = try await source.renameBranch(RepositoryRenameBranchRequest(oldName: "rename-me", newName: "renamed"))
        try require(try fixture.git(["show-ref", "--verify", "refs/heads/renamed"], in: repository).contains("refs/heads/renamed"), "rename branch: non-current ref is renamed")

        _ = try await source.renameBranch(RepositoryRenameBranchRequest(oldName: "main", newName: "primary"))
        try require(try fixture.git(["branch", "--show-current"], in: repository).trimmed == "primary", "rename branch: current symbolic HEAD is refreshed")
        do {
            _ = try await source.renameBranch(RepositoryRenameBranchRequest(oldName: "primary", newName: "collision"))
            throw MutationFixtureError("rename branch: collision was accepted")
        } catch let error as GitError {
            try require(error.errorDescription?.contains("already exists") == true, "rename branch: collision retains Git diagnostics")
        }
    }

    private static func testBranchDeletionSafety(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Branch deletion repo")
        try fixture.git(["branch", "merged-one", "main"], in: repository)
        try fixture.git(["branch", "merged-two", "main"], in: repository)
        try fixture.git(["branch", "unmerged-topic", "origin/topic"], in: repository)
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()

        let candidates = try await source.branchDeletionCandidates(names: ["merged-one", "unmerged-topic"])
        try require(candidates.first(where: { $0.name == "merged-one" })?.isMergedIntoHEAD == true, "delete branch: merged branch is classified")
        try require(candidates.first(where: { $0.name == "unmerged-topic" })?.isMergedIntoHEAD == false, "delete branch: unmerged branch is classified")
        do {
            _ = try await source.deleteBranches(RepositoryDeleteBranchesRequest(names: ["unmerged-topic"], allowUnmerged: false, removeLinkedWorktrees: false))
            throw MutationFixtureError("delete branch: unmerged branch bypassed confirmation gate")
        } catch RepositoryBranchError.unmergedBranches(let names) {
            try require(names == ["unmerged-topic"], "delete branch: unmerged error retains selected branch")
        }
        _ = try await source.deleteBranches(RepositoryDeleteBranchesRequest(names: ["merged-one", "merged-two"], allowUnmerged: false, removeLinkedWorktrees: false))
        try require((try? fixture.git(["show-ref", "--verify", "refs/heads/merged-one"], in: repository)) == nil, "delete branch: merged ref is removed")
        _ = try await source.deleteBranches(RepositoryDeleteBranchesRequest(names: ["unmerged-topic"], allowUnmerged: true, removeLinkedWorktrees: false))
        try require((try? fixture.git(["show-ref", "--verify", "refs/heads/unmerged-topic"], in: repository)) == nil, "delete branch: confirmed force path removes unmerged ref")

        do {
            _ = try await source.deleteBranches(RepositoryDeleteBranchesRequest(names: ["main"], allowUnmerged: true, removeLinkedWorktrees: false))
            throw MutationFixtureError("delete branch: current branch was accepted")
        } catch RepositoryMutationError.currentBranch(let name) {
            try require(name == "main", "delete branch: current restriction retains branch name")
        }
        do {
            _ = try await source.branchDeletionCandidates(names: ["does-not-exist"])
            throw MutationFixtureError("delete branch: missing branch was accepted")
        } catch RepositoryBranchError.branchNotFound(let name) {
            try require(name == "does-not-exist", "delete branch: missing name is retained")
        }
    }

    private static func testBareBranchRename(_ fixture: MutationGitFixture) async throws {
        let repository = fixture.rootURL.appendingPathComponent("Bare rename repo.git", isDirectory: true)
        try fixture.git(["clone", "--bare", fixture.templateURL.path, repository.path], in: fixture.rootURL)
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        _ = try await source.renameBranch(RepositoryRenameBranchRequest(oldName: "main", newName: "primary"))
        try require(try fixture.git(["show-ref", "--verify", "refs/heads/primary"], in: repository).contains("refs/heads/primary"), "rename branch: bare repository ref is renamed")
    }

    private static func testBranchDeletionInLinkedWorktree(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Branch worktree deletion repo")
        let worktree = fixture.rootURL.appendingPathComponent("Linked branch worktree", isDirectory: true)
        try fixture.git(["worktree", "add", "-b", "linked-delete", worktree.path, "main"], in: repository)
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let preview = try await source.branchDeletionCandidates(names: ["linked-delete"])
        let expectedPath = worktree.resolvingSymlinksInPath().path
        try require(preview.first.map { URL(fileURLWithPath: $0.worktreePath ?? "").resolvingSymlinksInPath().path } == expectedPath, "delete branch: linked worktree path is detected")

        let linkedSource = GitRepositoryModule(repositoryURL: worktree)
        _ = try await linkedSource.loadRepositoryState()
        let mainPreview = try await linkedSource.branchDeletionCandidates(names: ["main"])
        try require(mainPreview.first?.isMainWorktree == true, "delete branch: the primary worktree is distinguished from linked worktrees")
        do {
            _ = try await linkedSource.deleteBranches(RepositoryDeleteBranchesRequest(names: ["main"], allowUnmerged: true, removeLinkedWorktrees: true))
            throw MutationFixtureError("delete branch: main worktree branch was accepted from a linked worktree")
        } catch RepositoryBranchError.branchCheckedOutInMainWorktree(let name, _) {
            try require(name == "main", "delete branch: main worktree restriction retains branch name")
        }
        do {
            _ = try await source.deleteBranches(RepositoryDeleteBranchesRequest(names: ["linked-delete"], allowUnmerged: false, removeLinkedWorktrees: false))
            throw MutationFixtureError("delete branch: linked worktree bypassed confirmation gate")
        } catch RepositoryBranchError.branchCheckedOut(let name, let path) {
            try require(name == "linked-delete" && URL(fileURLWithPath: path).resolvingSymlinksInPath().path == expectedPath, "delete branch: linked worktree diagnostics retain name/path")
        }
        _ = try await source.deleteBranches(RepositoryDeleteBranchesRequest(names: ["linked-delete"], allowUnmerged: false, removeLinkedWorktrees: true))
        try require(!FileManager.default.fileExists(atPath: worktree.path), "delete branch: confirmed linked worktree is removed")
        try require((try? fixture.git(["show-ref", "--verify", "refs/heads/linked-delete"], in: repository)) == nil, "delete branch: linked ref is removed")
    }

    private static func testFileStaging(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "File staging repo")
        try fixture.write("changed main\n", to: repository.appendingPathComponent("shared.txt"))
        try fixture.write("new file\n", to: repository.appendingPathComponent("new file.txt"))
        try FileManager.default.removeItem(at: repository.appendingPathComponent("main.txt"))
        let source = GitRepositoryModule(repositoryURL: repository)
        var snapshot = try await source.loadRepositoryState()
        let worktree = try required(RevisionCommitBuilder.artificialRevisions(headID: snapshot.identity.headID).first(where: { $0.kind == .workingDirectory }), "staging: worktree revision exists")
        let worktreeDetails = try await source.loadRevisionDetails(for: worktree)
        try require(Set(worktreeDetails.files.map(\.path)).isSuperset(of: ["shared.txt", "new file.txt", "main.txt"]), "staging: worktree lists modified, untracked, and deleted paths")

        var result = try await source.stage(paths: ["shared.txt", "new file.txt", "main.txt"])
        let cached = try fixture.git(["diff", "--cached", "--name-only"], in: repository)
        try require(cached.contains("shared.txt") && cached.contains("new file.txt") && cached.contains("main.txt"), "staging: selected paths include additions and deletion")
        snapshot = try await source.loadRepositoryState()
        let index = try required(RevisionCommitBuilder.artificialRevisions(headID: snapshot.identity.headID).first(where: { $0.kind == .index }), "staging: refreshed index revision exists")
        let indexDetails = try await source.loadRevisionDetails(for: index)
        try require(Set(indexDetails.files.map(\.path)).isSuperset(of: ["shared.txt", "new file.txt", "main.txt"]), "staging: index artificial revision refreshes")

        result = try await source.unstage(paths: ["new file.txt", "main.txt"])
        let remaining = try fixture.git(["diff", "--cached", "--name-only"], in: repository)
        try require(remaining.trimmed == "shared.txt", "staging: selected unstage leaves unrelated index entries")
        try require(result.selectedCommitID == .index, "staging: unstage retains index selection intent")

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
        let source = GitRepositoryModule(repositoryURL: repository)
        var snapshot = try await source.loadRepositoryState()
        var worktree = try required(RevisionCommitBuilder.artificialRevisions(headID: snapshot.identity.headID).first(where: { $0.kind == .workingDirectory }), "hunks: worktree revision exists")
        var details = try await source.loadRevisionDetails(for: worktree)
        let file = try required(details.files.first(where: { $0.path == "hunks.txt" }), "hunks: modified file is present")
        let diff = try required(try await source.loadDiff(for: worktree, file: file), "hunks: worktree patch is parsed lazily")
        let firstChangedLine = try required(diff.lines.first(where: { $0.kind == .addition && $0.text == "line 2 changed" }), "hunks: first changed line exists")

        var result = try await source.applyHunk(RepositoryHunkSelection(file: file, diff: diff, lineID: firstChangedLine.id, direction: .stage))
        let cached = try fixture.git(["diff", "--cached", "--", "hunks.txt"], in: repository)
        let unstaged = try fixture.git(["diff", "--", "hunks.txt"], in: repository)
        try require(cached.contains("line 2 changed") && !cached.contains("line 18 changed"), "hunks: stage applies only the selected hunk")
        try require(!unstaged.contains("line 2 changed") && unstaged.contains("line 18 changed"), "hunks: unselected hunk stays in the worktree")

        snapshot = try await source.loadRepositoryState()
        let index = try required(RevisionCommitBuilder.artificialRevisions(headID: snapshot.identity.headID).first(where: { $0.kind == .index }), "hunks: index revision exists after stage")
        details = try await source.loadRevisionDetails(for: index)
        let stagedFile = try required(details.files.first(where: { $0.path == "hunks.txt" }), "hunks: staged file is present")
        let stagedDiff = try required(try await source.loadDiff(for: index, file: stagedFile), "hunks: staged patch is parsed lazily")
        let stagedLine = try required(stagedDiff.lines.first(where: { $0.kind == .addition && $0.text == "line 2 changed" }), "hunks: staged line exists")
        result = try await source.applyHunk(RepositoryHunkSelection(file: stagedFile, diff: stagedDiff, lineID: stagedLine.id, direction: .unstage))
        try require(try fixture.git(["diff", "--cached", "--", "hunks.txt"], in: repository).trimmed.isEmpty, "hunks: reverse apply unstages selected hunk")
        snapshot = try await source.loadRepositoryState()
        let refreshedArtificial = RevisionCommitBuilder.artificialRevisions(headID: snapshot.identity.headID)
        try require(refreshedArtificial.contains { $0.kind == .workingDirectory }, "hunks: both artificial revisions survive refresh")
        worktree = try required(refreshedArtificial.first(where: { $0.kind == .workingDirectory }), "hunks: refreshed worktree exists")
        let refreshed = try await source.loadRevisionDetails(for: worktree)
        try require(refreshed.files.contains { $0.path == "hunks.txt" }, "hunks: worktree detail reloads after unstage")
    }

    private static func testSelectedLineStaging(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Selected line staging repo")
        var lines = (1...20).map { "line \($0)" }
        lines.insert("selected insertion", at: 4)
        lines.insert("remaining insertion", at: 7)
        try fixture.write(lines.joined(separator: "\n") + "\n", to: repository.appendingPathComponent("hunks.txt"))
        let source = GitRepositoryModule(repositoryURL: repository)
        var snapshot = try await source.loadRepositoryState()
        let worktree = try required(RevisionCommitBuilder.artificialRevisions(headID: snapshot.identity.headID).first(where: { $0.kind == .workingDirectory }), "lines: worktree revision exists")
        var details = try await source.loadRevisionDetails(for: worktree)
        var file = try required(details.files.first(where: { $0.path == "hunks.txt" }), "lines: modified file exists")
        var diff = try required(try await source.loadDiff(for: worktree, file: file), "lines: worktree patch loads")
        let selected = try required(diff.lines.first(where: { $0.kind == .addition && $0.text == "selected insertion" }), "lines: first inserted line exists")
        let remaining = try required(diff.lines.first(where: { $0.kind == .addition && $0.text == "remaining insertion" }), "lines: second inserted line exists")
        let selectedHunk = diff.lines.lastIndex(where: { line in
            line.kind == .hunk && diff.lines.firstIndex(where: { $0.id == selected.id }).map { diff.lines.firstIndex(where: { $0.id == line.id })! <= $0 } == true
        })
        let remainingHunk = diff.lines.lastIndex(where: { line in
            line.kind == .hunk && diff.lines.firstIndex(where: { $0.id == remaining.id }).map { diff.lines.firstIndex(where: { $0.id == line.id })! <= $0 } == true
        })
        try require(selectedHunk == remainingHunk, "lines: both additions are in one Git hunk")

        var result = try await source.applyLines(RepositoryLineSelection(
            file: file,
            diff: diff,
            lineIDs: [selected.id],
            direction: .stage
        ))
        var cached = try fixture.git(["diff", "--cached", "--", "hunks.txt"], in: repository)
        var unstaged = try fixture.git(["diff", "--", "hunks.txt"], in: repository)
        try require(cached.contains("\n+selected insertion") && !cached.contains("\n+remaining insertion"), "lines: only selected addition is staged")
        try require(!unstaged.contains("\n+selected insertion") && unstaged.contains("\n+remaining insertion"), "lines: unselected addition remains unstaged; cached=\(cached) unstaged=\(unstaged)")

        snapshot = try await source.loadRepositoryState()
        let index = try required(RevisionCommitBuilder.artificialRevisions(headID: snapshot.identity.headID).first(where: { $0.kind == .index }), "lines: index revision exists")
        details = try await source.loadRevisionDetails(for: index)
        file = try required(details.files.first(where: { $0.path == "hunks.txt" }), "lines: staged file exists")
        diff = try required(try await source.loadDiff(for: index, file: file), "lines: staged patch loads")
        let stagedLine = try required(diff.lines.first(where: { $0.kind == .addition && $0.text == "selected insertion" }), "lines: staged addition exists")
        result = try await source.applyLines(RepositoryLineSelection(
            file: file,
            diff: diff,
            lineIDs: [stagedLine.id],
            direction: .unstage
        ))
        cached = try fixture.git(["diff", "--cached", "--", "hunks.txt"], in: repository)
        unstaged = try fixture.git(["diff", "--", "hunks.txt"], in: repository)
        try require(cached.trimmed.isEmpty, "lines: selected staged line is unstaged")
        try require(unstaged.contains("\n+selected insertion") && unstaged.contains("\n+remaining insertion"), "lines: both additions return to worktree")
        snapshot = try await source.loadRepositoryState()
        try require(RevisionCommitBuilder.artificialRevisions(headID: snapshot.identity.headID).contains { $0.kind == .workingDirectory }, "lines: refreshed worktree remains available")

        try fixture.write("first new line\nselected new line\nlast new line\n", to: repository.appendingPathComponent("new-lines.txt"))
        snapshot = try await source.loadRepositoryState()
        let newWorktree = try required(RevisionCommitBuilder.artificialRevisions(headID: snapshot.identity.headID).first(where: { $0.kind == .workingDirectory }), "lines: worktree revision exists for a newly added file")
        details = try await source.loadRevisionDetails(for: newWorktree)
        file = try required(details.files.first(where: { $0.path == "new-lines.txt" }), "lines: newly added worktree file exists")
        diff = try required(try await source.loadDiff(for: newWorktree, file: file), "lines: newly added worktree patch loads")
        var selectedNewLine = try required(diff.lines.first(where: { $0.kind == .addition && $0.text == "selected new line" }), "lines: untracked-file line is selectable")
        _ = try await source.applyLines(RepositoryLineSelection(
            file: file,
            diff: diff,
            lineIDs: [selectedNewLine.id],
            direction: .stage
        ))
        cached = try fixture.git(["show", ":new-lines.txt"], in: repository)
        try require(cached == "selected new line\n", "lines: selected-line stage creates a partial index entry for an untracked file")

        result = try await source.stage(paths: ["new-lines.txt"])
        snapshot = try await source.loadRepositoryState()
        let newIndex = try required(RevisionCommitBuilder.artificialRevisions(headID: snapshot.identity.headID).first(where: { $0.kind == .index }), "lines: index revision exists for a newly added file")
        details = try await source.loadRevisionDetails(for: newIndex)
        file = try required(details.files.first(where: { $0.path == "new-lines.txt" }), "lines: newly added staged file exists")
        diff = try required(try await source.loadDiff(for: newIndex, file: file), "lines: newly added file patch loads")
        selectedNewLine = try required(diff.lines.first(where: { $0.kind == .addition && $0.text == "selected new line" }), "lines: added-file line is selectable")
        result = try await source.applyLines(RepositoryLineSelection(
            file: file,
            diff: diff,
            lineIDs: [selectedNewLine.id],
            direction: .unstage
        ))
        cached = try fixture.git(["show", ":new-lines.txt"], in: repository)
        try require(cached == "first new line\nlast new line\n", "lines: selected-line unstage rewrites a new-file patch without dropping its other indexed lines")
        try require(try String(contentsOf: repository.appendingPathComponent("new-lines.txt"), encoding: .utf8) == "first new line\nselected new line\nlast new line\n", "lines: selected-line unstage leaves the worktree copy intact")
    }

    private static func testSelectedLineNoNewlineHandling(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Selected line newline repo")
        let path = "line-ending.txt"
        try fixture.write("base\n", to: repository.appendingPathComponent(path))
        try fixture.git(["add", "--", path], in: repository)
        try fixture.git(["commit", "-m", "Add line ending fixture"], in: repository)
        try fixture.write("base\nselected line\nremaining line", to: repository.appendingPathComponent(path))

        let source = GitRepositoryModule(repositoryURL: repository)
        let snapshot = try await source.loadRepositoryState()
        let worktree = try required(RevisionCommitBuilder.artificialRevisions(headID: snapshot.identity.headID).first(where: { $0.kind == .workingDirectory }), "line endings: worktree revision exists")
        let details = try await source.loadRevisionDetails(for: worktree)
        let file = try required(details.files.first(where: { $0.path == path }), "line endings: changed file exists")
        let diff = try required(try await source.loadDiff(for: worktree, file: file), "line endings: worktree patch loads")
        let selected = try required(diff.lines.first(where: { $0.kind == .addition && $0.text == "selected line" }), "line endings: non-final addition is selectable")
        _ = try await source.applyLines(RepositoryLineSelection(
            file: file,
            diff: diff,
            lineIDs: [selected.id],
            direction: .stage
        ))
        let indexed = try fixture.git(["show", ":\(path)"], in: repository)
        try require(indexed == "base\nselected line\n", "line endings: staging a non-final line does not inherit the worktree EOF no-newline marker")
        try require(try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8) == "base\nselected line\nremaining line", "line endings: partial stage preserves the no-newline worktree")
    }

    private static func testSelectedLineDeletion(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Selected line deletion repo")
        let path = "hunks.txt"
        var worktreeLines = (1...20).map { "line \($0)" }
        worktreeLines[5] = "replacement line 6"
        try fixture.write(worktreeLines.joined(separator: "\n") + "\n", to: repository.appendingPathComponent(path))

        let source = GitRepositoryModule(repositoryURL: repository)
        var snapshot = try await source.loadRepositoryState()
        var worktree = try required(RevisionCommitBuilder.artificialRevisions(headID: snapshot.identity.headID).first(where: { $0.kind == .workingDirectory }), "line deletion: worktree revision exists")
        var details = try await source.loadRevisionDetails(for: worktree)
        var file = try required(details.files.first(where: { $0.path == path }), "line deletion: changed file exists")
        var diff = try required(try await source.loadDiff(for: worktree, file: file), "line deletion: worktree patch loads")
        let deletion = try required(diff.lines.first(where: { $0.kind == .deletion && $0.text == "line 6" }), "line deletion: removed side is selectable")
        var result = try await source.applyLines(RepositoryLineSelection(
            file: file,
            diff: diff,
            lineIDs: [deletion.id],
            direction: .stage
        ))
        let expectedIndex = ((1...20).filter { $0 != 6 }.map { "line \($0)" }).joined(separator: "\n") + "\n"
        try require(try fixture.git(["show", ":\(path)"], in: repository) == expectedIndex, "line deletion: staging only a deletion omits its unselected replacement")
        try require(try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8) == worktreeLines.joined(separator: "\n") + "\n", "line deletion: partial stage preserves the replacement in the worktree")

        snapshot = try await source.loadRepositoryState()
        let index = try required(RevisionCommitBuilder.artificialRevisions(headID: snapshot.identity.headID).first(where: { $0.kind == .index }), "line deletion: refreshed index revision exists")
        details = try await source.loadRevisionDetails(for: index)
        file = try required(details.files.first(where: { $0.path == path }), "line deletion: staged file exists")
        diff = try required(try await source.loadDiff(for: index, file: file), "line deletion: staged patch loads")
        let stagedDeletion = try required(diff.lines.first(where: { $0.kind == .deletion && $0.text == "line 6" }), "line deletion: staged deletion is selectable")
        result = try await source.applyLines(RepositoryLineSelection(
            file: file,
            diff: diff,
            lineIDs: [stagedDeletion.id],
            direction: .unstage
        ))
        try require(try fixture.git(["diff", "--cached", "--", path], in: repository).trimmed.isEmpty, "line deletion: selected deletion unstages cleanly")
        snapshot = try await source.loadRepositoryState()
        worktree = try required(RevisionCommitBuilder.artificialRevisions(headID: snapshot.identity.headID).first(where: { $0.kind == .workingDirectory }), "line deletion: worktree remains after unstage")
        let worktreeDetails = try await source.loadRevisionDetails(for: worktree)
        try require(worktreeDetails.files.contains { $0.path == path }, "line deletion: replacement remains an unstaged worktree change")
    }

    private static func testSelectedLineRenamedFile(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Selected line rename repo")
        let oldPath = "hunks.txt"
        let newPath = "renamed-hunks.txt"
        try fixture.git(["mv", "--", oldPath, newPath], in: repository)
        var renamedLines = (1...20).map { "line \($0)" }
        renamedLines[5] = "renamed replacement line 6"
        try fixture.write(renamedLines.joined(separator: "\n") + "\n", to: repository.appendingPathComponent(newPath))

        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let staged = try await source.stage(paths: [oldPath, newPath])
        let repositoryState = try await source.loadRepositoryState()
        let index = try required(RevisionCommitBuilder.artificialRevisions(headID: repositoryState.identity.headID).first(where: { $0.kind == .index }), "line rename: index revision exists")
        let details = try await source.loadRevisionDetails(for: index)
        let file = try required(details.files.first(where: { $0.path == newPath && $0.changeType == .renamed }), "line rename: staged rename is detected")
        let diff = try required(try await source.loadDiff(for: index, file: file), "line rename: staged rename patch loads")
        let deletion = try required(diff.lines.first(where: { $0.kind == .deletion && $0.text == "line 6" }), "line rename: original line is selectable")
        let addition = try required(diff.lines.first(where: { $0.kind == .addition && $0.text == "renamed replacement line 6" }), "line rename: replacement line is selectable")

        _ = try await source.applyLines(RepositoryLineSelection(
            file: file,
            diff: diff,
            lineIDs: [deletion.id, addition.id],
            direction: .unstage
        ))
        let nameStatus = try fixture.git(["diff", "--cached", "--name-status", "-M"], in: repository)
        try require(nameStatus.contains("R100\t\(oldPath)\t\(newPath)"), "line rename: partial unstage preserves the staged rename")
        try require(try fixture.git(["show", ":\(newPath)"], in: repository) == (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n", "line rename: selected replacement is removed from the renamed index entry")
        try require(try String(contentsOf: repository.appendingPathComponent(newPath), encoding: .utf8) == renamedLines.joined(separator: "\n") + "\n", "line rename: worktree content is not modified")
    }

    private static func testNormalCommit(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Normal commit repo")
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()

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
        try require(result.selectedCommitID == .object(ObjectID.parse(head)), "commit: refreshed selection follows the new HEAD")
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
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
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
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()

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
        try require(amended.selectedCommitID == .object(ObjectID.parse(fixture.git(["rev-parse", "HEAD"], in: repository).trimmed)), "amend: selection follows rewritten HEAD")

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

    private static func testCommitOptionsAndState(_ fixture: MutationGitFixture) async throws {
        let commandRequest = RepositoryCommitRequest(
            message: "Command builder",
            mode: .amend,
            stageAllBeforeCommit: false,
            allowEmpty: true,
            signOff: true,
            author: "Command Tester <command@example.com>",
            resetAuthor: true,
            noVerify: true,
            gpgSigning: .signSpecificKey("ABC123")
        )
        try require(
            GitCommitCommandBuilder.arguments(
                request: commandRequest,
                messageFile: "/tmp/commit message",
                hasStagedChanges: true
            ) == [
                "commit", "--amend", "--no-verify", "--signoff",
                "--author", "Command Tester <command@example.com>",
                "--gpg-sign=ABC123", "-F", "/tmp/commit message",
                "--allow-empty", "--reset-author"
            ],
            "commit command: upstream option ordering and separate message-file argument are preserved"
        )
        let messageOnlyRequest = RepositoryCommitRequest(
            message: "Message only",
            mode: .amendMessageOnly,
            stageAllBeforeCommit: false,
            allowEmpty: false,
            signOff: false,
            author: nil,
            resetAuthor: false,
            gpgSigning: .doNotSign
        )
        try require(
            GitCommitCommandBuilder.arguments(
                request: messageOnlyRequest,
                messageFile: "/tmp/message",
                hasStagedChanges: true
            ) == ["commit", "--amend", "--no-gpg-sign", "-F", "/tmp/message", "--only", "--allow-empty"],
            "commit command: message-only amend preserves the index and explicit no-sign state"
        )

        let repository = try fixture.clone(named: "Commit options repo")
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let before = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed

        _ = try await source.commit(RepositoryCommitRequest(
            message: "Empty commit",
            mode: .normal,
            stageAllBeforeCommit: false,
            allowEmpty: true,
            signOff: false,
            author: nil,
            resetAuthor: false
        ))
        try require(try fixture.git(["rev-parse", "HEAD^{tree}"], in: repository).trimmed == fixture.git(["rev-parse", "\(before)^{tree}"], in: repository).trimmed, "commit options: allow-empty preserves the tree")

        try fixture.write("stage all content\n", to: repository.appendingPathComponent("stage-all.txt"))
        _ = try await source.commit(RepositoryCommitRequest(
            message: "Stage all commit",
            mode: .normal,
            stageAllBeforeCommit: true,
            allowEmpty: false,
            signOff: false,
            author: nil,
            resetAuthor: false
        ))
        try require(try fixture.git(["show", "HEAD:stage-all.txt"], in: repository) == "stage all content\n", "commit options: Stage All records untracked content")

        _ = try await source.commit(RepositoryCommitRequest(
            message: "Other author's history message",
            mode: .normal,
            stageAllBeforeCommit: false,
            allowEmpty: true,
            signOff: false,
            author: "Another Author <another@example.com>",
            resetAuthor: false
        ))
        let allHistory = try await source.loadCommitState(historyLimit: 6, showOnlyMyMessages: false, rememberAmend: true)
        let ownHistory = try await source.loadCommitState(historyLimit: 6, showOnlyMyMessages: true, rememberAmend: true)
        try require(allHistory.previousMessages.contains { $0.contains("Other author's history message") }, "commit history: general history includes commits from another author")
        try require(!ownHistory.previousMessages.contains { $0.contains("Other author's history message") }, "commit history: author filtering excludes commits from another author")

        let templateURL = repository.appendingPathComponent("commit-template.txt")
        let templateBytes = Data([0x23, 0x20, 0x68, 0x65, 0x6c, 0x70, 0x0a, 0x63, 0x61, 0x66, 0xe9, 0x20, 0x74, 0x65, 0x6d, 0x70, 0x6c, 0x61, 0x74, 0x65, 0x0a, 0x62, 0x6f, 0x64, 0x79, 0x0a])
        try templateBytes.write(to: templateURL)
        try fixture.git(["config", "i18n.commitEncoding", "ISO-8859-1"], in: repository)
        try fixture.git(["config", "commit.template", templateURL.path], in: repository)
        let state = try await source.loadCommitState(historyLimit: 6, showOnlyMyMessages: true, rememberAmend: true)
        try require(state.commitEncoding.caseInsensitiveCompare("ISO-8859-1") == .orderedSame, "commit state: configured encoding loads")
        try require(state.message.contains("café template") && state.loadedTemplate == state.message, "commit state: configured template loads in commit encoding")
        try require(state.committer == "Mutation Fixture <mutation@example.com>" && !state.previousMessages.isEmpty, "commit state: committer and history load")

        _ = try await source.commit(RepositoryCommitRequest(
            message: state.message,
            mode: .normal,
            stageAllBeforeCommit: false,
            allowEmpty: true,
            signOff: false,
            author: nil,
            resetAuthor: false,
            messageEncoding: state.commitEncoding,
            usingTemplate: true,
            ensureSecondLineEmpty: true
        ))
        let raw = try fixture.git(["cat-file", "commit", "HEAD"], in: repository)
        try require(raw.contains("encoding ISO-8859-1"), "commit encoding: Git records the legacy encoding header")
        let decoded = try fixture.git(["log", "-1", "--encoding=UTF-8", "--format=%B"], in: repository)
        try require(decoded.hasPrefix("café template\n\nbody") && !decoded.contains("# help"), "commit template: comments are stripped and second line is inserted")

        try await source.saveCommitDraft(message: "draft café", amend: true, rememberAmend: true, encoding: "ISO-8859-1")
        let restored = try await source.loadCommitState(historyLimit: 2, showOnlyMyMessages: false, rememberAmend: true)
        try require(restored.message == "draft café" && restored.rememberedAmend, "commit draft: encoded message and amend state round-trip")
    }

    private static func testCommitHooksAndSigning(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Commit hooks repo")
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        try fixture.write("hook content\n", to: repository.appendingPathComponent("hook.txt"))
        _ = try await source.stage(paths: ["hook.txt"])
        let hookURL = repository.appendingPathComponent(".git/hooks/pre-commit")
        try fixture.write("#!/bin/sh\necho deterministic-hook-output\necho deterministic-hook-rejection >&2\nexit 37\n", to: hookURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)
        let before = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        do {
            _ = try await source.commit(RepositoryCommitRequest(
                message: "Hook must reject",
                mode: .normal,
                stageAllBeforeCommit: false,
                allowEmpty: false,
                signOff: false,
                author: nil,
                resetAuthor: false
            ))
            throw MutationFixtureError("hooks: rejecting pre-commit hook was ignored")
        } catch GitError.commandFailed(let arguments, let status, let stderr) {
            try require(
                arguments.contains("commit") && status == 1
                    && stderr.contains("deterministic-hook-output")
                    && stderr.contains("deterministic-hook-rejection"),
                "hooks: status, command, stdout, and stderr survive failure"
            )
        }
        try require(try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed == before, "hooks: failed commit preserves HEAD")
        try require(FileManager.default.fileExists(atPath: repository.appendingPathComponent(".git/COMMITMESSAGE").path), "hooks: failed commit preserves prepared message")

        _ = try await source.commit(RepositoryCommitRequest(
            message: "Bypass hook",
            mode: .normal,
            stageAllBeforeCommit: false,
            allowEmpty: false,
            signOff: false,
            author: nil,
            resetAuthor: false,
            noVerify: true
        ))
        try require(try fixture.git(["log", "-1", "--format=%s"], in: repository).trimmed == "Bypass hook", "hooks: --no-verify bypasses the native hook")
        try require(!FileManager.default.fileExists(atPath: repository.appendingPathComponent(".git/COMMITMESSAGE").path), "hooks: success clears prepared message")

        try FileManager.default.removeItem(at: hookURL)
        try fixture.git(["config", "commit.gpgSign", "true"], in: repository)
        try fixture.git(["config", "gpg.program", "/definitely/missing/gpg-program"], in: repository)
        _ = try await source.commit(RepositoryCommitRequest(
            message: "Explicitly unsigned",
            mode: .normal,
            stageAllBeforeCommit: false,
            allowEmpty: true,
            signOff: false,
            author: nil,
            resetAuthor: false,
            gpgSigning: .doNotSign
        ))
        do {
            _ = try await source.commit(RepositoryCommitRequest(
                message: "Signing fails visibly",
                mode: .normal,
                stageAllBeforeCommit: false,
                allowEmpty: true,
                signOff: false,
                author: nil,
                resetAuthor: false,
                gpgSigning: .signDefault
            ))
            throw MutationFixtureError("GPG: missing signing program unexpectedly succeeded")
        } catch GitError.commandFailed(let arguments, let status, let stderr) {
            try require(arguments.contains("--gpg-sign") && status != 0 && !stderr.isEmpty, "GPG: sign mode and failure status/stderr survive")
        }
    }

    private static func testCommitDetachedConflictAndReset(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Commit state edge repo")
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        try fixture.git(["checkout", "--detach", "HEAD"], in: repository)
        let detached = try await source.commit(RepositoryCommitRequest(
            message: "Detached empty commit",
            mode: .normal,
            stageAllBeforeCommit: false,
            allowEmpty: true,
            signOff: false,
            author: nil,
            resetAuthor: false
        ))
        let detachedState = try await source.loadMutationState()
        try require(detachedState.currentBranch == nil && detached.selectedCommitID != nil, "detached commit: typed backend commits and refreshes detached HEAD")

        _ = try await source.createBranch(named: "commit-edge")
        try require(try fixture.git(["branch", "--show-current"], in: repository).trimmed == "commit-edge", "create branch: visible Commit control checks out a valid branch")
        try fixture.write("staged reset\n", to: repository.appendingPathComponent("main.txt"))
        _ = try await source.stage(paths: ["main.txt"])
        try fixture.write("unstaged reset\n", to: repository.appendingPathComponent("shared.txt"))
        try fixture.write("delete me\n", to: repository.appendingPathComponent("untracked-reset.txt"))
        _ = try await source.resetChanges(RepositoryResetChangesRequest(scope: .worktree, deleteUntracked: false))
        try require(try String(contentsOf: repository.appendingPathComponent("shared.txt"), encoding: .utf8) == fixture.git(["show", "HEAD:shared.txt"], in: repository), "reset unstaged: tracked worktree content returns to index")
        try require(FileManager.default.fileExists(atPath: repository.appendingPathComponent("untracked-reset.txt").path), "reset unstaged: untracked file remains unless deletion chosen")
        _ = try await source.resetChanges(RepositoryResetChangesRequest(scope: .all, deleteUntracked: true))
        try require(try fixture.git(["diff", "--cached", "--name-only"], in: repository).trimmed.isEmpty, "reset all: index returns to HEAD")
        try require(!FileManager.default.fileExists(atPath: repository.appendingPathComponent("untracked-reset.txt").path), "reset all: confirmed clean removes untracked file")

        try fixture.write("soft reset payload\n", to: repository.appendingPathComponent("soft-reset.txt"))
        _ = try await source.stage(paths: ["soft-reset.txt"])
        _ = try await source.commit(RepositoryCommitRequest(
            message: "Commit to reset softly",
            mode: .normal,
            stageAllBeforeCommit: false,
            allowEmpty: false,
            signOff: false,
            author: nil,
            resetAuthor: false
        ))
        let beforeSoft = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        _ = try await source.resetSoftToParent()
        try require(try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed == fixture.git(["rev-parse", "\(beforeSoft)^"], in: repository).trimmed, "reset soft: HEAD moves to parent")
        try require(!(try fixture.git(["diff", "--cached", "--name-only"], in: repository).trimmed.isEmpty), "reset soft: removed commit tree remains staged")
    }

    private static func testCommitValidationFailuresAndConflict(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Commit validation failures repo")
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        try fixture.write("validation payload\n", to: repository.appendingPathComponent("validation.txt"))
        _ = try await source.stage(paths: ["validation.txt"])

        do {
            _ = try await source.commit(RepositoryCommitRequest(
                message: "Invalid author",
                mode: .normal,
                stageAllBeforeCommit: false,
                allowEmpty: false,
                signOff: false,
                author: "Missing email",
                resetAuthor: false
            ))
            throw MutationFixtureError("commit validation: invalid author was accepted")
        } catch RepositoryMutationError.invalidAuthor(let author) {
            try require(author == "Missing email", "commit validation: invalid author value survives")
        }
        do {
            _ = try await source.commit(RepositoryCommitRequest(
                message: "Invalid encoding",
                mode: .normal,
                stageAllBeforeCommit: false,
                allowEmpty: false,
                signOff: false,
                author: nil,
                resetAuthor: false,
                messageEncoding: "definitely-not-an-encoding"
            ))
            throw MutationFixtureError("commit validation: invalid encoding was accepted")
        } catch RepositoryMutationError.invalidCommitEncoding(let encoding) {
            try require(encoding == "definitely-not-an-encoding", "commit validation: invalid encoding value survives")
        }
        do {
            _ = try await source.commit(RepositoryCommitRequest(
                message: "Snowman ☃",
                mode: .normal,
                stageAllBeforeCommit: false,
                allowEmpty: false,
                signOff: false,
                author: nil,
                resetAuthor: false,
                messageEncoding: "US-ASCII"
            ))
            throw MutationFixtureError("commit validation: unrepresentable message was accepted")
        } catch RepositoryMutationError.commitMessageNotRepresentable(let encoding) {
            try require(encoding == "US-ASCII", "commit validation: unrepresentable encoding survives")
        }
        try fixture.git(["config", "commit.template", "missing-template.txt"], in: repository)
        let missingTemplateState = try await source.loadCommitState(historyLimit: 6, showOnlyMyMessages: false, rememberAmend: true)
        try require(
            missingTemplateState.message.isEmpty
                && missingTemplateState.messageLoadError?.contains("missing-template.txt") == true,
            "commit template: missing configured path is reported without disabling the workflow"
        )

        let conflictRepository = try fixture.clone(named: "Commit unresolved conflict repo")
        try fixture.git(["checkout", "-b", "conflict-side"], in: conflictRepository)
        try fixture.write("side\n", to: conflictRepository.appendingPathComponent("shared.txt"))
        try fixture.git(["add", "--all", "--"], in: conflictRepository)
        try fixture.git(["commit", "-m", "Conflict side"], in: conflictRepository)
        try fixture.git(["checkout", "main"], in: conflictRepository)
        try fixture.write("main conflict\n", to: conflictRepository.appendingPathComponent("shared.txt"))
        try fixture.git(["add", "--all", "--"], in: conflictRepository)
        try fixture.git(["commit", "-m", "Main conflict"], in: conflictRepository)
        let merge = try await GitProcess().run(arguments: ["merge", "conflict-side"], in: conflictRepository)
        try require(!merge.succeeded, "conflict fixture: merge creates an unresolved path")
        let conflictSource = GitRepositoryModule(repositoryURL: conflictRepository)
        _ = try await conflictSource.loadRepositoryState()
        do {
            _ = try await conflictSource.commit(RepositoryCommitRequest(
                message: "Must not commit conflict",
                mode: .normal,
                stageAllBeforeCommit: false,
                allowEmpty: true,
                signOff: false,
                author: nil,
                resetAuthor: false
            ))
            throw MutationFixtureError("conflicts: unresolved merge was committed")
        } catch RepositoryMutationError.unresolvedConflicts(let paths) {
            try require(paths == ["shared.txt"], "conflicts: unresolved path survives validation")
        }
    }

    private static func testCommitCancellation(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Commit cancellation repo")
        let runner = CancellableCommitGitRunner()
        let source = GitRepositoryModule(repositoryURL: repository, git: runner)
        _ = try await source.loadRepositoryState()
        try fixture.write("cancel payload\n", to: repository.appendingPathComponent("cancel.txt"))
        _ = try await source.stage(paths: ["cancel.txt"])
        let before = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        let task = Task {
            try await source.commit(RepositoryCommitRequest(
                message: "Cancelled commit",
                mode: .normal,
                stageAllBeforeCommit: false,
                allowEmpty: false,
                signOff: false,
                author: nil,
                resetAuthor: false
            ))
        }
        for _ in 0..<100 where !runner.didBeginCommit {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try require(runner.didBeginCommit, "cancellation: typed runner reached commit")
        task.cancel()
        do {
            _ = try await task.value
            throw MutationFixtureError("cancellation: cancelled commit completed")
        } catch is CancellationError {
            // Expected.
        }
        try require(try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed == before, "cancellation: HEAD is unchanged")
        try require(try fixture.git(["diff", "--cached", "--name-only"], in: repository).trimmed == "cancel.txt", "cancellation: index is preserved")
        try require(FileManager.default.fileExists(atPath: repository.appendingPathComponent(".git/COMMITMESSAGE").path), "cancellation: prepared message is preserved")
    }

    private static func testCommitAndPushIntegration(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Commit and push repo")
        let remote = fixture.rootURL.appendingPathComponent("Commit and push remote.git", isDirectory: true)
        try fixture.git(["init", "--bare", "--initial-branch=main", remote.path], in: fixture.rootURL)
        try fixture.git(["remote", "add", "publish", remote.path], in: repository)
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        try fixture.write("commit and push\n", to: repository.appendingPathComponent("commit-and-push.txt"))
        _ = try await source.stage(paths: ["commit-and-push.txt"])
        let committed = try await source.commit(RepositoryCommitRequest(
            message: "Commit and push integration",
            mode: .normal,
            stageAllBeforeCommit: false,
            allowEmpty: false,
            signOff: false,
            author: nil,
            resetAuthor: false
        ))
        let pushed = try await source.performPush(
            RepositoryPushRequest(
                destination: .remote("publish"),
                operation: .branch(source: "refs/heads/main", destination: "main"),
                setUpstream: true,
                recursiveSubmodules: .none
            ),
            output: { _ in }
        )
        let remoteHead = try fixture.git(["rev-parse", "refs/heads/main"], in: remote).trimmed
        try require(pushed.outcome == .completed && committed.selectedCommitID == .object(ObjectID.parse(remoteHead)), "commit and push: resulting remote ref is the committed HEAD")
        let state = try await source.loadPushState()
        let main = try required(state.localBranches.first(where: { $0.name == "main" }), "commit and push: main branch reloads")
        try require(main.trackingRemote == "publish" && main.ahead == 0 && main.behind == 0, "commit and push: upstream and ahead/behind state refresh")
    }

    private static func testStashCreationOptions(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Stash options repo")
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()

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
        let createdState = try await source.loadRepositoryState()
        try require(createdState.navigation.stashes.count == 1, "stash: create refreshes stash refs")
        try require(createdState.navigation.stashes[0].subject.contains("options fixture"), "stash: optional message is parsed into the stash model")
        try require(try fixture.git(["diff", "--cached", "--name-only"], in: repository).trimmed == "main.txt", "stash: keep-index retains staged changes")
        try require(try fixture.git(["show", "HEAD:shared.txt"], in: repository) == String(contentsOf: repository.appendingPathComponent("shared.txt"), encoding: .utf8), "stash: tracked unstaged content is restored")
        try require(!FileManager.default.fileExists(atPath: repository.appendingPathComponent("untracked stash.txt").path), "stash: include-untracked removes the saved untracked file")

        let stagedRepository = try fixture.clone(named: "Stash staged repo")
        let stagedSource = GitRepositoryModule(repositoryURL: stagedRepository)
        _ = try await stagedSource.loadRepositoryState()
        try fixture.write("staged only\n", to: stagedRepository.appendingPathComponent("main.txt"))
        _ = try await stagedSource.stage(paths: ["main.txt"])
        try fixture.write("unstaged remains\n", to: stagedRepository.appendingPathComponent("shared.txt"))
        let stagedResult = try await stagedSource.createStash(RepositoryStashCreateRequest(
            message: "",
            includeUntracked: false,
            keepIndex: false,
            stagedOnly: true
        ))
        let stagedState = try await stagedSource.loadRepositoryState()
        try require(stagedState.navigation.stashes.count == 1, "stash staged: creates a stash")
        try require(try fixture.git(["diff", "--cached", "--name-only"], in: stagedRepository).trimmed.isEmpty, "stash staged: removes saved index changes")
        try require(try String(contentsOf: stagedRepository.appendingPathComponent("shared.txt"), encoding: .utf8) == "unstaged remains\n", "stash staged: leaves unrelated unstaged changes")
    }

    private static func testStashLifecycle(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Stash lifecycle repo")
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()

        try fixture.write("older stash\n", to: repository.appendingPathComponent("shared.txt"))
        _ = try await source.createStash(RepositoryStashCreateRequest(message: "older", includeUntracked: false, keepIndex: false, stagedOnly: false))
        try fixture.write("latest stash\n", to: repository.appendingPathComponent("main.txt"))
        _ = try await source.createStash(RepositoryStashCreateRequest(message: "latest", includeUntracked: false, keepIndex: false, stagedOnly: false))
        var snapshot = try await source.loadRepositoryState()
        try require(snapshot.navigation.stashes.count == 2, "stash lifecycle: two stashes are newest-first")

        let older = snapshot.navigation.stashes[1]
        var result = try await source.applyStash(older)
        try require(try String(contentsOf: repository.appendingPathComponent("shared.txt"), encoding: .utf8) == "older stash\n", "stash apply: selected stash content is restored")
        snapshot = try await source.loadRepositoryState()
        try require(snapshot.navigation.stashes.count == 2, "stash apply: stash remains in the reflog")
        try fixture.git(["restore", "--staged", "--worktree", "--", "shared.txt"], in: repository)

        let latest = snapshot.navigation.stashes[0]
        result = try await source.popStash(latest)
        try require(try String(contentsOf: repository.appendingPathComponent("main.txt"), encoding: .utf8) == "latest stash\n", "stash pop: selected stash content is restored")
        snapshot = try await source.loadRepositoryState()
        try require(snapshot.navigation.stashes.count == 1 && snapshot.navigation.stashes[0].commitID == older.commitID, "stash pop: successful selected stash is removed")
        try fixture.git(["restore", "--staged", "--worktree", "--", "main.txt"], in: repository)

        result = try await source.dropStash(snapshot.navigation.stashes[0])
        snapshot = try await source.loadRepositoryState()
        try require(snapshot.navigation.stashes.isEmpty, "stash drop: selected stash is removed")
        try require(result.selectedCommitID == snapshot.identity.headID.map(RevisionID.object), "stash drop: empty stash list falls back to HEAD selection")
        do {
            _ = try await source.applyStash(older)
            throw MutationFixtureError("stash: a stale stash selector was accepted")
        } catch RepositoryMutationError.invalidStash(let selector) {
            try require(selector == older.selector, "stash: stale selection reports its original selector")
        }
    }

    private static func testStashSelectedPaths(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Selected path stash repo")
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()

        try fixture.write("selected main\n", to: repository.appendingPathComponent("main.txt"))
        try fixture.write("unselected shared\n", to: repository.appendingPathComponent("shared.txt"))
        let onePath = try await source.createStash(RepositoryStashCreateRequest(
            message: "one selected path",
            includeUntracked: false,
            keepIndex: false,
            stagedOnly: false,
            selectedPaths: ["main.txt"]
        ))
        let onePathState = try await source.loadRepositoryState()
        try require(onePathState.navigation.stashes.count == 1, "partial stash: selected tracked path creates one stash")
        try require(try String(contentsOf: repository.appendingPathComponent("main.txt"), encoding: .utf8) == "main\n", "partial stash: selected path is restored")
        try require(try String(contentsOf: repository.appendingPathComponent("shared.txt"), encoding: .utf8) == "unselected shared\n", "partial stash: unselected path remains dirty")
        let partialNames = try fixture.git(["stash", "show", "--name-only", "--format=", "stash@{0}"], in: repository)
            .split(separator: "\n").map(String.init)
        try require(partialNames == ["main.txt"], "partial stash: stash contains only the typed pathspec")

        try fixture.git(["restore", "--staged", "--worktree", "--", "shared.txt"], in: repository)
        let applied = try await source.applyStash(try required(onePathState.navigation.stashes.first, "partial stash: created stash is selectable"))
        try require(applied.outcome == .completed, "partial stash: selected-path stash applies normally")
        try require(try String(contentsOf: repository.appendingPathComponent("main.txt"), encoding: .utf8) == "selected main\n", "partial stash: apply restores selected content")

        let multipleRepository = try fixture.clone(named: "Multiple path stash repo")
        let multipleSource = GitRepositoryModule(repositoryURL: multipleRepository)
        _ = try await multipleSource.loadRepositoryState()
        try fixture.write("selected shared\n", to: multipleRepository.appendingPathComponent("shared.txt"))
        try fixture.write("selected untracked\n", to: multipleRepository.appendingPathComponent("selected untracked.txt"))
        try fixture.write("leave untracked\n", to: multipleRepository.appendingPathComponent("leave untracked.txt"))
        let multiple = try await multipleSource.createStash(RepositoryStashCreateRequest(
            message: "multiple selected paths",
            includeUntracked: true,
            keepIndex: false,
            stagedOnly: false,
            selectedPaths: ["selected untracked.txt", "shared.txt", "shared.txt"]
        ))
        let multipleState = try await multipleSource.loadRepositoryState()
        try require(multipleState.navigation.stashes.count == 1, "partial stash: multiple paths create one stash")
        try require(try String(contentsOf: multipleRepository.appendingPathComponent("shared.txt"), encoding: .utf8) == "base\n", "partial stash: selected tracked path is restored")
        try require(!FileManager.default.fileExists(atPath: multipleRepository.appendingPathComponent("selected untracked.txt").path), "partial stash: selected untracked path is cleaned")
        try require(FileManager.default.fileExists(atPath: multipleRepository.appendingPathComponent("leave untracked.txt").path), "partial stash: unselected untracked path remains")
        let multipleNames = Set(try fixture.git(["stash", "show", "--include-untracked", "--name-only", "--format=", "stash@{0}"], in: multipleRepository)
            .split(separator: "\n").map(String.init))
        try require(multipleNames == Set(["selected untracked.txt", "shared.txt"]), "partial stash: multiple typed pathspecs and untracked content are recorded")

        let stashModel = try required(multipleState.navigation.stashes.first, "stash details: created stash is modeled")
        let stashCommit = RevisionCommitBuilder.stashRevision(stashModel)
        let details = try await multipleSource.loadRevisionDetails(for: stashCommit)
        try require(Set(details.files.map(\.path)) == multipleNames, "stash details: shared browser loading includes the untracked third parent")
        let trackedFile = try required(details.files.first(where: { $0.path == "shared.txt" }), "stash details: selected tracked file is available")
        let diff = try required(
            try await multipleSource.loadDiff(for: stashCommit, file: trackedFile),
            "stash details: tracked file patch is available"
        )
        try require(diff.lines.contains { $0.text.contains("selected shared") }, "stash details: shared FileViewer receives the stash patch")
        let untrackedFile = try required(
            details.files.first(where: { $0.path == "selected untracked.txt" }),
            "stash details: selected untracked file is available"
        )
        let untrackedDiff = try required(
            try await multipleSource.loadDiff(for: stashCommit, file: untrackedFile),
            "stash details: untracked third-parent patch is available"
        )
        try require(
            untrackedDiff.lines.contains { $0.text.contains("selected untracked") },
            "stash details: shared FileViewer receives the untracked third-parent patch"
        )
    }

    private static func testStashConflict(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Stash conflict repo")
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        try fixture.write("stashed side\n", to: repository.appendingPathComponent("shared.txt"))
        var result = try await source.createStash(RepositoryStashCreateRequest(message: "conflict", includeUntracked: false, keepIndex: false, stagedOnly: false))
        var repositoryState = try await source.loadRepositoryState()
        let stash = try required(repositoryState.navigation.stashes.first, "stash conflict: stash exists")

        try fixture.write("current side\n", to: repository.appendingPathComponent("shared.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Conflicting current change"], in: repository)
        result = try await source.applyStash(stash)
        guard case .conflicts(let paths) = result.outcome else {
            throw MutationFixtureError("stash conflict: apply did not return a conflict outcome")
        }
        try require(paths == ["shared.txt"], "stash conflict: conflicted path is reported")
        repositoryState = try await source.loadRepositoryState()
        try require(repositoryState.navigation.stashes.contains { $0.commitID == stash.commitID }, "stash conflict: stash remains available")
        try require(try fixture.git(["diff", "--name-only", "--diff-filter=U"], in: repository).trimmed == "shared.txt", "stash conflict: repository retains Git's unmerged index state")
    }

    private static func testStashDropSelection(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Stash drop selection repo")
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        for (message, file) in [("oldest", "shared.txt"), ("middle", "main.txt"), ("newest", "hunks.txt")] {
            try fixture.write("\(message) stash\n", to: repository.appendingPathComponent(file))
            _ = try await source.createStash(RepositoryStashCreateRequest(
                message: message,
                includeUntracked: false,
                keepIndex: false,
                stagedOnly: false
            ))
        }
        var snapshot = try await source.loadRepositoryState()
        try require(snapshot.navigation.stashes.map(\.subject).allSatisfy { !$0.isEmpty }, "stash ordering: stash metadata is populated")
        try require(snapshot.navigation.stashes[0].subject.contains("newest") && snapshot.navigation.stashes[2].subject.contains("oldest"), "stash ordering: list is newest-first")

        let middle = snapshot.navigation.stashes[1]
        var dropped = try await source.dropStash(middle)
        snapshot = try await source.loadRepositoryState()
        try require(snapshot.navigation.stashes.count == 2, "stash drop selection: middle stash is removed")
        try require(dropped.selectedCommitID == .object(snapshot.navigation.stashes[1].commitID), "stash drop selection: the row now at the dropped index is selected")

        dropped = try await source.dropStash(snapshot.navigation.stashes[1])
        snapshot = try await source.loadRepositoryState()
        try require(snapshot.navigation.stashes.count == 1, "stash drop selection: last stash row is removed")
        try require(dropped.selectedCommitID == .object(snapshot.navigation.stashes[0].commitID), "stash drop selection: dropping the last row selects the previous row")
    }

    private static func testStashPopConflictPreservesStash(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Stash pop conflict repo")
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        try fixture.write("stashed pop side\n", to: repository.appendingPathComponent("shared.txt"))
        var result = try await source.createStash(RepositoryStashCreateRequest(
            message: "pop conflict",
            includeUntracked: false,
            keepIndex: false,
            stagedOnly: false
        ))
        var repositoryState = try await source.loadRepositoryState()
        let stash = try required(repositoryState.navigation.stashes.first, "stash pop conflict: stash exists")
        try fixture.write("current pop side\n", to: repository.appendingPathComponent("shared.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Conflicting pop change"], in: repository)

        result = try await source.popStash(stash)
        guard case .conflicts(let paths) = result.outcome else {
            throw MutationFixtureError("stash pop conflict: pop did not report Git's conflict")
        }
        try require(paths == ["shared.txt"], "stash pop conflict: conflicted path is reported")
        repositoryState = try await source.loadRepositoryState()
        try require(repositoryState.navigation.stashes.contains { $0.commitID == stash.commitID }, "stash pop conflict: failed pop preserves the stash")
        try require(try fixture.git(["rev-parse", "--verify", "refs/stash"], in: repository).trimmed == stash.commitID.string, "stash pop conflict: refs/stash remains the original stash")
        try require(try fixture.git(["diff", "--name-only", "--diff-filter=U"], in: repository).trimmed == "shared.txt", "stash pop conflict: Git's unmerged index/worktree state is preserved")
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

        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let beforeCount = Int(try fixture.git(["rev-list", "--count", "HEAD"], in: repository).trimmed) ?? 0
        let result = try await source.cherryPick(RepositoryCherryPickRequest(
            items: [
                RepositoryCherryPickItem(commitID: try ObjectID.parse(first), mainlineParent: nil),
                RepositoryCherryPickItem(commitID: try ObjectID.parse(second), mainlineParent: nil)
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
        try require(result.selectedCommitID == .object(ObjectID.parse(fixture.git(["rev-parse", "HEAD"], in: repository).trimmed)), "cherry-pick: successful selection follows HEAD")

        let noCommitRepository = try fixture.clone(named: "Cherry pick no commit repo")
        let noCommitSource = GitRepositoryModule(repositoryURL: noCommitRepository)
        _ = try await noCommitSource.loadRepositoryState()
        let headBefore = try fixture.git(["rev-parse", "HEAD"], in: noCommitRepository).trimmed
        let topic = try fixture.git(["rev-parse", "origin/topic"], in: noCommitRepository).trimmed
        let noCommit = try await noCommitSource.cherryPick(RepositoryCherryPickRequest(
            items: [RepositoryCherryPickItem(commitID: try ObjectID.parse(topic), mainlineParent: nil)],
            options: RepositoryCherryPickOptions(automaticallyCommit: false, addReference: false)
        ))
        try require(try fixture.git(["rev-parse", "HEAD"], in: noCommitRepository).trimmed == headBefore, "cherry-pick --no-commit: HEAD is unchanged")
        try require(!fixture.git(["diff", "--cached", "--name-only"], in: noCommitRepository).trimmed.isEmpty, "cherry-pick --no-commit: changes are staged")
        try require(noCommit.selectedCommitID == .index, "cherry-pick --no-commit: refreshed selection targets Commit index")
    }

    private static func testSingleCherryPickAndDetachedHead(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Single cherry pick repo")
        let topic = try fixture.git(["rev-parse", "origin/topic"], in: repository).trimmed
        let before = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let result = try await source.cherryPick(RepositoryCherryPickRequest(
            items: [RepositoryCherryPickItem(commitID: try ObjectID.parse(topic), mainlineParent: nil)],
            options: RepositoryCherryPickOptions(automaticallyCommit: true, addReference: false)
        ))
        let head = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try require(head != before, "single cherry-pick: HEAD advances")
        try require(try fixture.git(["log", "-1", "--format=%s"], in: repository).trimmed == "Topic change", "single cherry-pick: source subject is retained")
        let repositoryState = try await source.loadRepositoryState()
        try require(result.selectedCommitID == .object(ObjectID.parse(head)) && repositoryState.identity.headID == ObjectID.parse(head), "single cherry-pick: repository state and selection refresh to Git HEAD")
        let state = try await source.loadMutationState()
        try require(!state.cherryPickInProgress && state.conflictedPaths.isEmpty && !state.hasStagedChanges, "single cherry-pick: sequencer, index, and worktree are clean")

        let detachedRepository = try fixture.clone(named: "Detached cherry pick repo")
        let detachedTopic = try fixture.git(["rev-parse", "origin/topic"], in: detachedRepository).trimmed
        try fixture.git(["checkout", "--detach", "HEAD"], in: detachedRepository)
        let detachedSource = GitRepositoryModule(repositoryURL: detachedRepository)
        _ = try await detachedSource.loadRepositoryState()
        let detached = try await detachedSource.cherryPick(RepositoryCherryPickRequest(
            items: [RepositoryCherryPickItem(commitID: try ObjectID.parse(detachedTopic), mainlineParent: nil)],
            options: RepositoryCherryPickOptions(automaticallyCommit: true, addReference: false)
        ))
        let detachedHead = try fixture.git(["rev-parse", "HEAD"], in: detachedRepository).trimmed
        let detachedState = try await detachedSource.loadMutationState()
        try require(detachedState.currentBranch == nil, "detached cherry-pick: HEAD remains detached")
        try require(detached.selectedCommitID == .object(ObjectID.parse(detachedHead)), "detached cherry-pick: selection follows detached HEAD")
    }

    private static func testCherryPickSequentialOptionsAndPartialCancel(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Sequential dialog cherry pick repo")
        try fixture.git(["checkout", "-b", "sequential-source"], in: repository)
        try fixture.write("first dialog\n", to: repository.appendingPathComponent("dialog-first.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Dialog first"], in: repository)
        let first = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.write("second dialog\n", to: repository.appendingPathComponent("dialog-second.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Dialog second"], in: repository)
        let second = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "main"], in: repository)

        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let propagatedOptions = RepositoryCherryPickOptions(automaticallyCommit: true, addReference: true)
        _ = try await source.cherryPick(RepositoryCherryPickRequest(
            items: [RepositoryCherryPickItem(commitID: try ObjectID.parse(first), mainlineParent: nil)],
            options: propagatedOptions
        ))
        _ = try await source.cherryPick(RepositoryCherryPickRequest(
            items: [RepositoryCherryPickItem(commitID: try ObjectID.parse(second), mainlineParent: nil)],
            options: propagatedOptions
        ))
        let bodies = try fixture.git(["log", "-2", "--format=%b"], in: repository)
        try require(bodies.contains("cherry picked from commit \(first)") && bodies.contains("cherry picked from commit \(second)"), "sequential dialogs: propagated -x option is applied to each accepted form")
        let subjects = try fixture.git(["log", "-2", "--reverse", "--format=%s"], in: repository)
            .split(separator: "\n").map(String.init)
        try require(subjects == ["Dialog first", "Dialog second"], "sequential dialogs: individual backend requests retain oldest-to-newest order")

        let cancelledRepository = try fixture.clone(named: "Partial cancel cherry pick repo")
        try fixture.git(["checkout", "-b", "cancel-source"], in: cancelledRepository)
        try fixture.write("first cancelled sequence dialog\n", to: cancelledRepository.appendingPathComponent("dialog-first.txt"))
        try fixture.git(["add", "--all", "--"], in: cancelledRepository)
        try fixture.git(["commit", "-m", "Dialog first"], in: cancelledRepository)
        let cancelledFirst = try fixture.git(["rev-parse", "HEAD"], in: cancelledRepository).trimmed
        try fixture.write("second cancelled sequence dialog\n", to: cancelledRepository.appendingPathComponent("dialog-second.txt"))
        try fixture.git(["add", "--all", "--"], in: cancelledRepository)
        try fixture.git(["commit", "-m", "Dialog second"], in: cancelledRepository)
        try fixture.git(["checkout", "main"], in: cancelledRepository)
        let cancelledSource = GitRepositoryModule(repositoryURL: cancelledRepository)
        _ = try await cancelledSource.loadRepositoryState()
        let beforePartial = try fixture.git(["rev-parse", "HEAD"], in: cancelledRepository).trimmed
        let partial = try await cancelledSource.cherryPick(RepositoryCherryPickRequest(
            items: [RepositoryCherryPickItem(commitID: try ObjectID.parse(cancelledFirst), mainlineParent: nil)],
            options: RepositoryCherryPickOptions(automaticallyCommit: true, addReference: false)
        ))
        let partialHead = try fixture.git(["rev-parse", "HEAD"], in: cancelledRepository).trimmed
        try require(partial.selectedCommitID == .object(ObjectID.parse(partialHead)) && partialHead != beforePartial, "partial cancel: the accepted commit remains as the refreshed target HEAD")
        try require(FileManager.default.fileExists(atPath: cancelledRepository.appendingPathComponent("dialog-first.txt").path), "partial cancel: completed commit remains applied")
        try require(!FileManager.default.fileExists(atPath: cancelledRepository.appendingPathComponent("dialog-second.txt").path), "partial cancel: remaining commit is not applied")
        try require(try fixture.git(["log", "-1", "--format=%s"], in: cancelledRepository).trimmed == "Dialog first", "partial cancel: history stops after the last accepted form")
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
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()

        do {
            _ = try await source.cherryPick(RepositoryCherryPickRequest(
                items: [RepositoryCherryPickItem(commitID: try ObjectID.parse(merge), mainlineParent: nil)],
                options: RepositoryCherryPickOptions(automaticallyCommit: true, addReference: false)
            ))
            throw MutationFixtureError("cherry-pick: merge without a mainline was accepted")
        } catch RepositoryMutationError.invalidMainline(_, let parent, let count) {
            try require(parent == nil && count == 2, "cherry-pick: merge validation reports available parents")
        }

        do {
            _ = try await source.cherryPick(RepositoryCherryPickRequest(
                items: [RepositoryCherryPickItem(commitID: try ObjectID.parse(merge), mainlineParent: 3)],
                options: RepositoryCherryPickOptions(automaticallyCommit: true, addReference: false)
            ))
            throw MutationFixtureError("cherry-pick: invalid merge mainline was accepted")
        } catch RepositoryMutationError.invalidMainline(_, let parent, let count) {
            try require(parent == 3 && count == 2, "cherry-pick: out-of-range mainline reports the requested and available parents")
        }

        _ = try await source.cherryPick(RepositoryCherryPickRequest(
            items: [RepositoryCherryPickItem(commitID: try ObjectID.parse(merge), mainlineParent: 1)],
            options: RepositoryCherryPickOptions(automaticallyCommit: true, addReference: false)
        ))
        try require(FileManager.default.fileExists(atPath: repository.appendingPathComponent("merge-topic.txt").path), "cherry-pick: selected merge mainline applies the other-parent change")

        let secondParent = try fixture.git(["rev-parse", "\(merge)^2"], in: repository).trimmed
        try fixture.git(["checkout", "-B", "merge-target-parent-two", secondParent], in: repository)
        let parentTwoSource = GitRepositoryModule(repositoryURL: repository)
        _ = try await parentTwoSource.loadRepositoryState()
        _ = try await parentTwoSource.cherryPick(RepositoryCherryPickRequest(
            items: [RepositoryCherryPickItem(commitID: try ObjectID.parse(merge), mainlineParent: 2)],
            options: RepositoryCherryPickOptions(automaticallyCommit: true, addReference: false)
        ))
        try require(FileManager.default.fileExists(atPath: repository.appendingPathComponent("main-later.txt").path), "cherry-pick: second valid mainline applies the first-parent side")

        let nonMerge = try fixture.git(["rev-parse", "\(merge)^1"], in: repository).trimmed
        do {
            _ = try await parentTwoSource.cherryPick(RepositoryCherryPickRequest(
                items: [RepositoryCherryPickItem(commitID: try ObjectID.parse(nonMerge), mainlineParent: 1)],
                options: RepositoryCherryPickOptions(automaticallyCommit: true, addReference: false)
            ))
            throw MutationFixtureError("cherry-pick: non-merge accepted a mainline")
        } catch RepositoryMutationError.invalidMainline(_, let parent, let count) {
            try require(parent == 1 && count == 1, "cherry-pick: non-merge mainline validation is explicit")
        }
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

        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        var result = try await source.cherryPick(RepositoryCherryPickRequest(
            items: [
                RepositoryCherryPickItem(commitID: try ObjectID.parse(conflicting), mainlineParent: nil),
                RepositoryCherryPickItem(commitID: try ObjectID.parse(queued), mainlineParent: nil)
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

        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let conflicted = try await source.cherryPick(RepositoryCherryPickRequest(
            items: [RepositoryCherryPickItem(commitID: try ObjectID.parse(incoming), mainlineParent: nil)],
            options: RepositoryCherryPickOptions(automaticallyCommit: true, addReference: false)
        ))
        guard case .conflicts = conflicted.outcome else { throw MutationFixtureError("cherry-pick abort: conflict was not created") }
        let aborted = try await source.abortCherryPick()
        try require(try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed == before, "cherry-pick abort: original HEAD is restored")
        let abortedState = try await source.loadMutationState()
        try require(abortedState.conflictedPaths.isEmpty, "cherry-pick abort: conflict state is cleared")
        try require(aborted.selectedCommitID == .object(ObjectID.parse(before)), "cherry-pick abort: selection returns to HEAD")
        try require(try String(contentsOf: repository.appendingPathComponent("shared.txt"), encoding: .utf8) == "abort current\n", "cherry-pick abort: original worktree content is restored")
    }

    private static func testCherryPickNonConflictFailure(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Cherry pick failure repo")
        let topic = try fixture.git(["rev-parse", "origin/topic"], in: repository).trimmed
        let before = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.write("untracked local content\n", to: repository.appendingPathComponent("topic.txt"))

        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        do {
            _ = try await source.cherryPick(RepositoryCherryPickRequest(
                items: [RepositoryCherryPickItem(commitID: try ObjectID.parse(topic), mainlineParent: nil)],
                options: RepositoryCherryPickOptions(automaticallyCommit: true, addReference: false)
            ))
            throw MutationFixtureError("cherry-pick failure: rejecting hook unexpectedly succeeded")
        } catch GitError.commandFailed(let arguments, let status, let stderr) {
            try require(arguments == ["cherry-pick", topic], "cherry-pick failure: typed argument array survives")
            try require(
                status != 0
                    && stderr.contains("untracked working tree files would be overwritten")
                    && stderr.contains("topic.txt"),
                "cherry-pick failure: exit status and Git diagnostics survive"
            )
        }
        try require(try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed == before, "cherry-pick failure: HEAD does not advance")
        try require(
            try String(contentsOf: repository.appendingPathComponent("topic.txt"), encoding: .utf8) == "untracked local content\n",
            "cherry-pick failure: rejected operation preserves the untracked file"
        )
        let state = try await source.loadMutationState()
        if state.cherryPickInProgress {
            _ = try await source.abortCherryPick()
        }
    }

    private static func testMergeCommandConstruction() throws {
        let request = RepositoryMergeRequest(
            targets: ["topic", "release-tag"],
            allowFastForward: false,
            noCommit: true,
            strategy: "ours",
            allowUnrelatedHistories: true,
            message: "Merge topic",
            logCount: 20
        )
        let arguments = try GitMergeCommandBuilder.arguments(
            for: request,
            messageFile: "/tmp/MERGE_MSG"
        )
        try require(arguments == [
            "merge",
            "--no-ff",
            "--strategy=ours",
            "--no-commit",
            "--allow-unrelated-histories",
            "-F", "/tmp/MERGE_MSG",
            "--log=20",
            "--no-edit",
            "topic", "release-tag"
        ], "merge command: argument order matches Git Extensions")

        do {
            _ = try GitMergeCommandBuilder.arguments(
                for: RepositoryMergeRequest(targets: [" "]),
                messageFile: nil
            )
            throw MutationFixtureError("merge command: an empty target was accepted")
        } catch RepositoryMergeError.missingTarget {
            // Expected.
        }
    }

    private static func testMergeFastForwardAndAlreadyUpToDate(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Merge fast-forward repo")
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let topic = try fixture.git(["rev-parse", "origin/topic"], in: repository).trimmed
        let result = try await source.performMerge(
            RepositoryMergeRequest(targets: ["origin/topic"]),
            output: { _ in }
        )
        let head = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try require(result.outcome == .completed, "merge fast-forward: operation completes")
        try require(head == topic, "merge fast-forward: HEAD advances directly to the target")
        try require(try fixture.git(["rev-list", "--parents", "-n", "1", "HEAD"], in: repository).split(separator: " ").count == 2, "merge fast-forward: no merge commit is created")
        let repositoryState = try await source.loadRepositoryState()
        try require(result.selectedCommitID == .object(ObjectID.parse(head)) && repositoryState.identity.headID == ObjectID.parse(head), "merge fast-forward: repository state and selection follow HEAD")

        let second = try await source.performMerge(
            RepositoryMergeRequest(targets: ["origin/topic"]),
            output: { _ in }
        )
        try require(second.outcome == .alreadyUpToDate, "merge: repeated target reports already up to date")
        try require(try fixture.git(["status", "--porcelain"], in: repository).trimmed.isEmpty, "merge already-up-to-date: index and worktree stay clean")
    }

    private static func testMergeCommitOptions(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Merge commit options repo")
        try fixture.write("main side\n", to: repository.appendingPathComponent("main-side.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Main side"], in: repository)
        let before = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        let topic = try fixture.git(["rev-parse", "origin/topic"], in: repository).trimmed
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let result = try await source.performMerge(
            RepositoryMergeRequest(
                targets: ["origin/topic"],
                allowFastForward: false,
                message: "Merge the topic\n\nTyped merge body",
                logCount: 1
            ),
            output: { _ in }
        )
        try require(result.outcome == .completed, "merge commit: diverged histories complete")
        let parents = try fixture.git(["show", "-s", "--format=%P", "HEAD"], in: repository).trimmed.split(separator: " ").map(String.init)
        try require(
            parents == [before, topic],
            "merge commit: expected parents \([before, topic]), received \(parents)"
        )
        try require(try fixture.git(["log", "-1", "--format=%s"], in: repository).trimmed == "Merge the topic", "merge message: custom subject is used")
        try require(try fixture.git(["log", "-1", "--format=%b"], in: repository).contains("Typed merge body"), "merge message: custom body is preserved")
        let state = try await source.loadMutationState()
        try require(!state.mergeInProgress && state.conflictedPaths.isEmpty && !state.hasStagedChanges, "merge commit: merge state, index, and worktree are clean")

        let noFFRepository = try fixture.clone(named: "Merge no-ff fast-forward repo")
        let noFFSource = GitRepositoryModule(repositoryURL: noFFRepository)
        _ = try await noFFSource.loadRepositoryState()
        _ = try await noFFSource.performMerge(
            RepositoryMergeRequest(targets: ["origin/topic"], allowFastForward: false),
            output: { _ in }
        )
        let noFFParents = try fixture.git(["show", "-s", "--format=%P", "HEAD"], in: noFFRepository).split(separator: " ")
        try require(noFFParents.count == 2, "merge --no-ff: a merge commit is created even when fast-forward was possible")
    }

    private static func testMergeSquashAndNoCommit(_ fixture: MutationGitFixture) async throws {
        let squashRepository = try fixture.clone(named: "Merge squash repo")
        let squashHead = try fixture.git(["rev-parse", "HEAD"], in: squashRepository).trimmed
        let squashSource = GitRepositoryModule(repositoryURL: squashRepository)
        _ = try await squashSource.loadRepositoryState()
        let squashed = try await squashSource.performMerge(
            RepositoryMergeRequest(targets: ["origin/topic"], squash: true),
            output: { _ in }
        )
        try require(squashed.outcome == .completed, "merge --squash: operation completes")
        try require(try fixture.git(["rev-parse", "HEAD"], in: squashRepository).trimmed == squashHead, "merge --squash: HEAD does not move")
        try require(Set(try fixture.git(["diff", "--cached", "--name-only"], in: squashRepository).split(separator: "\n").map(String.init)).isSuperset(of: ["shared.txt", "topic.txt"]), "merge --squash: target changes are staged")
        try require(!FileManager.default.fileExists(atPath: squashRepository.appendingPathComponent(".git/MERGE_HEAD").path), "merge --squash: no merge state is left")

        let noCommitRepository = try fixture.clone(named: "Merge no-commit repo")
        try fixture.write("main divergence\n", to: noCommitRepository.appendingPathComponent("main-divergence.txt"))
        try fixture.git(["add", "--all", "--"], in: noCommitRepository)
        try fixture.git(["commit", "-m", "Main divergence"], in: noCommitRepository)
        let noCommitHead = try fixture.git(["rev-parse", "HEAD"], in: noCommitRepository).trimmed
        let noCommitSource = GitRepositoryModule(repositoryURL: noCommitRepository)
        _ = try await noCommitSource.loadRepositoryState()
        let pending = try await noCommitSource.performMerge(
            RepositoryMergeRequest(targets: ["origin/topic"], noCommit: true),
            output: { _ in }
        )
        try require(pending.outcome == .readyToCommit, "merge --no-commit: successful real merge is reported ready to commit")
        try require(try fixture.git(["rev-parse", "HEAD"], in: noCommitRepository).trimmed == noCommitHead, "merge --no-commit: HEAD stays at the pre-merge commit")
        try require(FileManager.default.fileExists(atPath: noCommitRepository.appendingPathComponent(".git/MERGE_HEAD").path), "merge --no-commit: MERGE_HEAD is retained")
        try require(!fixture.git(["diff", "--cached", "--name-only"], in: noCommitRepository).trimmed.isEmpty, "merge --no-commit: merged changes remain staged")
        let aborted = try await noCommitSource.abortMerge()
        try require(aborted.outcome == .completed, "merge --no-commit: shared Abort succeeds")
        try require(try fixture.git(["rev-parse", "HEAD"], in: noCommitRepository).trimmed == noCommitHead, "merge --no-commit Abort: original HEAD is retained")
        try require(try fixture.git(["status", "--porcelain"], in: noCommitRepository).trimmed.isEmpty, "merge --no-commit Abort: index and worktree are restored")
    }

    private static func testMergeAdvancedTargets(_ fixture: MutationGitFixture) async throws {
        let strategyRepository = try fixture.clone(named: "Merge ours strategy repo")
        try fixture.write("ours\n", to: strategyRepository.appendingPathComponent("ours.txt"))
        try fixture.git(["add", "--all", "--"], in: strategyRepository)
        try fixture.git(["commit", "-m", "Ours side"], in: strategyRepository)
        let strategySource = GitRepositoryModule(repositoryURL: strategyRepository)
        _ = try await strategySource.loadRepositoryState()
        let ours = try await strategySource.performMerge(
            RepositoryMergeRequest(targets: ["origin/topic"], strategy: "ours"),
            output: { _ in }
        )
        try require(ours.outcome == .completed, "merge strategy: ours completes")
        try require(try fixture.git(["show", "-s", "--format=%P", "HEAD"], in: strategyRepository).split(separator: " ").count == 2, "merge strategy: ours still records both parents")
        try require(!FileManager.default.fileExists(atPath: strategyRepository.appendingPathComponent("topic.txt").path), "merge strategy: ours retains the current tree")

        let octopusRepository = try fixture.clone(named: "Merge multiple target repo")
        try fixture.git(["checkout", "-b", "octopus-a"], in: octopusRepository)
        try fixture.write("a\n", to: octopusRepository.appendingPathComponent("octopus-a.txt"))
        try fixture.git(["add", "--all", "--"], in: octopusRepository)
        try fixture.git(["commit", "-m", "Octopus A"], in: octopusRepository)
        let octopusA = try fixture.git(["rev-parse", "HEAD"], in: octopusRepository).trimmed
        try fixture.git(["checkout", "main"], in: octopusRepository)
        try fixture.git(["checkout", "-b", "octopus-b"], in: octopusRepository)
        try fixture.write("b\n", to: octopusRepository.appendingPathComponent("octopus-b.txt"))
        try fixture.git(["add", "--all", "--"], in: octopusRepository)
        try fixture.git(["commit", "-m", "Octopus B"], in: octopusRepository)
        let octopusB = try fixture.git(["rev-parse", "HEAD"], in: octopusRepository).trimmed
        try fixture.git(["checkout", "main"], in: octopusRepository)
        let octopusSource = GitRepositoryModule(repositoryURL: octopusRepository)
        _ = try await octopusSource.loadRepositoryState()
        let octopus = try await octopusSource.performMerge(
            RepositoryMergeRequest(targets: ["octopus-a", "octopus-b"]),
            output: { _ in }
        )
        try require(octopus.outcome == .completed, "merge multiple targets: octopus merge completes")
        let octopusParents = try fixture.git(["show", "-s", "--format=%P", "HEAD"], in: octopusRepository).trimmed.split(separator: " ").map(String.init)
        try require(Set(octopusParents) == Set([octopusA, octopusB]), "merge multiple targets: Git records both non-redundant selected parents")
        try require(FileManager.default.fileExists(atPath: octopusRepository.appendingPathComponent("octopus-a.txt").path) && FileManager.default.fileExists(atPath: octopusRepository.appendingPathComponent("octopus-b.txt").path), "merge multiple targets: both target trees are present")

        let unrelatedRepository = try fixture.clone(named: "Merge unrelated histories repo")
        try fixture.git(["checkout", "--orphan", "unrelated"], in: unrelatedRepository)
        try fixture.git(["rm", "-rf", "--", "."], in: unrelatedRepository)
        try fixture.write("unrelated\n", to: unrelatedRepository.appendingPathComponent("unrelated.txt"))
        try fixture.git(["add", "--all", "--"], in: unrelatedRepository)
        try fixture.git(["commit", "-m", "Unrelated root"], in: unrelatedRepository)
        try fixture.git(["checkout", "main"], in: unrelatedRepository)
        let unrelatedSource = GitRepositoryModule(repositoryURL: unrelatedRepository)
        _ = try await unrelatedSource.loadRepositoryState()
        let rejected = try await unrelatedSource.performMerge(
            RepositoryMergeRequest(targets: ["unrelated"]),
            output: { _ in }
        )
        try require(rejected.outcome == .failed && rejected.command.exitStatus != 0, "merge unrelated histories: Git rejects the target without the exposed option")
        let accepted = try await unrelatedSource.performMerge(
            RepositoryMergeRequest(targets: ["unrelated"], allowUnrelatedHistories: true),
            output: { _ in }
        )
        try require(accepted.outcome == .completed, "merge unrelated histories: exposed option permits the merge")
        try require(FileManager.default.fileExists(atPath: unrelatedRepository.appendingPathComponent("unrelated.txt").path), "merge unrelated histories: unrelated tree is merged")
    }

    private static func testMergeValidationAndDiagnostics(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Merge diagnostics repo")
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let before = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        let invalid = try await source.performMerge(
            RepositoryMergeRequest(targets: ["missing/revision"]),
            output: { _ in }
        )
        try require(invalid.outcome == .failed, "merge invalid revision: failure is typed")
        try require(invalid.command.exitStatus != 0 && !invalid.command.standardErrorString.trimmed.isEmpty, "merge invalid revision: exit status and stderr are preserved")
        try require(try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed == before, "merge invalid revision: HEAD is unchanged")

        try fixture.write("dirty current worktree\n", to: repository.appendingPathComponent("shared.txt"))
        let dirty = try await source.performMerge(
            RepositoryMergeRequest(targets: ["origin/topic"]),
            output: { _ in }
        )
        try require(dirty.outcome == .failed && dirty.command.exitStatus != 0, "merge dirty worktree: overlapping changes are rejected by Git")
        try require(try String(contentsOf: repository.appendingPathComponent("shared.txt"), encoding: .utf8) == "dirty current worktree\n", "merge dirty worktree: local content is preserved")
        try require(!dirty.message.trimmed.isEmpty, "merge dirty worktree: useful diagnostics survive")

        let detachedRepository = try fixture.clone(named: "Merge detached HEAD repo")
        try fixture.git(["checkout", "--detach", "HEAD"], in: detachedRepository)
        let detachedSource = GitRepositoryModule(repositoryURL: detachedRepository)
        _ = try await detachedSource.loadRepositoryState()
        let detached = try await detachedSource.performMerge(
            RepositoryMergeRequest(targets: ["origin/topic"]),
            output: { _ in }
        )
        let detachedState = try await detachedSource.loadMutationState()
        try require(detached.outcome == .completed && detachedState.currentBranch == nil, "merge detached HEAD: Git permits the merge and HEAD remains detached")
    }

    private static func testMergeConflictContinue(_ fixture: MutationGitFixture) async throws {
        let setup = try makeMergeConflictRepository(fixture, name: "Merge conflict continue repo")
        let source = GitRepositoryModule(repositoryURL: setup.repository)
        _ = try await source.loadRepositoryState()
        let conflicted = try await source.performMerge(
            RepositoryMergeRequest(targets: [setup.target]),
            output: { _ in }
        )
        guard case .conflicts(let paths) = conflicted.outcome else {
            throw MutationFixtureError("merge conflict continue: conflict was not reported")
        }
        try require(paths == ["shared.txt"], "merge conflict continue: exact unresolved path is retained")
        let state = try await source.loadMutationState()
        try require(state.mergeInProgress && state.conflictedPaths == ["shared.txt"], "merge conflict continue: MERGE_HEAD and index conflict state are visible")

        do {
            _ = try await source.performMerge(
                RepositoryMergeRequest(targets: [setup.target]),
                output: { _ in }
            )
            throw MutationFixtureError("merge conflict continue: a second merge began over unresolved paths")
        } catch RepositoryMergeError.unresolvedConflicts(let existing) {
            try require(existing == ["shared.txt"], "merge conflict continue: validation reports the existing unresolved path")
        }

        try fixture.write("resolved merge\n", to: setup.repository.appendingPathComponent("shared.txt"))
        _ = try await source.stage(paths: ["shared.txt"])
        let resolvedState = try await source.loadMutationState()
        try require(resolvedState.mergeInProgress && resolvedState.conflictedPaths.isEmpty, "merge conflict continue: staging clears conflicts while retaining merge state")
        let committed = try await source.commit(RepositoryCommitRequest(
            message: "Resolve merge",
            mode: .normal,
            stageAllBeforeCommit: false,
            allowEmpty: false,
            signOff: false,
            author: nil,
            resetAuthor: false
        ))
        try require(committed.outcome == .completed, "merge conflict continue: shared Commit workflow completes the merge")
        let parents = try fixture.git(["show", "-s", "--format=%P", "HEAD"], in: setup.repository).trimmed.split(separator: " ").map(String.init)
        try require(parents == [setup.originalHead, setup.target], "merge conflict continue: committed merge records both expected parents")
        let finalState = try await source.loadMutationState()
        try require(!finalState.mergeInProgress && finalState.conflictedPaths.isEmpty && !finalState.hasStagedChanges, "merge conflict continue: merge files, index, and worktree finish cleanly")
    }

    private static func testMergeConflictAbort(_ fixture: MutationGitFixture) async throws {
        let setup = try makeMergeConflictRepository(fixture, name: "Merge conflict abort repo")
        let originalContent = try String(contentsOf: setup.repository.appendingPathComponent("shared.txt"), encoding: .utf8)
        let source = GitRepositoryModule(repositoryURL: setup.repository)
        _ = try await source.loadRepositoryState()
        let conflicted = try await source.performMerge(
            RepositoryMergeRequest(targets: [setup.target]),
            output: { _ in }
        )
        guard case .conflicts = conflicted.outcome else {
            throw MutationFixtureError("merge conflict abort: conflict was not created")
        }
        let aborted = try await source.abortMerge()
        try require(aborted.outcome == .completed, "merge conflict abort: shared Abort completes")
        try require(try fixture.git(["rev-parse", "HEAD"], in: setup.repository).trimmed == setup.originalHead, "merge conflict abort: original HEAD is restored")
        try require(try String(contentsOf: setup.repository.appendingPathComponent("shared.txt"), encoding: .utf8) == originalContent, "merge conflict abort: original worktree is restored")
        try require(try fixture.git(["status", "--porcelain"], in: setup.repository).trimmed.isEmpty, "merge conflict abort: index and worktree are clean")
        let state = try await source.loadMutationState()
        try require(!state.mergeInProgress && state.conflictedPaths.isEmpty, "merge conflict abort: merge state files and unmerged entries are removed")
    }

    private static func testMergeCancellation(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Merge cancellation repo")
        let before = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        let runner = CancellableMergeGitRunner()
        let source = GitRepositoryModule(repositoryURL: repository, git: runner)
        _ = try await source.loadRepositoryState()
        let task = Task {
            try await source.performMerge(
                RepositoryMergeRequest(targets: ["origin/topic"]),
                output: { _ in }
            )
        }
        for _ in 0..<100 where !runner.didBeginMerge {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try require(runner.didBeginMerge, "merge cancellation: typed runner reached merge")
        task.cancel()
        do {
            _ = try await task.value
            throw MutationFixtureError("merge cancellation: cancelled operation completed")
        } catch is CancellationError {
            // Expected.
        }
        try require(try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed == before, "merge cancellation: HEAD is unchanged")
        try require(try fixture.git(["status", "--porcelain"], in: repository).trimmed.isEmpty, "merge cancellation: index and worktree are unchanged")
    }

    private static func makeMergeConflictRepository(
        _ fixture: MutationGitFixture,
        name: String
    ) throws -> (repository: URL, target: String, originalHead: String) {
        let repository = try fixture.clone(named: name)
        try fixture.git(["checkout", "-b", "merge-conflict-topic"], in: repository)
        try fixture.write("incoming merge conflict\n", to: repository.appendingPathComponent("shared.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Incoming merge conflict"], in: repository)
        let target = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "main"], in: repository)
        try fixture.write("current merge conflict\n", to: repository.appendingPathComponent("shared.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Current merge conflict"], in: repository)
        let originalHead = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        return (repository, target, originalHead)
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

        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
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
        try require(result.selectedCommitID == .object(ObjectID.parse(newFeature)), "rebase: selection follows rewritten HEAD")
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

        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
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

    private static func testAlreadyUpToDateRebase(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Up-to-date rebase repo")
        let head = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let result = try await source.rebase(RepositoryRebaseRequest(upstream: head, autoStash: false))
        try require(result.outcome == .completed, "up-to-date rebase: operation completes")
        try require(result.message == "Current branch is up to date. Nothing to rebase.", "up-to-date rebase: upstream completion message is preserved")
        try require(try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed == head, "up-to-date rebase: HEAD is unchanged")
    }

    private static func testInteractiveRebaseEdit(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Interactive edit repo")
        try fixture.git(["checkout", "-b", "edit-feature"], in: repository)
        try fixture.write("edit me\n", to: repository.appendingPathComponent("edit.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Edit stop"], in: repository)
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
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
        let progress = try await source.loadRebaseState()
        try require(progress.inProgress && progress.canEditTodo, "interactive edit: live todo state is available")
        try require(progress.patches.contains(where: { $0.status == .applying && $0.revisionToken == item.commitID.string }), "interactive edit: stopped revision is marked as applying")
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
        let source = GitRepositoryModule(repositoryURL: setup.repository)
        _ = try await source.loadRepositoryState()
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

    private static func testRebaseConflictMergeTool(_ fixture: MutationGitFixture) async throws {
        let setup = try makeRebaseConflictRepository(fixture, name: "Rebase merge tool repo")
        try fixture.git(["config", "merge.tool", "fixture"], in: setup.repository)
        try fixture.git([
            "config", "mergetool.fixture.cmd",
            "printf 'resolved by merge tool\\n' > \"$MERGED\""
        ], in: setup.repository)
        try fixture.git(["config", "mergetool.fixture.trustExitCode", "true"], in: setup.repository)
        let source = GitRepositoryModule(repositoryURL: setup.repository)
        _ = try await source.loadRepositoryState()

        let configuration = try await source.loadMergeToolConfiguration()
        try require(configuration == RepositoryMergeToolConfiguration(name: "fixture", usesGUISetting: false), "rebase mergetool: effective merge.tool is discovered")
        let conflicted = try await source.rebase(RepositoryRebaseRequest(upstream: setup.target, autoStash: false))
        guard case .conflicts(let paths) = conflicted.outcome else { throw MutationFixtureError("rebase mergetool: conflict was not reported") }

        let resolved = try await source.runMergeTool(paths: paths)
        try require(resolved.outcome == .completed, "rebase mergetool: successful tool clears conflict state")
        try require(try String(contentsOf: setup.repository.appendingPathComponent("shared.txt"), encoding: .utf8) == "resolved by merge tool\n", "rebase mergetool: configured tool updates the merged file")
        try require(try fixture.git(["diff", "--cached", "--name-only"], in: setup.repository).trimmed == "shared.txt", "rebase mergetool: trusted tool stages the resolved file")

        let completed = try await source.continueRebase()
        try require(completed.outcome == .completed, "rebase mergetool: resolved rebase continues")
    }

    private static func testRebaseAdvancedOptions(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Advanced rebase repo")
        let base = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "-b", "advanced-feature"], in: repository)
        try fixture.write("one\n", to: repository.appendingPathComponent("advanced-one.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Advanced one"], in: repository)
        let first = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["branch", "dependent", first], in: repository)
        try fixture.write("two\n", to: repository.appendingPathComponent("advanced-two.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Advanced two"], in: repository)
        try fixture.git(["checkout", "main"], in: repository)
        try fixture.write("target\n", to: repository.appendingPathComponent("advanced-target.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Advanced target"], in: repository)
        let target = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "advanced-feature"], in: repository)
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let result = try await source.rebase(RepositoryRebaseRequest(
            upstream: target,
            autoStash: false,
            updateRefs: true,
            onto: target,
            from: base,
            branch: "advanced-feature"
        ))
        try require(result.outcome == .completed, "advanced rebase: onto range completes")
        try require(try fixture.git(["merge-base", "--is-ancestor", target, "HEAD"], in: repository).trimmed.isEmpty, "advanced rebase: target is an ancestor")
        let updatedDependent = try fixture.git(["rev-parse", "dependent"], in: repository).trimmed
        try require(updatedDependent != first, "advanced rebase: update-refs rewrites dependent branch")
    }

    private static func testInteractiveAutosquash(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Autosquash rebase repo")
        let base = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "-b", "autosquash-feature"], in: repository)
        try fixture.write("feature\n", to: repository.appendingPathComponent("autosquash.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Autosquash target"], in: repository)
        try fixture.write("feature fixed\n", to: repository.appendingPathComponent("autosquash.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "fixup! Autosquash target"], in: repository)
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let plan = try await source.loadInteractiveRebasePlan(upstream: base)
        let result = try await source.interactiveRebase(RepositoryInteractiveRebaseRequest(
            upstream: base,
            items: plan,
            autoStash: false,
            autoSquash: true
        ))
        try require(result.outcome == .completed, "autosquash rebase: operation completes")
        let count = try fixture.git(["rev-list", "--count", "\(base)..HEAD"], in: repository).trimmed
        try require(count == "1", "autosquash rebase: fixup is folded into its target")
        try require(try String(contentsOf: repository.appendingPathComponent("autosquash.txt"), encoding: .utf8) == "feature fixed\n", "autosquash rebase: fixup tree is retained")
    }

    private static func testDetachedHeadAndInvalidRebase(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Detached rebase repo")
        try fixture.git(["checkout", "-b", "detached-feature"], in: repository)
        try fixture.write("detached\n", to: repository.appendingPathComponent("detached-rebase.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Detached feature"], in: repository)
        let feature = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "main"], in: repository)
        try fixture.write("target\n", to: repository.appendingPathComponent("detached-target.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Detached target"], in: repository)
        let target = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "--detach", feature], in: repository)
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        do {
            _ = try await source.rebase(RepositoryRebaseRequest(upstream: "missing/rebase-ref", autoStash: false))
            throw MutationFixtureError("invalid rebase: missing revision was accepted")
        } catch RepositoryMutationError.invalidRevision(let revision) {
            try require(revision == "missing/rebase-ref", "invalid rebase: invalid ref is preserved in the error")
        }
        let result = try await source.rebase(RepositoryRebaseRequest(upstream: target, autoStash: false))
        try require(result.outcome == .completed, "detached rebase: operation completes")
        let state = try await source.loadMutationState()
        try require(state.currentBranch == nil, "detached rebase: HEAD remains detached")
        try require(try fixture.git(["merge-base", "--is-ancestor", target, "HEAD"], in: repository).trimmed.isEmpty, "detached rebase: target is an ancestor")
    }

    private static func testNativeInteractiveTodo(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Native interactive todo repo")
        let base = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "-b", "native-todo-feature"], in: repository)
        for name in ["Native A", "Native B", "Native C"] {
            try fixture.write("\(name)\n", to: repository.appendingPathComponent("\(name.replacingOccurrences(of: " ", with: "-")).txt"))
            try fixture.git(["add", "--all", "--"], in: repository)
            try fixture.git(["commit", "-m", name], in: repository)
        }
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let options = RepositoryInteractiveRebaseTodoRequest(
            upstream: base,
            autoStash: false,
            autoSquash: false,
            rebaseMerges: false,
            updateRefs: nil,
            onto: nil,
            from: nil,
            branch: nil
        )
        let todo = try await source.loadNativeInteractiveRebaseTodo(options)
        var actionable = todo.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter {
            $0.hasPrefix("pick ")
        }
        try require(actionable.count == 3, "native todo: Git-generated todo contains every commit")
        actionable.reverse()
        actionable[1] = actionable[1].replacingOccurrences(of: "pick ", with: "drop ", options: .anchored)
        let lastFields = actionable[2].split(maxSplits: 2, whereSeparator: \.isWhitespace)
        actionable[2] = "reword \(lastFields[1]) Native A rewritten"
        let nativeTodo = actionable.joined(separator: "\n") + "\n"
        let result = try await source.interactiveRebase(RepositoryInteractiveRebaseRequest(
            upstream: base,
            items: [],
            autoStash: false,
            nativeTodo: nativeTodo
        ))
        try require(result.outcome == .completed, "native todo: reordered/reword/drop sequence completes")
        let subjects = try fixture.git(["log", "--reverse", "--format=%s", "\(base)..HEAD"], in: repository)
            .split(separator: "\n").map(String.init)
        try require(subjects == ["Native C", "Native A rewritten"], "native todo: resulting history follows edited native todo")
    }

    private static func testNativeInteractiveRebaseMerges(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Native rebase merges repo")
        try fixture.git(["checkout", "-b", "native-merge-feature"], in: repository)
        try fixture.write("feature\n", to: repository.appendingPathComponent("native-merge-feature.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Native merge feature"], in: repository)
        let featureBase = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "-b", "native-merge-side", featureBase], in: repository)
        try fixture.write("side\n", to: repository.appendingPathComponent("native-merge-side.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Native merge side"], in: repository)
        try fixture.git(["checkout", "native-merge-feature"], in: repository)
        try fixture.write("mainline\n", to: repository.appendingPathComponent("native-merge-mainline.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Native merge mainline"], in: repository)
        try fixture.git(["merge", "--no-ff", "native-merge-side", "-m", "Native feature merge"], in: repository)
        try fixture.git(["checkout", "main"], in: repository)
        try fixture.write("target\n", to: repository.appendingPathComponent("native-merge-target.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Native merge target"], in: repository)
        let target = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "native-merge-feature"], in: repository)
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let options = RepositoryInteractiveRebaseTodoRequest(
            upstream: target,
            autoStash: false,
            autoSquash: false,
            rebaseMerges: true,
            updateRefs: nil,
            onto: nil,
            from: nil,
            branch: nil
        )
        var todo = try await source.loadNativeInteractiveRebaseTodo(options)
        try require(todo.contains("label ") && todo.contains("merge "), "native rebase-merges: Git topology directives are exposed")
        if let action = todo.range(of: "pick ") { todo.replaceSubrange(action, with: "edit ") }
        let started = try await source.interactiveRebase(RepositoryInteractiveRebaseRequest(
            upstream: target,
            items: [],
            autoStash: false,
            rebaseMerges: true,
            nativeTodo: todo
        ))
        guard case .paused = started.outcome else { throw MutationFixtureError("native rebase-merges: edit did not pause") }
        let activeTodo = try await source.loadRebaseTodoText()
        try require(activeTodo.contains("merge "), "native rebase-merges: active todo retains topology directives")
        _ = try await source.editRebaseTodoText(activeTodo)
        let result = try await source.continueRebase()
        try require(result.outcome == .completed, "native rebase-merges: edited active todo completes")
        let merges = try fixture.git(["rev-list", "--merges", "\(target)..HEAD"], in: repository).trimmed
        try require(!merges.isEmpty, "native rebase-merges: interactive topology retains a merge")
    }

    private static func testNativeInteractiveUpdateRefs(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Native update refs repo")
        try fixture.git(["checkout", "-b", "native-update-feature"], in: repository)
        try fixture.write("one\n", to: repository.appendingPathComponent("native-update-one.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Native update one"], in: repository)
        let dependentBefore = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["branch", "native-dependent"], in: repository)
        try fixture.write("two\n", to: repository.appendingPathComponent("native-update-two.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Native update two"], in: repository)
        try fixture.git(["checkout", "main"], in: repository)
        try fixture.write("target\n", to: repository.appendingPathComponent("native-update-target.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Native update target"], in: repository)
        let target = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "native-update-feature"], in: repository)
        try fixture.git(["config", "rebase.autosquash", "true"], in: repository)
        try fixture.git(["config", "rebase.updateRefs", "true"], in: repository)
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let configuration = try await source.loadRebaseConfiguration()
        try require(configuration.autoSquash && configuration.updateRefs, "rebase configuration: Git defaults are loaded")
        let options = RepositoryInteractiveRebaseTodoRequest(
            upstream: target,
            autoStash: false,
            autoSquash: true,
            rebaseMerges: false,
            updateRefs: true,
            onto: nil,
            from: nil,
            branch: nil
        )
        let todo = try await source.loadNativeInteractiveRebaseTodo(options)
        try require(todo.contains("update-ref refs/heads/native-dependent"), "native update-refs: dependent ref directive is retained")
        let result = try await source.interactiveRebase(RepositoryInteractiveRebaseRequest(
            upstream: target,
            items: [],
            autoStash: false,
            autoSquash: true,
            updateRefs: true,
            nativeTodo: todo
        ))
        try require(result.outcome == .completed, "native update-refs: interactive operation completes")
        let dependentAfter = try fixture.git(["rev-parse", "native-dependent"], in: repository).trimmed
        try require(dependentAfter != dependentBefore, "native update-refs: dependent branch is rewritten")
    }

    private static func testRebaseMerges(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Rebase merges repo")
        try fixture.git(["checkout", "-b", "merge-feature"], in: repository)
        try fixture.write("feature\n", to: repository.appendingPathComponent("merge-feature.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Merge feature"], in: repository)
        let featureBase = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "-b", "merge-side", featureBase], in: repository)
        try fixture.write("side\n", to: repository.appendingPathComponent("merge-side.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Merge side"], in: repository)
        try fixture.git(["checkout", "merge-feature"], in: repository)
        try fixture.write("mainline\n", to: repository.appendingPathComponent("merge-mainline.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Merge mainline"], in: repository)
        try fixture.git(["merge", "--no-ff", "merge-side", "-m", "Feature merge"], in: repository)
        try fixture.git(["checkout", "main"], in: repository)
        try fixture.write("new base\n", to: repository.appendingPathComponent("merge-target.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Merge target"], in: repository)
        let target = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "merge-feature"], in: repository)
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let result = try await source.rebase(RepositoryRebaseRequest(upstream: target, autoStash: false, rebaseMerges: true))
        try require(result.outcome == .completed, "rebase-merges: operation completes")
        let merges = try fixture.git(["rev-list", "--merges", "\(target)..HEAD"], in: repository).trimmed
        try require(!merges.isEmpty, "rebase-merges: topology retains a merge commit")
    }

    private static func testRebaseDateModes(_ fixture: MutationGitFixture) async throws {
        for (name, ignoreDate, committerIsAuthor) in [("ignore", true, false), ("committer", false, true)] {
            let repository = try fixture.clone(named: "Rebase date \(name) repo")
            try fixture.git(["checkout", "-b", "date-\(name)-feature"], in: repository)
            try fixture.write("date\n", to: repository.appendingPathComponent("date-\(name).txt"))
            try fixture.git(["add", "--all", "--"], in: repository)
            try fixture.git(
                ["commit", "-m", "Date \(name)"],
                in: repository,
                environment: ["GIT_AUTHOR_DATE": "2001-02-03T04:05:06Z", "GIT_COMMITTER_DATE": "2002-03-04T05:06:07Z"]
            )
            let originalAuthorDate = try fixture.git(["show", "-s", "--format=%at", "HEAD"], in: repository).trimmed
            try fixture.git(["checkout", "main"], in: repository)
            try fixture.write("target\n", to: repository.appendingPathComponent("date-target-\(name).txt"))
            try fixture.git(["add", "--all", "--"], in: repository)
            try fixture.git(["commit", "-m", "Date target \(name)"], in: repository)
            let target = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
            try fixture.git(["checkout", "date-\(name)-feature"], in: repository)
            let source = GitRepositoryModule(repositoryURL: repository)
            _ = try await source.loadRepositoryState()
            let result = try await source.rebase(RepositoryRebaseRequest(
                upstream: target,
                autoStash: false,
                ignoreDate: ignoreDate,
                committerDateIsAuthorDate: committerIsAuthor
            ))
            try require(result.outcome == .completed, "rebase dates: \(name) operation completes")
            let authorDate = try fixture.git(["show", "-s", "--format=%at", "HEAD"], in: repository).trimmed
            let committerDate = try fixture.git(["show", "-s", "--format=%ct", "HEAD"], in: repository).trimmed
            if ignoreDate { try require(authorDate != originalAuthorDate, "rebase dates: ignore-date resets author date") }
            if committerIsAuthor { try require(committerDate == authorDate, "rebase dates: committer date matches author date") }
        }
    }

    private static func testEditActiveRebaseTodo(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Edit active todo repo")
        let base = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "-b", "edit-todo-feature"], in: repository)
        for name in ["Todo A", "Todo B", "Todo C"] {
            try fixture.write("\(name)\n", to: repository.appendingPathComponent("\(name.replacingOccurrences(of: " ", with: "-")).txt"))
            try fixture.git(["add", "--all", "--"], in: repository)
            try fixture.git(["commit", "-m", name], in: repository)
        }
        let source = GitRepositoryModule(repositoryURL: repository)
        _ = try await source.loadRepositoryState()
        let plan = try await source.loadInteractiveRebasePlan(upstream: base)
        let started = try await source.interactiveRebase(RepositoryInteractiveRebaseRequest(
            upstream: base,
            items: [RepositoryRebaseTodoItem(commitID: plan[0].commitID, subject: plan[0].subject, action: .edit)] + Array(plan.dropFirst()),
            autoStash: false
        ))
        guard case .paused = started.outcome else { throw MutationFixtureError("edit todo: rebase did not stop") }
        let state = try await source.loadRebaseState()
        let pending = state.patches.filter { $0.status == .pending }
        try require(pending.map(\.subject) == ["Todo B", "Todo C"], "edit todo: pending rows are loaded from Git")
        let edited = [
            RepositoryRebaseTodoItem(commitID: try ObjectID.parse(pending[1].revisionToken), subject: pending[1].subject, action: .pick),
            RepositoryRebaseTodoItem(commitID: try ObjectID.parse(pending[0].revisionToken), subject: pending[0].subject, action: .drop)
        ]
        let updated = try await source.editRebaseTodo(edited)
        try require(updated.patches.filter { $0.status == .pending }.map(\.subject) == ["Todo C", "Todo B"], "edit todo: live todo order updates")
        let completed = try await source.continueRebase()
        try require(completed.outcome == .completed, "edit todo: continue completes edited sequence")
        let subjects = try fixture.git(["log", "--reverse", "--format=%s", "\(base)..HEAD"], in: repository).split(separator: "\n").map(String.init)
        try require(subjects == ["Todo A", "Todo C"], "edit todo: reordered and dropped rows affect resulting history")
    }

    private static func testRebaseConflictSkip(_ fixture: MutationGitFixture) async throws {
        let setup = try makeRebaseConflictRepository(fixture, name: "Rebase skip repo")
        let source = GitRepositoryModule(repositoryURL: setup.repository)
        _ = try await source.loadRepositoryState()
        let conflicted = try await source.rebase(RepositoryRebaseRequest(upstream: setup.target, autoStash: false))
        guard case .conflicts = conflicted.outcome else { throw MutationFixtureError("rebase skip: conflict was not created") }
        let skipped = try await source.skipRebase()
        try require(skipped.outcome == .completed, "rebase skip: operation completes")
        try require(try fixture.git(["rev-parse", "HEAD"], in: setup.repository).trimmed == setup.target, "rebase skip: conflicting commit is omitted")
        try require(try String(contentsOf: setup.repository.appendingPathComponent("shared.txt"), encoding: .utf8) == "target conflict\n", "rebase skip: target content remains")
    }

    private static func testApplyBackendRebaseState(_ fixture: MutationGitFixture) async throws {
        let setup = try makeRebaseConflictRepository(fixture, name: "Apply backend rebase state repo")
        let source = GitRepositoryModule(repositoryURL: setup.repository)
        _ = try await source.loadRepositoryState()
        let command = try await GitProcess().run(arguments: ["rebase", "--apply", setup.target], in: setup.repository)
        try require(!command.succeeded, "apply backend state: conflict stops the operation")
        let state = try await source.loadRebaseState()
        try require(state.inProgress && state.hasConflicts, "apply backend state: active conflict is detected")
        try require(state.patches.contains { $0.status == .applying && !$0.subject.isEmpty }, "apply backend state: numbered mail patch is parsed and selected")
        _ = try await source.abortRebase()
    }

    private static func testRebaseConflictAbort(_ fixture: MutationGitFixture) async throws {
        let setup = try makeRebaseConflictRepository(fixture, name: "Rebase abort repo")
        let source = GitRepositoryModule(repositoryURL: setup.repository)
        _ = try await source.loadRepositoryState()
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

    private static func testRebaseCancellation(_ fixture: MutationGitFixture) async throws {
        let repository = try fixture.clone(named: "Rebase cancellation repo")
        let target = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        try fixture.git(["checkout", "-b", "cancel-rebase-feature"], in: repository)
        try fixture.write("cancel rebase\n", to: repository.appendingPathComponent("cancel-rebase.txt"))
        try fixture.git(["add", "--all", "--"], in: repository)
        try fixture.git(["commit", "-m", "Cancel rebase feature"], in: repository)
        let before = try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed
        let runner = CancellableRebaseGitRunner()
        let source = GitRepositoryModule(repositoryURL: repository, git: runner)
        _ = try await source.loadRepositoryState()
        let task = Task { try await source.rebase(RepositoryRebaseRequest(upstream: target, autoStash: false)) }
        for _ in 0..<100 where !runner.didBeginRebase { try await Task.sleep(nanoseconds: 5_000_000) }
        try require(runner.didBeginRebase, "rebase cancellation: typed runner reached rebase")
        task.cancel()
        do {
            _ = try await task.value
            throw MutationFixtureError("rebase cancellation: cancelled operation completed")
        } catch is CancellationError {
            // Expected.
        }
        try require(try fixture.git(["rev-parse", "HEAD"], in: repository).trimmed == before, "rebase cancellation: HEAD is unchanged")
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

private final class CancellableCommitGitRunner: GitCommandRunning, @unchecked Sendable {
    private let base = GitProcess()
    private let lock = NSLock()
    private var beganCommit = false

    var didBeginCommit: Bool { lock.withLock { beganCommit } }

    func run(
        arguments: [String],
        in directory: URL,
        standardInput: Data?,
        environment: [String: String]
    ) async throws -> GitCommandResult {
        guard arguments.first == "commit" else {
            return try await base.run(
                arguments: arguments,
                in: directory,
                standardInput: standardInput,
                environment: environment
            )
        }
        lock.withLock { beganCommit = true }
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class CancellableRebaseGitRunner: GitCommandRunning, @unchecked Sendable {
    private let base = GitProcess()
    private let lock = NSLock()
    private var beganRebase = false

    var didBeginRebase: Bool { lock.withLock { beganRebase } }

    func run(
        arguments: [String],
        in directory: URL,
        standardInput: Data?,
        environment: [String: String]
    ) async throws -> GitCommandResult {
        guard arguments.first == "rebase" else {
            return try await base.run(arguments: arguments, in: directory, standardInput: standardInput, environment: environment)
        }
        lock.withLock { beganRebase = true }
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class CancellableMergeGitRunner: GitCommandRunning, @unchecked Sendable {
    private let base = GitProcess()
    private let lock = NSLock()
    private var beganMerge = false

    var didBeginMerge: Bool { lock.withLock { beganMerge } }

    func run(
        arguments: [String],
        in directory: URL,
        standardInput: Data?,
        environment: [String: String]
    ) async throws -> GitCommandResult {
        guard arguments.first == "merge" else {
            return try await base.run(
                arguments: arguments,
                in: directory,
                standardInput: standardInput,
                environment: environment
            )
        }
        lock.withLock { beganMerge = true }
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
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
