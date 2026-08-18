import Foundation

enum GitPushTests {
    static func run() async throws {
        try testCommandConstruction()
        try await testStateAndDestinationDerivation()
        try await testNormalNewAndExplicitPushes()
        try await testMultipleRemotesAndTags()
        try await testRejectionForceAndForceWithLease()
        try await testMultipleBranchCreationAndDeletion()
        try await testDetachedAndValidationFailures()
        try await testCancellationPreservesRemoteRef()
        print("GitPushTests: passed")
    }

    private static func testCommandConstruction() throws {
        try require(
            try GitPushCommandBuilder.arguments(for: RepositoryPushRequest(
                destination: .remote("origin"),
                operation: .branch(source: "refs/heads/from-branch", destination: "to-branch"),
                force: .forceWithLease,
                setUpstream: true,
                recursiveSubmodules: .onDemand
            )) == [
                "push", "--force-with-lease", "-u", "--recurse-submodules=on-demand", "--progress",
                "origin", "refs/heads/from-branch:refs/heads/to-branch"
            ],
            "command builder: branch push matches Git Extensions option and refspec ordering"
        )
        try require(
            try GitPushCommandBuilder.arguments(for: RepositoryPushRequest(
                destination: .url("/tmp/remote with spaces.git"),
                operation: .allBranches,
                force: .force,
                setUpstream: false,
                recursiveSubmodules: .check
            )) == ["push", "-f", "--recurse-submodules=check", "--progress", "--all", "/tmp/remote with spaces.git"],
            "command builder: all-branches push matches upstream ordering"
        )
        try require(
            try GitPushCommandBuilder.arguments(for: RepositoryPushRequest(
                destination: .remote("origin"),
                operation: .tag(" release 1 "),
                force: .force
            )) == ["push", "-f", "--progress", "origin", "tag", "release1"],
            "command builder: a selected tag uses the upstream tag refspec form"
        )
        try require(
            try GitPushCommandBuilder.arguments(for: RepositoryPushRequest(
                destination: .remote("origin"),
                operation: .allTags,
                force: .forceWithLease
            )) == ["push", "-f", "--progress", "origin", "--tags"],
            "command builder: tags normalize lease to ordinary force like the upstream bound controls"
        )
        try require(
            try GitPushCommandBuilder.arguments(for: RepositoryPushRequest(
                destination: .remote("origin"),
                operation: .multiple([
                    RepositoryPushAction(localBranch: "one", remoteBranch: "review/one", mode: .push),
                    RepositoryPushAction(localBranch: "two", remoteBranch: "two", mode: .force),
                    RepositoryPushAction(localBranch: nil, remoteBranch: "obsolete", mode: .delete)
                ])
            )) == [
                "push", "--progress", "origin",
                "refs/heads/one:refs/heads/review/one",
                "+refs/heads/two:refs/heads/two",
                ":refs/heads/obsolete"
            ],
            "command builder: multiple push has per-row push, force, and delete refspecs"
        )
        try require(
            RepositoryPullRequestURLBuilder.url(
                remoteURL: "git@github.com:owner/repository.git",
                branch: "feature/topic"
            )?.absoluteString == "https://github.com/owner/repository/compare/feature%2Ftopic?expand=1",
            "pull request follow-up: GitHub SSH remotes map to the host create page"
        )
        try require(
            RepositoryPullRequestURLBuilder.url(
                remoteURL: "https://dev.azure.com/organization/project/_git/repository",
                branch: "feature/topic"
            )?.absoluteString == "https://dev.azure.com/organization/project/_git/repository/pullrequestcreate?sourceRef=feature/topic",
            "pull request follow-up: Azure remotes map to the host create page"
        )

        let trackingState = RepositoryPushState(
            currentBranch: "topic",
            headID: "1",
            isBare: false,
            localBranches: [
                RepositoryPushBranchState(name: "topic", objectID: "1", trackingRemote: nil, mergeWith: nil, ahead: 0, behind: 0),
                RepositoryPushBranchState(name: "origin-copy", objectID: "1", trackingRemote: nil, mergeWith: nil, ahead: 0, behind: 0)
            ],
            remoteBranches: [],
            tags: [],
            remotes: [RepositoryRemoteConfiguration(
                name: "origin", fetchURL: "/tmp/origin.git", pushURL: nil,
                puttyKeyFile: nil, color: nil, prefix: nil, pushRefSpecs: [], isDisabled: false
            )],
            autoSetupMerge: true
        )
        try require(trackingState.shouldOfferTrackingReference(for: "topic"), "tracking prompt: an ordinary untracked branch is offered upstream creation")
        try require(!trackingState.shouldOfferTrackingReference(for: "origin-copy"), "tracking prompt: remote-prefixed local branch preserves the upstream suppression edge case")
    }

    private static func testStateAndDestinationDerivation() async throws {
        let fixture = try PullGitFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.clone(named: "Push state client")
        try fixture.git(["config", "--add", "remote.origin.push", "refs/heads/main:refs/heads/review/main"], in: repository)
        try fixture.git(["config", "--add", "remote.origin.push", "refs/heads/new-topic:refs/tags/not-a-branch"], in: repository)
        try fixture.git(["config", "--add", "remote.origin.push", "main:refs/heads/not-a-head-source"], in: repository)
        try fixture.git(["config", "remote.origin.prefix", "users/test/"], in: repository)
        try fixture.git(["config", "branch.autosetupmerge", "false"], in: repository)
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()
        let state = try await source.loadPushState()
        let directRemoteBranches = try await source.loadPushRemoteBranches(named: "origin")
        try require(state.currentBranch == "main" && state.preferredRemoteName == "origin", "push state: current tracking remote is preferred")
        try require(state.commandSource(for: "main") == "refs/heads/main", "push state: existing local branches use full source refs")
        try require(state.commandSource(for: "HEAD") == "HEAD", "push state: detached HEAD source remains HEAD")
        try require(state.defaultRemoteBranch(localBranch: "main", remoteName: "origin") == "review/main", "push state: explicit remote.push mapping wins")
        try require(state.defaultRemoteBranch(localBranch: "new-topic", remoteName: "origin") == "users/test/new-topic", "push state: remote prefix is applied after tracking/refspec rules")
        try require(!state.shouldOfferTrackingReference(for: "main"), "push state: existing tracking and autosetupmerge=false suppress upstream creation")
        try require(state.isBranchKnown(remote: "origin", branch: "main"), "push state: cached remote refs identify known branches")
        try require(directRemoteBranches.contains(where: { $0.name == "main" && $0.objectID == state.localBranches.first(where: { $0.name == "main" })?.objectID }), "push state: direct remote enumeration preserves branch object IDs for multiple-push comparison")
        try require(!state.autoSetupMerge, "push state: branch.autosetupmerge=false suppresses automatic upstream creation")
    }

    private static func testNormalNewAndExplicitPushes() async throws {
        let fixture = try PullGitFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.clone(named: "Normal push client")
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()
        try fixture.commit("normal\n", path: "normal.txt", message: "Normal push", in: repository)
        let events = PushOutputRecorder()
        let normal = try await source.performPush(
            RepositoryPushRequest(
                destination: .remote("origin"),
                operation: .branch(source: "refs/heads/main", destination: "main"),
                recursiveSubmodules: .none
            ),
            output: { event in events.append(event) }
        )
        try require(normal.outcome == .completed && !events.events.isEmpty, "normal push: completes and streams output")
        try require(try idsMatch("main", in: repository, remoteRef: "refs/heads/main", fixture: fixture), "normal push: bare remote receives the new commit")
        let current = normal.snapshot.branches.first(where: \.isCurrent)
        try require(current?.ahead == 0 && current?.behind == 0, "normal push: refreshed remote-tracking and ahead/behind state are current")

        let alreadyCurrent = try await source.performPush(
            RepositoryPushRequest(destination: .remote("origin"), operation: .branch(source: "refs/heads/main", destination: "main"), recursiveSubmodules: .none),
            output: { _ in }
        )
        try require(alreadyCurrent.outcome == .completed, "normal push: already up-to-date completes")

        try fixture.git(["checkout", "-b", "new/topic"], in: repository)
        try fixture.commit("new\n", path: "new.txt", message: "New branch", in: repository)
        let created = try await source.performPush(
            RepositoryPushRequest(
                destination: .remote("origin"),
                operation: .branch(source: "refs/heads/new/topic", destination: "published/topic"),
                setUpstream: true,
                recursiveSubmodules: .none
            ),
            output: { _ in }
        )
        try require(created.outcome == .completed, "new branch: explicit source/destination push completes")
        try require(try fixture.refExists("refs/heads/published/topic", in: fixture.originURL), "new branch: explicit destination is created")
        try require(try fixture.git(["config", "--get", "branch.new/topic.remote"], in: repository).trimmedPush == "origin", "new branch: -u writes the tracking remote")
        try require(try fixture.git(["config", "--get", "branch.new/topic.merge"], in: repository).trimmedPush == "refs/heads/published/topic", "new branch: -u writes the destination merge ref")

        try fixture.git(["branch", "all-one"], in: repository)
        try fixture.git(["branch", "all-two"], in: repository)
        let all = try await source.performPush(
            RepositoryPushRequest(destination: .remote("origin"), operation: .allBranches, recursiveSubmodules: .none),
            output: { _ in }
        )
        try require(all.outcome == .completed, "all branches: push completes")
        try require(try fixture.refExists("refs/heads/all-one", in: fixture.originURL), "all branches: first local branch is published")
        try require(try fixture.refExists("refs/heads/all-two", in: fixture.originURL), "all branches: second local branch is published")
    }

    private static func testMultipleRemotesAndTags() async throws {
        let fixture = try PullGitFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.clone(named: "Remote and tag client")
        try fixture.git(["remote", "add", "upstream", fixture.upstreamURL.path], in: repository)
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()
        try fixture.git(["checkout", "-b", "upstream-work"], in: repository)
        try fixture.commit("upstream\n", path: "upstream.txt", message: "Upstream push", in: repository)
        let upstream = try await source.performPush(
            RepositoryPushRequest(destination: .remote("upstream"), operation: .branch(source: "refs/heads/upstream-work", destination: "review/work"), recursiveSubmodules: .none),
            output: { _ in }
        )
        try require(upstream.outcome == .completed && (try fixture.refExists("refs/heads/review/work", in: fixture.upstreamURL)), "multiple remotes: only selected remote receives branch")
        try require(!(try fixture.refExists("refs/heads/review/work", in: fixture.originURL)), "multiple remotes: origin is unchanged")

        try fixture.git(["checkout", "-b", "url-work"], in: repository)
        let byURL = try await source.performPush(
            RepositoryPushRequest(destination: .url(fixture.originURL.path), operation: .branch(source: "refs/heads/url-work", destination: "url/work"), recursiveSubmodules: .none),
            output: { _ in }
        )
        try require(byURL.outcome == .completed && (try fixture.refExists("refs/heads/url/work", in: fixture.originURL)), "URL destination: absolute local bare-remote path is supported")

        try fixture.git(["tag", "push-one"], in: repository)
        let oneTag = try await source.performPush(
            RepositoryPushRequest(destination: .remote("origin"), operation: .tag("push-one")),
            output: { _ in }
        )
        try require(oneTag.outcome == .completed && (try fixture.refExists("refs/tags/push-one", in: fixture.originURL)), "tags: selected tag is pushed")
        try fixture.git(["tag", "push-two"], in: repository)
        let allTags = try await source.performPush(
            RepositoryPushRequest(destination: .remote("origin"), operation: .allTags),
            output: { _ in }
        )
        try require(allTags.outcome == .completed && (try fixture.refExists("refs/tags/push-two", in: fixture.originURL)), "tags: all tags are pushed")

        try fixture.git(["tag", "movable"], in: repository)
        _ = try await source.performPush(
            RepositoryPushRequest(destination: .remote("origin"), operation: .tag("movable")),
            output: { _ in }
        )
        let originalTagID = try fixture.git(["rev-parse", "refs/tags/movable"], in: fixture.originURL).trimmedPush
        try fixture.commit("move tag\n", path: "move-tag.txt", message: "Move tag", in: repository)
        try fixture.git(["tag", "-f", "movable"], in: repository)
        let rejectedTag = try await source.performPush(
            RepositoryPushRequest(destination: .remote("origin"), operation: .tag("movable")),
            output: { _ in }
        )
        try require(rejectedTag.outcome == .rejected && (try fixture.git(["rev-parse", "refs/tags/movable"], in: fixture.originURL).trimmedPush == originalTagID), "tags: replacing an existing tag is rejected without force")
        let forcedTag = try await source.performPush(
            RepositoryPushRequest(destination: .remote("origin"), operation: .tag("movable"), force: .forceWithLease),
            output: { _ in }
        )
        try require(forcedTag.outcome == .completed, "tags: lease selection normalizes to ordinary force and replaces the tag")
        try require(try fixture.git(["rev-parse", "refs/tags/movable"], in: fixture.originURL).trimmedPush == fixture.git(["rev-parse", "refs/tags/movable"], in: repository).trimmedPush, "tags: forced destination points at the moved local tag")
    }

    private static func testRejectionForceAndForceWithLease() async throws {
        let fixture = try PullGitFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.clone(named: "Rejected push client")
        let peer = try fixture.clone(named: "Rejected push peer")
        try fixture.commit("local\n", path: "local.txt", message: "Local divergence", in: repository)
        try fixture.commit("peer\n", path: "peer.txt", message: "Peer divergence", in: peer)
        try fixture.git(["push", "origin", "main"], in: peer)
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()
        let rejected = try await source.performPush(
            RepositoryPushRequest(destination: .remote("origin"), operation: .branch(source: "refs/heads/main", destination: "main"), recursiveSubmodules: .none),
            output: { _ in }
        )
        try require(rejected.outcome == .rejected, "rejection: non-fast-forward is classified separately")
        try require(rejected.command.exitStatus != 0 && !rejected.command.standardErrorString.isEmpty, "rejection: stderr and status are preserved")

        let leaseRejected = try await source.performPush(
            RepositoryPushRequest(destination: .remote("origin"), operation: .branch(source: "refs/heads/main", destination: "main"), force: .forceWithLease, recursiveSubmodules: .none),
            output: { _ in }
        )
        try require(leaseRejected.outcome == .rejected, "force-with-lease: stale remote-tracking lease rejects")
        try require(try fixture.git(["rev-parse", "main"], in: fixture.originURL).trimmedPush == fixture.git(["rev-parse", "main"], in: peer).trimmedPush, "force-with-lease: stale lease preserves peer work")

        let forced = try await source.performPush(
            RepositoryPushRequest(destination: .remote("origin"), operation: .branch(source: "refs/heads/main", destination: "main"), force: .force, recursiveSubmodules: .none),
            output: { _ in }
        )
        try require(forced.outcome == .completed, "force: explicit force overwrites non-fast-forward target")
        try require(try idsMatch("main", in: repository, remoteRef: "refs/heads/main", fixture: fixture), "force: remote now points at local branch")

        try fixture.commit("peer after force\n", path: "peer-after.txt", message: "Peer after force", in: peer)
        _ = try? fixture.git(["push", "--force", "origin", "main"], in: peer)
        try fixture.git(["fetch", "origin"], in: repository)
        try fixture.commit("lease succeeds\n", path: "lease.txt", message: "Lease succeeds", in: repository)
        let leaseSucceeded = try await source.performPush(
            RepositoryPushRequest(destination: .remote("origin"), operation: .branch(source: "refs/heads/main", destination: "main"), force: .forceWithLease, recursiveSubmodules: .none),
            output: { _ in }
        )
        try require(leaseSucceeded.outcome == .completed, "force-with-lease: current lease allows intentional overwrite")
    }

    private static func testMultipleBranchCreationAndDeletion() async throws {
        let fixture = try PullGitFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.clone(named: "Multiple push client")
        try fixture.git(["branch", "one"], in: repository)
        try fixture.git(["branch", "two"], in: repository)
        try fixture.git(["branch", "obsolete"], in: repository)
        try fixture.git(["push", "origin", "obsolete"], in: repository)
        try fixture.git(["config", "branch.obsolete.remote", "origin"], in: repository)
        try fixture.git(["config", "branch.obsolete.merge", "refs/heads/obsolete"], in: repository)
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()
        try fixture.git(["config", "receive.denyDeletes", "true"], in: fixture.originURL)
        let remoteRejected = try await source.performPush(
            RepositoryPushRequest(
                destination: .remote("origin"),
                operation: .multiple([RepositoryPushAction(localBranch: nil, remoteBranch: "main", mode: .delete)]),
                recursiveSubmodules: .none
            ),
            output: { _ in }
        )
        try require(remoteRejected.outcome == .failed, "remote rejection: server-side rejection remains an ordinary failure rather than entering non-fast-forward recovery")
        try require(remoteRejected.command.standardErrorString.contains("remote rejected") && (try fixture.refExists("refs/heads/main", in: fixture.originURL)), "remote rejection: stderr is preserved and the rejected ref is unchanged")
        try fixture.git(["config", "--unset", "receive.denyDeletes"], in: fixture.originURL)
        let merged = try await source.loadMergedRemoteBranches()
        try require(merged.contains("origin/obsolete"), "remote deletion: merged-remote discovery identifies safe deletions")
        let result = try await source.performPush(
            RepositoryPushRequest(
                destination: .remote("origin"),
                operation: .multiple([
                    RepositoryPushAction(localBranch: "one", remoteBranch: "created/one", mode: .push),
                    RepositoryPushAction(localBranch: "two", remoteBranch: "created/two", mode: .force),
                    RepositoryPushAction(localBranch: nil, remoteBranch: "obsolete", mode: .delete)
                ])
            ),
            output: { _ in }
        )
        try require(result.outcome == .completed, "multiple branches: combined operation completes")
        try require(try fixture.refExists("refs/heads/created/one", in: fixture.originURL), "multiple branches: normal row creates destination")
        try require(try fixture.refExists("refs/heads/created/two", in: fixture.originURL), "multiple branches: force row creates destination")
        try require(!(try fixture.refExists("refs/heads/obsolete", in: fixture.originURL)), "multiple branches: delete row removes remote ref")
        try require(!result.snapshot.branches.contains(where: { $0.isRemote && $0.remoteName == "origin" && $0.name == "obsolete" }), "multiple branches: refreshed snapshot removes remote-tracking ref")
        let afterLocalDelete = try await source.deleteLocalTrackingBranches(["obsolete"], force: false)
        try require(!afterLocalDelete.branches.contains(where: { !$0.isRemote && $0.name == "obsolete" }), "remote deletion: optional local tracking branch cleanup updates repository state")
    }

    private static func testDetachedAndValidationFailures() async throws {
        let fixture = try PullGitFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.clone(named: "Push validation client")
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()
        try fixture.git(["checkout", "--detach", "HEAD"], in: repository)
        let state = try await source.loadPushState()
        try require(state.isDetached, "detached HEAD: state is represented")
        let detached = try await source.performPush(
            RepositoryPushRequest(destination: .remote("origin"), operation: .branch(source: "HEAD", destination: "detached/published"), recursiveSubmodules: .none),
            output: { _ in }
        )
        try require(detached.outcome == .completed && (try fixture.refExists("refs/heads/detached/published", in: fixture.originURL)), "detached HEAD: explicit destination is supported")

        do {
            _ = try await source.performPush(
                RepositoryPushRequest(destination: .remote("missing"), operation: .allBranches, recursiveSubmodules: .none),
                output: { _ in }
            )
            throw PullFixtureError("validation: missing remote was accepted")
        } catch RepositoryPushError.missingRemote(let value) {
            try require(value == "missing", "validation: missing remote name is preserved")
        }
        do {
            _ = try await source.performPush(
                RepositoryPushRequest(destination: .remote("origin"), operation: .branch(source: "HEAD", destination: "bad~branch"), recursiveSubmodules: .none),
                output: { _ in }
            )
            throw PullFixtureError("validation: invalid destination branch was accepted")
        } catch RepositoryPushError.invalidRemoteBranch(let value) {
            try require(value == "bad~branch", "validation: invalid destination ref is preserved")
        }

        let missingURL = fixture.rootURL.appendingPathComponent("Missing Remote.git").path
        let events = PushOutputRecorder()
        let failed = try await source.performPush(
            RepositoryPushRequest(destination: .url(missingURL), operation: .branch(source: "HEAD", destination: "missing"), recursiveSubmodules: .none),
            output: { event in events.append(event) }
        )
        try require(failed.outcome == .failed && failed.command.exitStatus != 0, "failure: invalid URL/path preserves typed failure status")
        try require(!failed.command.standardErrorString.isEmpty && !events.standardError.isEmpty, "failure: stderr is retained and streamed")
    }

    private static func testCancellationPreservesRemoteRef() async throws {
        let fixture = try PullGitFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.clone(named: "Cancelled push client")
        try fixture.commit("cancelled\n", path: "cancelled.txt", message: "Cancelled push", in: repository)
        let originalRemoteID = try fixture.git(["rev-parse", "refs/heads/main"], in: fixture.originURL).trimmedPush
        let marker = fixture.rootURL.appendingPathComponent("push-hook-started")
        let hook = fixture.originURL.appendingPathComponent("hooks/pre-receive")
        try fixture.write("#!/bin/sh\ntouch '\(marker.path)'\nsleep 10\n", to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repository)
        _ = try await source.loadSnapshot()
        let started = Date()
        let task = Task {
            try await source.performPush(
                RepositoryPushRequest(
                    destination: .remote("origin"),
                    operation: .branch(source: "refs/heads/main", destination: "main"),
                    recursiveSubmodules: .none
                ),
                output: { _ in }
            )
        }
        for _ in 0..<80 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try require(FileManager.default.fileExists(atPath: marker.path), "cancellation: disposable remote hook began before cancellation")
        task.cancel()
        do {
            _ = try await task.value
            throw PullFixtureError("cancellation: cancelled Push completed")
        } catch is CancellationError {
            // Expected.
        }
        try require(Date().timeIntervalSince(started) < 3, "cancellation: Push terminates Git and its remote child process promptly")
        let remoteID = try fixture.git(["rev-parse", "refs/heads/main"], in: fixture.originURL).trimmedPush
        try require(remoteID == originalRemoteID, "cancellation: remote branch remains unchanged")
    }

    private static func idsMatch(_ localRef: String, in repository: URL, remoteRef: String, fixture: PullGitFixture) throws -> Bool {
        try fixture.git(["rev-parse", localRef], in: repository).trimmedPush
            == fixture.git(["rev-parse", remoteRef], in: fixture.originURL).trimmedPush
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw PullFixtureError(message) }
    }
}

private final class PushOutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [GitOutputEvent] = []
    var events: [GitOutputEvent] { lock.withLock { recorded } }
    var standardError: String {
        lock.withLock { recorded.filter { $0.stream == .standardError }.map(\.text).joined() }
    }
    func append(_ event: GitOutputEvent) { lock.withLock { recorded.append(event) } }
}

private extension String {
    var trimmedPush: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
