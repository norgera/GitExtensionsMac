import AppKit
import Foundation
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("Repository status")
    enum RepositoryStatusTests {
        private struct Failure: LocalizedError { let errorDescription: String? }
        private static func wait(_ message: String, until condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(12)
            while !condition() {
                #expect(ContinuousClock.now < deadline, Comment(rawValue: message))
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        @Test("Classifier vectors") private static func classifierVectors() throws {
            func record(_ index: Character = ".", _ worktree: Character = ".", untracked: Bool = false, submodule: Bool = false) -> GitStatusRecord {
                GitStatusRecord(
                    path: "file", oldPath: nil, indexStatus: index, worktreeStatus: worktree,
                    isUntracked: untracked, isConflict: false, submoduleStatus: submodule ? "S.M." : "N...")
            }
            let vectors: [([GitStatusRecord]?, RepositoryVisualState)] = [
                ([], .clean), (nil, .unknown),
                ([record(".", "M", submodule: true), record(".", "M", submodule: true)], .dirtySubmodules),
                ([record(".", "M", submodule: true), record(".", "M")], .dirty),
                ([record("M"), record(".", "M")], .mixed),
                ([record("M"), record("A")], .staged),
                ([record(".", "?", untracked: true), record(".", "?", untracked: true)], .untrackedOnly),
                ([record(".", "M")], .dirty), ([record("M", "M")], .mixed),
                ([record("A"), record(".", "?", untracked: true)], .mixed),
                ([record(".", "M", submodule: true), record(".", "?", untracked: true)], .dirty),
                ([record("M", ".", submodule: true)], .staged),
            ]
            for (records, expected) in vectors {
                #expect(GitStatusRecord.visualState(records) == expected, "RepoStateVisualiser vector \(expected)")
            }
            let unmerged = GitStatusRecord(path: "conflict", oldPath: nil, indexStatus: "U", worktreeStatus: "U", isUntracked: false, isConflict: true)
            #expect(
                GitStatusRecord.visualState([unmerged]) == .dirty && GitStatusRecord.entryCount([unmerged]) == 1,
                "upstream suppresses index entry for UU conflict")
            for state in RepositoryVisualState.allCases {
                #expect(state.imageName(enabled: false) == "RepoStateClean", "disabled status icon")
                #expect(state.imageName(enabled: true) == "RepoState" + state.rawValue, "enabled status icon")
            }
            let ordered = ["a", "b"].map {
                GitStatusRecord(path: $0, oldPath: nil, indexStatus: "M", worktreeStatus: "M", isUntracked: false, isConflict: false)
            }
            #expect(
                GitStatusRecord.allRevisionChangeCounts(ordered).changed == ["a", "a", "b", "b"],
                "combined summary preserves upstream index/worktree order per path")
            #expect(GitStatusRecord.entryCount([record("M", "M")]) == 2, "index and worktree entries counted separately")
        }

        @Test("Push vectors") private static func pushVectors() throws {
            func data(_ ahead: String, _ behind: String) -> AheadBehindData {
                AheadBehindData(branch: "main", remoteRef: "origin/main", aheadCount: ahead, behindCount: behind)
            }
            let vectors: [(AheadBehindData?, Bool, String, String)] = [
                (nil, true, "", "Push"), (data("0", ""), true, "0↑↓", "Push"),
                (data("9", ""), true, "9↑", "Push"), (data("", "2"), true, "2↓", "Unstage"),
                (data("99", "3"), true, "99↑ 3↓", "Unstage"), (data("gone", ""), true, "✗", "Push"),
                (data("99", "3"), false, "", "Push"), (data("", ""), true, "", "Push"),
            ]
            for (input, enabled, text, image) in vectors {
                let result = PushButtonPresentation(data: input, enabled: enabled)
                #expect(result.text == text && result.imageName == image, "ToolStripPushButton vector \(text)")
            }
            #expect(PushButtonPresentation(data: nil, enabled: true).tooltip == "Push", "missing upstream distinct from 0/0")
            for n in ["0", "1", "2", "99"] {
                #expect(
                    PushButtonPresentation(data: data(n, ""), enabled: true, shortcut: "⌃↑").tooltip
                        == "\(n) new commit(s) will be pushed (⌃↑)", "literal upstream singular/plural wording and shortcut")
            }
            for n in ["1", "2", "3"] {
                #expect(
                    PushButtonPresentation(data: data("", n), enabled: true).tooltip
                        == "\(n) commit(s) should be integrated (or will be lost if force pushed)", "behind tooltip")
            }
            #expect(PushButtonPresentation(data: data("gone", ""), enabled: true).tooltip == "gone new commit(s) will be pushed", "gone tooltip")
            #expect(PushButtonPresentation(data: data("", ""), enabled: true).tooltip == nil, "empty available data")
            #expect(AheadBehindData.parse("\0\0\0\0main\0").isEmpty, "no upstream parser")
            #expect(AheadBehindData.parse("\0\0\0refs/remotes/origin/main\0main\0")["main"]?.display() == "0↑↓", "tracked zero parser")
            #expect(AheadBehindData.parse("\0gone\0\0refs/remotes/origin/main\0main\0")["main"]?.isGone == true, "gone parser")
        }

        @Test("Summary vectors") private static func summaryVectors() throws {
            var counts = RevisionChangeCounts()
            #expect(counts.summary.isEmpty, "no changes has empty summary")
            counts.changed = ["a"]
            #expect(counts.summary == "1 changed file\n- a\n", "one changed file")
            #expect(counts.merging(counts).summary == "2 changed files\n- a\n- a\n", "shared submodule summary counts both index/worktree entries")
            counts.deleted = ["d1", "d2"]
            counts.added = ["new"]
            counts.submodulesChanged = ["module"]
            counts.submodulesDirty = ["module"]
            #expect(
                counts.summary
                    == "1 changed file\n- a\n\n2 deleted files\n- d1\n- d2\n\n1 new file\n- new\n\n1 changed submodule\n- module\n\n1 dirty submodule\n- module\n",
                "category order, blank lines, plural wording")
            counts.changed = (1...6).map { "f\($0)" }
            #expect(counts.summary.contains("- f5\n- (1 more file)\n") && !counts.summary.contains("- f6"), "five-path cap")
            counts.changed.append("f7")
            #expect(counts.summary.contains("- (2 more files)"), "plural omitted files")
            let rows = RevisionCommitBuilder.artificialRevisions(headID: nil)
            for row in rows {
                #expect(
                    RevisionGridPresentation.messageToolTip(row, notesInSeparateColumn: false, artificialCounts: counts) == counts.summary, "WD/Index summary")
                #expect(
                    RevisionGridPresentation.messageToolTip(row, notesInSeparateColumn: false, artificialCounts: counts, showArtificialCounts: false) == nil,
                    "disabled artificial summary")
                #expect(RevisionGridPresentation.messageToolTip(row, notesInSeparateColumn: false) == nil, "unavailable summary")
            }
            let url = URL(fileURLWithPath: "/fixture/module")
            let item = SubmoduleTreeItem(
                repositoryURL: url, parentURL: url.deletingLastPathComponent(), path: "module", localPath: "module", isCurrent: false, isTop: false,
                isInitialized: true, branch: "main", commitID: nil, recordedID: nil, commitState: .same, changeCounts: counts)
            #expect(SubmoduleTreePresentation.toolTip(item) == counts.summary, "submodule fallback summary")
            let detailed = SubmoduleTreeItem(
                repositoryURL: url, parentURL: url.deletingLastPathComponent(), path: "module", localPath: "module", isCurrent: false, isTop: false,
                isInitialized: true, branch: "main", commitID: nil, recordedID: nil, commitState: .ahead, addedCommits: 2, removedCommits: 0, isDirty: true,
                changeCounts: counts)
            #expect(
                SubmoduleTreePresentation.toolTip(detailed).contains("Type: Fast Forward (dirty)")
                    && SubmoduleTreePresentation.toolTip(detailed).contains("2 added / 0 removed commits"), "detailed submodule status retained")
        }

        @Test("Refresh vectors") private static func refreshVectors() throws {
            var state = RepositoryRefreshState()
            #expect(!state.isDirty && state.active == nil, "initial up-to-date")
            state.changed()
            #expect(state.isDirty, "event enters dirty")
            let first = state.begin()
            #expect(state.isDirty && state.active == first, "refresh begins without clearing dirty")
            state.changed()
            state.finish(first, succeeded: true)
            #expect(state.isDirty && state.active == nil, "event during refresh retained")
            let second = state.begin()
            state.finish(second, succeeded: true)
            #expect(!state.isDirty, "successful refresh incorporates generation")
            state.changed()
            let third = state.begin()
            state.finish(third, succeeded: false)
            #expect(state.isDirty, "failed/cancelled refresh remains dirty")
            let cancelled = state.begin()
            let replacement = state.begin()
            #expect(!state.finish(cancelled, succeeded: true) && state.active == replacement, "stale completion cannot clear replacement")
            state.reset()
            state.finish(replacement, succeeded: true)
            #expect(!state.isDirty && state.active == nil, "switch/reset rejects previous repository completion")
            let timing = RepositoryStatusMonitor.Timing()
            #expect(
                timing.debounce == .seconds(1) && timing.interactive == .milliseconds(200)
                    && timing.minimumInterval == .seconds(30) && timing.poll == .seconds(300), "upstream timing constants")
        }

        @Test("Monitor scheduling scenarios") private static func monitorSchedulingScenarios() async throws {
            let monitor = RepositoryStatusMonitor(
                timing: .init(debounce: .milliseconds(40), interactive: .milliseconds(20), minimumInterval: .milliseconds(40), poll: .seconds(3600)))
            defer { monitor.stop() }
            var callbacks = 0
            var paused = true
            monitor.isPaused = { paused }
            monitor.onRefresh = { callbacks += 1 }
            monitor.changed(interactive: true)
            try await Task.sleep(for: .milliseconds(70))
            #expect(callbacks == 0 && monitor.state.isDirty, "pause defers refresh while retaining dirty state")
            paused = false
            try await wait("resume delivers pending refresh") { callbacks == 1 }
            monitor.stop()
            monitor.receive(path: "/fixture/.git/index.lock", flags: 0)
            #expect(!monitor.state.isDirty, "optional index lock excluded")
            for _ in 0..<3 {
                monitor.changed()
                let ticket = monitor.beginRefresh()
                monitor.finishRefresh(ticket, succeeded: false)
            }
            #expect(monitor.automaticRefreshSuspended && monitor.state.isDirty, "three errors suspend automatic refresh")
            monitor.changed(interactive: true)
            #expect(!monitor.automaticRefreshSuspended, "interactive refresh recovers from suspended state")
            monitor.suspendAutomaticRefresh()
            #expect(monitor.automaticRefreshSuspended, "security decline suspends automatic trust retry")
        }

        @Test("Repository scenarios") private static func repositoryScenarios() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let repo = try await fixture.repository("repo")
            let module = GitRepositoryModule(repositoryURL: repo, git: fixture.runner)
            let initial = try await module.loadRepositoryState()
            #expect(initial.status.visualState == .clean && initial.aheadBehind.isEmpty, "clean repo, no upstream")
            let monitor = RepositoryStatusMonitor(
                timing: .init(debounce: .milliseconds(150), interactive: .milliseconds(30), minimumInterval: .milliseconds(150), poll: .seconds(3600)))
            defer { monitor.stop() }
            var refreshed: RepositoryLoadState = initial
            var completions = 0
            var failures: [String] = []
            var tasks: [Task<Void, Never>] = []
            monitor.onRefresh = {
                let ticket = monitor.beginRefresh()
                let task = Task { @MainActor in
                    do {
                        refreshed = try await module.loadRepositoryState()
                        monitor.finishRefresh(ticket, succeeded: true)
                    } catch {
                        failures.append(error.localizedDescription)
                        monitor.finishRefresh(ticket, succeeded: false)
                    }
                    completions += 1
                }
                tasks.append(task)
            }
            monitor.configure(repositoryID: initial.identity.currentRepository.id, urls: initial.monitoringURLs)
            #expect(monitor.isRunning, "native stream starts")
            func settle(_ message: String, after count: Int) async throws {
                try await wait(message) { completions > count && monitor.state.active == nil && !monitor.state.isDirty }
                #expect(failures.isEmpty, "refresh failures: \(failures)")
            }
            var count = completions
            try fixture.write(repo, "tracked.txt", "external edit\n")
            try await settle("external edit refresh", after: count)
            #expect(refreshed.status.visualState == .dirty && refreshed.status.worktree?.changed == ["tracked.txt"], "external edit snapshot")
            count = completions
            try await fixture.git(["add", "tracked.txt"], in: repo)
            try await settle("external add refresh", after: count)
            #expect(refreshed.status.visualState == .staged && refreshed.status.index?.changed == ["tracked.txt"], "staged-only state and tooltip")
            count = completions
            try await fixture.git(["reset", "HEAD", "--", "tracked.txt"], in: repo)
            try await settle("external index reset", after: count)
            #expect(refreshed.status.visualState == .dirty, "reset state")
            count = completions
            try await fixture.git(["add", "."], in: repo)
            try await fixture.git(["commit", "-qm", "external commit"], in: repo)
            try await settle("external commit/ref refresh", after: count)
            #expect(refreshed.identity.headID != initial.identity.headID && refreshed.status.visualState == .clean, "HEAD change and clean snapshot")
            count = completions
            try await fixture.git(["checkout", "-qb", "feature"], in: repo)
            try await settle("external branch switch", after: count)
            #expect(refreshed.references.branches.contains { $0.name == "feature" && $0.isCurrent }, "branch state")
            count = completions
            for index in 0..<40 { try fixture.write(repo, "burst-\(index)", "data") }
            try await settle("coalesced burst", after: count)
            #expect(
                completions == count + 1 && refreshed.status.worktree?.added.count == 40 && refreshed.status.visualState == .untrackedOnly,
                "forty writes coalesce into one refresh")
            count = completions
            try await fixture.git(["add", "tracked.txt"], in: repo)
            let inApp = monitor.beginRefresh()
            _ = try await module.loadRepositoryState()
            monitor.finishRefresh(inApp, succeeded: true)
            monitor.changed(interactive: true)
            try await settle("interactive refresh", after: count)
            count = completions
            let drain = monitor.beginRefresh()
            try fixture.write(repo, "during-refresh", "external event while active")
            try await wait("native event while refresh active") { monitor.state.isDirty }
            monitor.finishRefresh(drain, succeeded: true)
            #expect(monitor.state.isDirty, "pending event remains dirty")
            try await settle("event while active requests another refresh", after: count)
            count = completions
            monitor.changed(interactive: true)
            let same = monitor.beginRefresh()
            _ = try await module.loadRepositoryState()
            monitor.finishRefresh(same, succeeded: true)
            let barrier = monitor.beginRefresh()
            try await Task.sleep(for: .milliseconds(400))
            #expect(completions == count && !monitor.state.isDirty, "read-only refresh creates no event loop")
            monitor.finishRefresh(barrier, succeeded: true)
            let second = try await fixture.repository("other")
            let otherModule = GitRepositoryModule(repositoryURL: second, git: fixture.runner)
            let other = try await otherModule.loadRepositoryState()
            monitor.configure(repositoryID: other.identity.currentRepository.id, urls: other.monitoringURLs)
            let switched = monitor.beginRefresh()
            try fixture.write(repo, "old-only", "old")
            try await Task.sleep(for: .milliseconds(250))
            #expect(!monitor.state.isDirty, "switch tears down old repository stream")
            monitor.finishRefresh(switched, succeeded: true)
            monitor.stop()
            #expect(!monitor.isRunning && !monitor.state.isDirty, "stop clears watchers/tasks/state")
            monitor.configure(repositoryID: other.identity.currentRepository.id, urls: other.monitoringURLs)
            monitor.onRefresh = {
                let ticket = monitor.beginRefresh()
                monitor.finishRefresh(ticket, succeeded: true)
            }
            try FileManager.default.moveItem(at: second, to: fixture.root.appendingPathComponent("moved"))
            try await wait("moved watched root produces change") { monitor.state.isDirty }
            monitor.stop()
            #expect(!monitor.isRunning, "moved/deleted watched root cleanup")
            weak var released: RepositoryStatusMonitor?
            do {
                let transient = RepositoryStatusMonitor()
                released = transient
                transient.configure(repositoryID: "lifecycle", urls: [repo])
            }
            #expect(released == nil, "native callback and poll do not retain monitor")
            for task in tasks { await task.value }
            try await submoduleAndTrackingScenarios(fixture)
        }

        private static func submoduleAndTrackingScenarios(_ fixture: Fixture) async throws {
            let root = try await fixture.repository("superproject")
            let child = try await fixture.repository("child-source")
            try await fixture.git(["-c", "protocol.file.allow=always", "submodule", "add", child.path, "child"], in: root)
            try await fixture.git(["commit", "-qam", "add child"], in: root)
            let module = GitRepositoryModule(repositoryURL: root, git: fixture.runner)
            let initial = try await module.loadRepositoryState()
            let monitor = RepositoryStatusMonitor(
                timing: .init(debounce: .milliseconds(100), interactive: .milliseconds(20), minimumInterval: .milliseconds(100), poll: .seconds(3600)))
            defer { monitor.stop() }
            var events = 0
            monitor.onRefresh = { events += 1 }
            monitor.configure(repositoryID: initial.identity.currentRepository.id, urls: initial.monitoringURLs)
            let worktree = root.appendingPathComponent("child")
            try fixture.write(worktree, "tracked.txt", "child external edit")
            try await wait("submodule worktree event") { events > 0 }
            var state = try await module.loadRepositoryState()
            #expect(state.status.visualState == .dirtySubmodules && state.status.worktree?.submodulesDirty == ["child"], "dirty submodule classifier/summary")
            #expect(
                state.navigation.submoduleTree.first { $0.path == "child" }?.changeCounts?.changed == ["tracked.txt"],
                "submodule tooltip uses current shared child status")
            let count = events
            try await fixture.git(["add", "tracked.txt"], in: worktree)
            try await wait("submodule index event") { events > count }
            state = try await module.loadRepositoryState()
            #expect(state.navigation.submoduleTree.first { $0.path == "child" }?.changeCounts?.changed == ["tracked.txt"], "child index summary")
            try await fixture.git(["-c", "user.name=Status Parity", "-c", "user.email=status@example.com", "commit", "-qm", "child commit"], in: worktree)
            try fixture.write(worktree, "tracked.txt", "child dirty after commit")
            state = try await module.loadRepositoryState()
            #expect(
                state.status.worktree?.submodulesChanged == ["child"] && state.status.worktree?.submodulesDirty == ["child"],
                "changed and dirty child categories both retained")
            let linked = fixture.root.appendingPathComponent("linked")
            try await fixture.git(["worktree", "add", "-b", "linked", linked.path], in: root)
            let linkedModule = GitRepositoryModule(repositoryURL: linked, git: fixture.runner)
            let linkedState = try await linkedModule.loadRepositoryState()
            #expect(linkedState.monitoringURLs.contains(root.appendingPathComponent(".git")), "linked worktree watches common refs")
            let remote = fixture.root.appendingPathComponent("remote.git")
            try await fixture.git(["init", "--bare", "-q", remote.path], in: fixture.root)
            try await fixture.git(["remote", "add", "origin", remote.path], in: root)
            try await fixture.git(["push", "-qu", "origin", "main"], in: root)
            state = try await module.loadRepositoryState()
            #expect(state.aheadBehind["main"]?.display() == "0↑↓", "tracked zero after push")
            try await fixture.git(["commit", "--allow-empty", "-qm", "ahead"], in: root)
            state = try await module.loadRepositoryState()
            #expect(state.aheadBehind["main"]?.display() == "1↑", "ahead after external commit")
            let beforeRef = events
            try await fixture.git(["update-ref", "refs/remotes/origin/main", "HEAD"], in: root)
            try await wait("external tracking ref change event") { events > beforeRef }
            state = try await module.loadRepositoryState()
            #expect(state.aheadBehind["main"]?.display() == "0↑↓", "external tracking ref update")
            try await fixture.git(["push", "-q", "origin", "main"], in: root)
            state = try await module.loadRepositoryState()
            #expect(state.aheadBehind["main"]?.display() == "0↑↓", "ahead clears after push")
            let peer = fixture.root.appendingPathComponent("peer")
            try await fixture.git(["clone", "-q", "--branch", "main", remote.path, peer.path], in: fixture.root)
            for (key, value) in [("user.name", "Status Parity"), ("user.email", "status@example.com"), ("commit.gpgsign", "false")] {
                try await fixture.git(["config", key, value], in: peer)
            }
            try await fixture.git(["commit", "--allow-empty", "-qm", "peer advance"], in: peer)
            try await fixture.git(["push", "-q", "origin", "main"], in: peer)
            let beforeFetch = events
            try await fixture.git(["fetch", "-q", "origin"], in: root)
            try await wait("fetch tracking ref event") { events > beforeFetch }
            state = try await module.loadRepositoryState()
            #expect(state.aheadBehind["main"]?.display() == "1↓", "behind state after fetch")
            try await fixture.git(["pull", "--ff-only", "-q"], in: root)
            state = try await module.loadRepositoryState()
            #expect(state.aheadBehind["main"]?.display() == "0↑↓", "behind clears after pull")
            try await fixture.git(["update-ref", "-d", "refs/remotes/origin/main"], in: root)
            state = try await module.loadRepositoryState()
            #expect(state.aheadBehind["main"]?.isGone == true, "gone upstream after external ref deletion")
            try await fixture.git(["branch", "--unset-upstream"], in: root)
            state = try await module.loadRepositoryState()
            #expect(state.aheadBehind["main"] == nil, "upstream tracking removal")
        }

        @Test("Ownership scenarios") private static func ownershipScenarios() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let repo = try await fixture.repository("repo space ' ; $ special")
            let output =
                "fatal: detected dubious ownership in repository at '\(repo.path)'\nTo add an exception for this directory, call:\n\tgit config --global --add safe.directory '\(repo.path)'\n"
            #expect(
                DubiousRepositoryOwnership.recognize(output, accessing: repo)?.repositoryURL.path == repo.resolvingSymlinksInPath().path,
                "canonical ownership recognition and special path")
            let legacy = "fatal: unsafe repository ('\(repo.path)' is owned by someone else)\ngit config --global --add safe.directory '\(repo.path)'"
            #expect(DubiousRepositoryOwnership.recognize(legacy, accessing: repo) != nil, "legacy canonical unsafe-repository diagnostic")
            #expect(DubiousRepositoryOwnership.recognize("fatal: not a git repository", accessing: repo) == nil, "unrelated failure")
            #expect(
                DubiousRepositoryOwnership.recognize("user text config --global --add safe.directory *", accessing: repo) == nil,
                "vague substring does not trigger trust")
            let wildcard = repo.appendingPathComponent("*")
            let wildcardOutput =
                "fatal: detected dubious ownership in repository at '\(wildcard.path)'\ngit config --global --add safe.directory '\(wildcard.path)'"
            #expect(DubiousRepositoryOwnership.recognize(wildcardOutput, accessing: wildcard) == nil, "Git parent wildcard suffix never trusted")
            #expect(DubiousRepositoryOwnership.recognize(output, accessing: fixture.root) == nil, "different repository error rejected")
            let declinedRunner = ControlledOwnershipGit(base: fixture.runner)
            let declined = GitRepositoryModule(repositoryURL: repo, git: declinedRunner)
            var declinePreserved = false
            do {
                _ = try await RepositoryOwnershipRecovery.perform(
                    source: declined, decide: { _ in false }, operation: { try await declined.loadRepositoryState() })
            } catch let error as DubiousRepositoryOwnership { declinePreserved = error.output.contains("detected dubious ownership") }
            #expect(declinePreserved, "decline retains original failure")
            let declinedEntries = try await fixture.configEntries(in: repo)
            #expect(declinedEntries.isEmpty, "decline leaves global config untouched")
            let nested = repo.appendingPathComponent("nested folder", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            #expect(
                DubiousRepositoryOwnership.recognize(output, accessing: nested)?.repositoryURL.path == repo.path,
                "nested path resolves only to nearest proven repository root")
            let alias = fixture.root.appendingPathComponent("repo-alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repo)
            #expect(
                DubiousRepositoryOwnership.recognize(output, accessing: alias)?.repositoryURL.path == repo.path, "symlink access uses canonical approved root")
            let acceptedRunner = ControlledOwnershipGit(base: fixture.runner)
            let accepted = GitRepositoryModule(repositoryURL: repo, git: acceptedRunner)
            var decisions = 0
            let loaded = try await RepositoryOwnershipRecovery.perform(
                source: accepted,
                decide: { failure in
                    decisions += 1
                    return failure.repositoryURL.path == repo.path
                }, operation: { try await accepted.loadRepositoryState() })
            #expect(decisions == 1 && loaded.identity.currentRepository.path == repo.path, "trust retries initialization successfully")
            let entries = try await fixture.configEntries(in: repo)
            #expect(entries == [repo.path] && !entries.contains("*"), "only exact approved path trusted globally")
            let duplicate = GitRepositoryModule(repositoryURL: repo, git: ControlledOwnershipGit(base: fixture.runner))
            _ = try await RepositoryOwnershipRecovery.perform(
                source: duplicate, decide: { _ in true }, operation: { try await duplicate.loadRepositoryState() })
            let duplicateEntries = try await fixture.configEntries(in: repo)
            #expect(duplicateEntries == entries, "duplicate trust is idempotent")
            let nestedModule = GitRepositoryModule(repositoryURL: nested, git: ControlledOwnershipGit(base: fixture.runner, reportedURL: repo))
            _ = try await RepositoryOwnershipRecovery.perform(
                source: nestedModule, decide: { $0.repositoryURL.path == repo.path },
                operation: {
                    try await nestedModule.loadRepositoryState()
                })
            let nestedEntries = try await fixture.configEntries(in: repo)
            #expect(nestedEntries == entries, "nested open retries with exact root and no broad parent trust")
            let nestedRepository = try await fixture.repository("nested-repository")
            try FileManager.default.moveItem(at: nestedRepository, to: nested.appendingPathComponent("inner"))
            #expect(
                DubiousRepositoryOwnership.recognize(output, accessing: nested.appendingPathComponent("inner")) == nil,
                "nested repository boundary cannot approve outer repository")
            let other = try await fixture.repository("different")
            let mismatched = GitRepositoryModule(repositoryURL: repo, git: ControlledOwnershipGit(base: fixture.runner, reportedURL: other))
            var wrongDecisions = 0
            do {
                _ = try await RepositoryOwnershipRecovery.perform(
                    source: mismatched,
                    decide: { _ in
                        wrongDecisions += 1
                        return true
                    }, operation: { try await mismatched.loadRepositoryState() })
            } catch let error as GitError {
                #expect(error.localizedDescription.contains("detected dubious ownership"), "mismatched original security error preserved")
            }
            let wrongEntries = try await fixture.configEntries(in: repo)
            #expect(wrongDecisions == 0 && wrongEntries == entries, "different reported repository never reaches trust decision")
            let switched = GitRepositoryModule(repositoryURL: repo, git: ControlledOwnershipGit(base: fixture.runner))
            var old: DubiousRepositoryOwnership?
            do { _ = try await switched.loadRepositoryState() } catch let failure as DubiousRepositoryOwnership { old = failure }
            do { _ = try await switched.openRepository(at: other) } catch is DubiousRepositoryOwnership {}
            var rejected = false
            do { try await switched.trustRepository(old!) } catch { rejected = true }
            let switchedEntries = try await fixture.configEntries(in: other)
            #expect(rejected && switchedEntries == entries, "stale other-repository approval cannot change config")
        }

        private final class Fixture {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "GitExtensionsMac-RepositoryStatus-\(UUID().uuidString)", isDirectory: true
            ).resolvingSymlinksInPath()
            let runner: IsolatedGit
            init() throws {
                let home = root.appendingPathComponent("home", isDirectory: true)
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
                let config = home.appendingPathComponent(".gitconfig")
                try Data().write(to: config)
                runner = IsolatedGit(environment: [
                    "HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
                    "GIT_CONFIG_GLOBAL": config.path, "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_COUNT": "0",
                ])
            }
            func remove() { try? FileManager.default.removeItem(at: root) }
            func write(_ repo: URL, _ path: String, _ value: String) throws { try Data(value.utf8).write(to: repo.appendingPathComponent(path)) }
            func repository(_ name: String) async throws -> URL {
                let url = root.appendingPathComponent(name, isDirectory: true)
                try await git(["init", "-q", "-b", "main", url.path], in: root)
                for (key, value) in [
                    ("user.name", "Status Parity"), ("user.email", "status@example.com"), ("commit.gpgsign", "false"), ("core.autocrlf", "false"),
                ] {
                    try await git(["config", key, value], in: url)
                }
                try write(url, "tracked.txt", "base\n")
                try await git(["add", "."], in: url)
                try await git(["commit", "-qm", "base"], in: url)
                return url.standardizedFileURL
            }
            @discardableResult func git(_ arguments: [String], in directory: URL) async throws -> GitCommandResult {
                let result = try await runner.run(arguments: arguments, in: directory, standardInput: nil, environment: [:])
                #expect(result.succeeded, "git \(arguments) failed: \(result.standardErrorString)")
                return result
            }
            func configEntries(in directory: URL) async throws -> [String] {
                let result = try await runner.run(
                    arguments: ["config", "--global", "--get-all", "safe.directory"], in: directory, standardInput: nil, environment: [:])
                #expect(result.exitStatus == 0 || result.exitStatus == 1, "read global trust config")
                return result.standardOutputString.split(separator: "\n").map(String.init)
            }
        }

        private struct IsolatedGit: GitCommandRunning {
            let environment: [String: String]
            func run(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String]) async throws -> GitCommandResult {
                try await GitProcess().run(
                    arguments: arguments, in: directory, standardInput: standardInput, environment: self.environment.merging(environment) { _, new in new })
            }
            func runStreaming(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String], output: @escaping GitOutputHandler)
                async throws -> GitCommandResult
            {
                try await GitProcess().runStreaming(
                    arguments: arguments, in: directory, standardInput: standardInput, environment: self.environment.merging(environment) { _, new in new },
                    output: output)
            }
        }

        private actor ControlledOwnershipGit: GitCommandRunning {
            let base: IsolatedGit
            let reportedURL: URL?
            var failed: Set<URL> = []
            init(base: IsolatedGit, reportedURL: URL? = nil) {
                self.base = base
                self.reportedURL = reportedURL
            }
            func run(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String]) async throws -> GitCommandResult {
                if arguments.suffix(2) == ["rev-parse", "--absolute-git-dir"], failed.insert(directory).inserted {
                    let path = reportedURL?.path ?? directory.path
                    return GitCommandResult(
                        arguments: arguments, standardOutput: Data(),
                        standardError: Data(
                            "fatal: detected dubious ownership in repository at '\(path)'\ngit config --global --add safe.directory '\(path)'\n".utf8),
                        exitStatus: 128, executionClass: .local)
                }
                return try await base.run(arguments: arguments, in: directory, standardInput: standardInput, environment: environment)
            }
            func runStreaming(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String], output: @escaping GitOutputHandler)
                async throws -> GitCommandResult
            {
                try await base.runStreaming(arguments: arguments, in: directory, standardInput: standardInput, environment: environment, output: output)
            }
        }
    }
}

typealias RepositoryStatusTests = UIIntegrationTests.RepositoryStatusTests
