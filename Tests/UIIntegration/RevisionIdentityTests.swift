import AppKit
import Foundation
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("Revision identity")
    enum RevisionIdentityTests {
        private struct Failure: LocalizedError { let errorDescription: String? }

        private static func commit(email: String) -> Commit {
            Commit(
                id: testRevisionID(email), shortID: "12345678", subject: "author", body: "", authorName: "Author",
                authorEmail: email, authorDate: .distantPast, committerName: "", committerEmail: "", commitDate: .distantPast,
                parentIDs: [], references: [])
        }

        @Test("Author vectors") private static func authorVectors() throws {
            let first = commit(email: "doe1@example.org")
            let second = commit(email: "doe2@example.org")
            var state = AuthorRevisionHighlighting()
            #expect(state.authorEmailToHighlight == nil, "upstream initial highlight is nil")
            do {
                let actual = !state.processSelection([first, first], currentUserEmail: second.authorEmail)
                #expect(actual, "initial multi-selection does not refresh")
            }
            #expect(state.authorEmailToHighlight == nil, "initial multi-selection keeps nil")
            do {
                let actual = state.processSelection([first], currentUserEmail: nil)
                #expect(actual, "first selection refreshes")
            }
            #expect(state.authorEmailToHighlight == first.authorEmail, "single selected author")
            do {
                let actual = !state.processSelection([first], currentUserEmail: nil)
                #expect(actual, "same author does not refresh")
            }
            do {
                let actual = !state.processSelection([commit(email: first.authorEmail.uppercased())], currentUserEmail: nil)
                #expect(actual, "same author case ignored")
            }
            do {
                let actual = !state.processSelection([second, first], currentUserEmail: nil)
                #expect(actual, "multi-selection does not refresh")
            }
            #expect(state.authorEmailToHighlight == first.authorEmail, "multi-selection retains prior author")
            do {
                let actual = state.processSelection([second], currentUserEmail: nil)
                #expect(actual, "different author refreshes")
            }
            #expect(state.authorEmailToHighlight == second.authorEmail, "different single selected author")
            do {
                let actual = state.processSelection([], currentUserEmail: first.authorEmail)
                #expect(actual, "clearing selection refreshes")
            }
            #expect(state.authorEmailToHighlight == first.authorEmail, "empty selection falls back to current user")
            #expect(!state.isHighlighted(nil), "null revision is not highlighted")
            for email in ["", "\t", " \n"] { #expect(!state.isHighlighted(commit(email: email)), "blank author never highlighted") }
            for (email, highlight, expected) in [
                ("a@a.aaa", "a@a.aaa", true), ("A@A.aaa", "a@a.aaa", true),
                ("b@A.aaa", "a@a.aaa", false), ("a@a.aaa", "", false), ("a@a.aaa", "\t", false),
            ] {
                state = AuthorRevisionHighlighting()
                _ = state.processSelection([commit(email: highlight)], currentUserEmail: nil)
                #expect(state.isHighlighted(commit(email: email)) == expected, "upstream IsHighlighted vector")
            }
            state = AuthorRevisionHighlighting()
            #expect(!state.isHighlighted(commit(email: "a@a.aaa")), "nil highlight does not match")
            state.updateCurrentUser(first.authorEmail, selected: [])
            #expect(state.isHighlighted(first), "repository identity supplies initial current user")
            state.updateCurrentUser(second.authorEmail, selected: [])
            #expect(state.isHighlighted(second) && !state.isHighlighted(first), "repository/config fallback changes")
            _ = state.processSelection([first], currentUserEmail: nil)
            #expect(
                state.processSelection([], currentUserEmail: nil) && state.authorEmailToHighlight == nil, "clearing prior highlight without configured email")
            state.updateCurrentUser(nil, selected: [])
            #expect(state.authorEmailToHighlight == nil, "unavailable current user clears fallback")
        }

        @Test("Settings vectors") private static func settingsVectors() throws {
            #expect(RevisionReadOptions().maxStashesWithUntrackedFiles == 10, "upstream reader default stash maximum")
            let defaults = try JSONDecoder().decode(RevisionGridPreferences.self, from: Data("{}".utf8))
            #expect(defaults.maxStashesWithUntrackedFiles == 10, "old settings retain upstream maximum default")
            var preferences = defaults
            preferences.maxStashesWithUntrackedFiles = 2
            let decoded = try JSONDecoder().decode(RevisionGridPreferences.self, from: JSONEncoder().encode(preferences))
            #expect(decoded.maxStashesWithUntrackedFiles == 2, "maximum persists")
        }

        @Test("Stash scenarios") private static func stashScenarios() async throws {
            let f = try Fixture()
            defer { f.remove() }
            let repo = try await f.repository("stash")
            try f.write(repo, "tracked.txt", "normal stash\n")
            try await f.git(["stash", "push", "-qm", "ordinary"], in: repo)
            for index in 0..<13 {
                try f.write(repo, "untracked-\(index).txt", "new \(index)\n")
                try await f.git(["stash", "push", "-u", "-qm", "untracked \(index)"], in: repo)
            }
            try f.write(repo, "tracked.txt", "empty third-parent\n")
            try await f.git(["stash", "push", "-u", "-qm", "empty untracked"], in: repo)
            let module = GitRepositoryModule(repositoryURL: repo, git: f.runner)
            let state = try await module.loadRepositoryState()
            let stashes = state.revisionReadRequest.context.stashes
            #expect(stashes.count == 15 && stashes.last?.parentIDs.count == 2, "ordinary stash keeps its two original parents")
            #expect(stashes.prefix(14).allSatisfy { $0.parentIDs.count == 3 }, "all untracked third-parent identities preserved")
            for stash in stashes {
                let parents = try await f.git(["rev-list", "--parents", "-n", "1", stash.objectID.string], in: repo).standardOutputString
                #expect(
                    parents.split(whereSeparator: \.isWhitespace).dropFirst().map(String.init) == stash.parentIDs.map(\.string),
                    "parent IDs match real rev-list")
            }
            var options = RevisionReadOptions()
            options.showArtificialCommits = false
            options.filter.setBranchFilter("main")
            let revisions = try await f.read(state, options: options)
            let candidates = Array(stashes.filter { $0.parentIDs.count >= 3 }.prefix(10))
            var expected = Set<ObjectID>()
            for stash in candidates {
                let tree = try await f.git(["ls-tree", stash.parentIDs[2].string], in: repo)
                if !tree.standardOutput.isEmpty { expected.insert(stash.parentIDs[2]) }
            }
            #expect(expected.count == 9, "empty third-parent consumes one of ten candidate slots")
            #expect(
                Set(revisions.compactMap(\.objectID)).intersection(Set(stashes.filter { $0.parentIDs.count == 3 }.map { $0.parentIDs[2] }))
                    == expected.union([stashes[0].parentIDs[2]]),
                "maximum and empty-tree exclusion match upstream; latest stash third-parent already in normal history")
            for stash in stashes {
                let index = revisions.firstIndex { $0.objectID == stash.objectID }!
                let revision = revisions[index]
                let included = stash.parentIDs.count == 3 && expected.contains(stash.parentIDs[2])
                #expect(
                    revision.parentIDs
                        == (stash.objectID == stashes[0].objectID ? stash.parentIDs : [stash.parentIDs[0]] + (included ? [stash.parentIDs[2]] : [])),
                    "inserted stash omits index parent and excluded untracked parent")
                #expect(revision.isStash && !revision.isAutostash && !revision.isArtificial, "normal stash classification")
                if included {
                    let untracked = revisions[index + 1]
                    #expect(untracked.objectID == stash.parentIDs[2] && untracked.parentIDs.isEmpty, "third-parent node follows stash with its root topology")
                    #expect(!untracked.isStashLike && !untracked.isArtificial, "untracked node remains a real history commit")
                    let raw = try await f.git(["cat-file", "-p", stash.parentIDs[2].string], in: repo)
                    #expect(raw.standardOutputString.contains(untracked.subject), "untracked subject comes from actual object")
                    let timestamp = try await f.git(["show", "-s", "--format=%at", stash.parentIDs[2].string], in: repo)
                    #expect(
                        untracked.authorDate.timeIntervalSince1970 == Double(timestamp.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)),
                        "actual untracked commit date")
                }
                let baseIndex = revisions.firstIndex { $0.objectID == stash.parentIDs[0] }!
                #expect(index < baseIndex, "stash precedes its base revision")
            }
            let graph = RevisionGraphLayout.build(commits: revisions)
            for revision in revisions { #expect(graph.parentIDs[revision.id] == revision.graphParentIDs, "graph retains stash and untracked topology") }
            options.maxStashesWithUntrackedFiles = 2
            let limited = try await f.read(state, options: options)
            #expect(limited.count == stashes.count + 4, "two candidates produce one nonempty untracked node plus base")
            options.maxStashesWithUntrackedFiles = 100
            let unlimited = try await f.read(state, options: options)
            #expect(unlimited.count == stashes.count + 16, "maximum larger than stash count includes all thirteen nonempty supplemental roots")
            options.maxStashesWithUntrackedFiles = 0
            let zero = try await f.read(state, options: options)
            #expect(zero.count == stashes.count + 3, "zero maximum adds no untracked nodes")
            options.showStashes = false
            let hidden = try await f.read(state, options: options)
            #expect(hidden.count == 1 && !hidden.contains { $0.isStashLike }, "hidden stashes do not insert supplemental revisions")
            options = RevisionReadOptions()
            options.showArtificialCommits = false
            options.filter.showReflogReferences = true
            let reflog = try await f.read(state, options: options)
            #expect(Set(reflog.map(\.id)).count == reflog.count, "reflog does not duplicate inserted untracked revisions")
            #expect(
                reflog.filter(\.isStash).allSatisfy { revision in stashes.first { $0.objectID == revision.objectID }?.parentIDs == revision.parentIDs },
                "reflog keeps actual stash graph parents")
            try await f.git(["stash", "drop", "-q", "stash@{0}"], in: repo)
            let refreshed = try await module.loadRepositoryState()
            options.filter.setBranchFilter("main")
            options.filter.showReflogReferences = false
            let afterDrop = try await f.read(refreshed, options: options)
            #expect(!afterDrop.contains { $0.objectID == stashes[0].objectID }, "dropped stash disappears on shared refresh")
            try f.write(repo, "fresh.txt", "fresh\n")
            try await f.git(["stash", "push", "-u", "-qm", "fresh"], in: repo)
            let afterCreateState = try await module.loadRepositoryState()
            let afterCreate = try await f.read(afterCreateState, options: options)
            let newStash = afterCreateState.revisionReadRequest.context.stashes[0]
            #expect(afterCreate.contains { $0.objectID == newStash.parentIDs[2] }, "new stash third-parent appears on shared refresh")
            try await f.git(["checkout", "-qb", "topic"], in: repo)
            try f.write(repo, "topic.txt", "topic\n")
            try await f.git(["add", "."], in: repo)
            try await f.git(["commit", "-qm", "topic"], in: repo)
            try await f.git(["checkout", "-q", "main"], in: repo)
            try await f.git(["merge", "--no-ff", "-qm", "ordinary merge", "topic"], in: repo)
            let mergeID = try await f.object(repo, "HEAD")
            let mergeState = try await module.loadRepositoryState()
            let merged = try await f.read(mergeState, options: options)
            #expect(merged.first { $0.objectID == mergeID }.map { $0.isMerge && !$0.isStashLike } == true, "ordinary merge is not misclassified")
            let sharedRepo = try await f.repository("shared-untracked-object")
            for index in 0..<3 {
                try f.write(sharedRepo, "shared-new.txt", "identical untracked content\n")
                try f.write(sharedRepo, "tracked.txt", "different tracked change \(index)\n")
                let saved = try await f.runner.run(
                    arguments: ["stash", "push", "-u", "-qm", "shared \(index)"], in: sharedRepo,
                    standardInput: nil, environment: ["GIT_AUTHOR_DATE": "1700000000 +0000", "GIT_COMMITTER_DATE": "1700000000 +0000"])
                #expect(saved.succeeded, "save deterministic shared untracked root")
            }
            try f.write(sharedRepo, "tracked.txt", "latest ordinary stash\n")
            try await f.git(["stash", "push", "-qm", "ordinary latest"], in: sharedRepo)
            let sharedModule = GitRepositoryModule(repositoryURL: sharedRepo, git: f.runner)
            let sharedState = try await sharedModule.loadRepositoryState()
            let sharedStashes = sharedState.revisionReadRequest.context.stashes.filter { $0.parentIDs.count == 3 }
            let sharedID = sharedStashes[0].parentIDs[2]
            #expect(sharedStashes.count == 3 && Set(sharedStashes.map { $0.parentIDs[2] }).count == 1, "real Git produces shared untracked root identity")
            let sharedRevisions = try await f.read(sharedState, options: options)
            #expect(
                sharedRevisions.filter { $0.objectID == sharedID }.count == 1 && Set(sharedRevisions.map(\.id)).count == sharedRevisions.count,
                "shared untracked root displayed once without duplicate graph identities")
            let sharedGraph = RevisionGraphLayout.build(commits: sharedRevisions)
            for stash in sharedStashes {
                #expect(sharedGraph.parentIDs[.object(stash.objectID)]?.contains(.object(sharedID)) == true, "each stash keeps shared-root graph edge")
            }

        }

        @Test("Autostash scenarios") private static func autostashScenarios() async throws {
            let f = try Fixture()
            defer { f.remove() }
            let repo = try await f.repository("autostash")
            let module = GitRepositoryModule(repositoryURL: repo, git: f.runner)
            #expect(try await module.loadRepositoryState().revisionReadRequest.context.autostash == nil, "no rebase has no autostash")
            let base = try await f.object(repo, "HEAD")
            try f.write(repo, "tracked.txt", "saved change\n")
            try await f.git(["stash", "push", "-qm", "saved"], in: repo)
            let stashID = try await f.object(repo, "refs/stash")
            let metadata = repo.appendingPathComponent(".git/rebase-merge", isDirectory: true)
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
            #expect(try await module.loadRepositoryState().revisionReadRequest.context.autostash == nil, "rebase without autostash")
            try f.write(metadata, "autostash", stashID.string + "\n")
            try f.write(metadata, "orig-head", base.string + "\n")
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: metadata.appendingPathComponent("autostash").path)
            let state = try await module.loadRepositoryState()
            var options = RevisionReadOptions()
            options.showArtificialCommits = false
            let revisions = try await f.read(state, options: options)
            let autostash = revisions.first!
            #expect(
                autostash.objectID == stashID && autostash.isAutostash && !autostash.isStash && !autostash.isArtificial,
                "upstream Autostash identity and independent type")
            #expect(autostash.subject == "Autostash" && autostash.parentIDs == [base], "Autostash subject and orig-head graph parent")
            #expect(
                autostash.authorDate == date && autostash.commitDate == date && autostash.authorEmail.isEmpty && autostash.committerName.isEmpty,
                "file mtime and blank author metadata")
            #expect(!autostash.loadsCommitInfo && autostash.isStashLike, "CommitInfo preserves synthetic subject without loading normal commit metadata")
            let menu = RevisionContextMenuBuilder.build(
                RevisionContextMenuContext(focusedCommit: autostash, selectedCommits: [autostash], history: revisions, currentBranchName: "main"))
            #expect(
                menu.entry(id: "revision.stash.apply")?.isEnabled == true && menu.entry(id: "revision.stash.pop") == nil
                    && menu.entry(id: "revision.stash.drop") == nil, "only Apply is enabled among Autostash stash actions")
            let graph = RevisionGraphLayout.build(commits: revisions)
            #expect(
                graph.rows.first?.commitID == autostash.id && graph.parentIDs[autostash.id] == [.object(base)],
                "Autostash participates in graph with original-head parent")
            #expect(Set(revisions.map(\.id)).count == revisions.count, "Autostash object reachable in history is not duplicated")
            let details = try await module.loadRevisionDetails(for: autostash)
            #expect(details.files.contains { $0.path == "tracked.txt" }, "Autostash details use stash-like diff")
            options.showStashes = false
            #expect(!(try await f.read(state, options: options)).contains { $0.isAutostash }, "hidden stashes hide Autostash")
            try FileManager.default.removeItem(at: metadata.appendingPathComponent("orig-head"))
            #expect(
                try await module.loadRepositoryState().revisionReadRequest.context.autostash?.parentIDs.isEmpty == true,
                "missing orig-head keeps safe parentless Autostash")
            try f.write(metadata, "orig-head", "not an object")
            #expect(
                try await module.loadRepositoryState().revisionReadRequest.context.autostash?.parentIDs.isEmpty == true,
                "malformed orig-head keeps safe parentless Autostash")
            try f.write(metadata, "autostash", "not an object")
            #expect(try await module.loadRepositoryState().revisionReadRequest.context.autostash == nil, "malformed Autostash is skipped")
            try FileManager.default.removeItem(at: metadata)
            _ = try await module.applyStash(Stash(id: stashID.string, selector: stashID.string, subject: "Autostash", branchName: "", commitID: stashID))
            #expect(try String(contentsOf: repo.appendingPathComponent("tracked.txt")) == "saved change\n", "Apply supports autostash object-ID selector")
            try await f.git(["reset", "--hard", "-q"], in: repo)
            try await f.git(["checkout", "-qb", "topic"], in: repo)
            try f.write(repo, "tracked.txt", "topic conflict\n")
            try f.write(repo, "extra.txt", "clean\n")
            try await f.git(["add", "."], in: repo)
            try await f.git(["commit", "-qm", "topic"], in: repo)
            let originalHead = try await f.object(repo, "HEAD")
            try await f.git(["checkout", "-q", "main"], in: repo)
            try f.write(repo, "tracked.txt", "main conflict\n")
            try await f.git(["commit", "-qam", "main"], in: repo)
            try await f.git(["checkout", "-q", "topic"], in: repo)
            try f.write(repo, "extra.txt", "dirty extra\n")
            let rebase = try await f.runner.run(arguments: ["rebase", "--autostash", "main"], in: repo, standardInput: nil, environment: [:])
            #expect(!rebase.succeeded, "real rebase stops on deterministic conflict")
            let active = try await module.loadRepositoryState()
            let actual = active.revisionReadRequest.context.autostash!
            let metadataID = try String(contentsOf: metadata.appendingPathComponent("autostash")).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(actual.objectID?.string == metadataID && actual.parentIDs == [originalHead], "real rebase Autostash ID and original head")
            #expect(try await module.loadRebaseState().hasAutoStash, "existing rebase state shares Autostash reader")
            try await f.git(["rebase", "--abort"], in: repo)
            #expect(try await module.loadRepositoryState().revisionReadRequest.context.autostash == nil, "abort removes Autostash naturally")
            #expect(try String(contentsOf: repo.appendingPathComponent("extra.txt")) == "dirty extra\n", "real abort reapplies autostash")
            try await f.git(["reset", "--hard", "-q"], in: repo)
            let without = try await f.runner.run(arguments: ["rebase", "main"], in: repo, standardInput: nil, environment: [:])
            let withoutState = try await module.loadRepositoryState()
            #expect(!without.succeeded && withoutState.revisionReadRequest.context.autostash == nil, "real active rebase without autostash")
            try await f.git(["rebase", "--abort"], in: repo)
            try f.write(repo, "extra.txt", "dirty for completion\n")
            let completing = try await f.runner.run(arguments: ["rebase", "--autostash", "main"], in: repo, standardInput: nil, environment: [:])
            #expect(!completing.succeeded, "completion fixture stops with Autostash")
            try f.write(repo, "tracked.txt", "resolved conflict\n")
            try await f.git(["add", "tracked.txt"], in: repo)
            let completed = try await f.runner.run(arguments: ["rebase", "--continue"], in: repo, standardInput: nil, environment: ["GIT_EDITOR": "true"])
            #expect(completed.succeeded, "real rebase completes after resolving conflict")
            let completedState = try await module.loadRepositoryState()
            #expect(completedState.revisionReadRequest.context.autostash == nil, "completion removes Autostash revision")
            #expect(try String(contentsOf: repo.appendingPathComponent("extra.txt")) == "dirty for completion\n", "completion reapplies saved worktree")
        }

        @Test("Tracking scenarios") private static func trackingScenarios() async throws {
            let f = try Fixture()
            defer { f.remove() }
            let repo = try await f.repository("refs")
            let module = GitRepositoryModule(repositoryURL: repo, git: f.runner)
            let base = try await f.object(repo, "HEAD")
            try await f.git(["remote", "add", "origin", "/unused"], in: repo)
            try await f.git(["remote", "add", "other", "/unused-other"], in: repo)
            for ref in [
                "refs/remotes/origin/main", "refs/remotes/origin/different/name", "refs/remotes/other/main", "refs/heads/origin/main", "refs/heads/zz-local",
                "refs/tags/marker",
            ] {
                try await f.git(["update-ref", ref, base.string], in: repo)
            }
            try f.write(repo, "tracked.txt", "ahead\n")
            try await f.git(["commit", "-qam", "ahead"], in: repo)
            let head = try await f.object(repo, "HEAD")
            try await f.git(["branch", "--set-upstream-to=refs/remotes/origin/main", "main"], in: repo)
            var state = try await module.loadRepositoryState()
            var marked = state.references.references.filter(\.isSelectedHeadMergeSource)
            #expect(marked.map(\.id) == ["refs/remotes/origin/main"], "only actual tracked remote marked")
            #expect(
                state.references.referencesByCommit[base]?.contains { $0.isSelectedHeadMergeSource } == true && head != base,
                "marker applies on different commit")
            let local = state.references.branches.first { $0.isCurrent }!
            let remote = state.navigation.remotes.first { $0.name == "origin" }!.branches.first { $0.name == "main" }!
            #expect(TrackingBranchNavigation.target(branch: local, data: state.aheadBehind, alternate: false) == local.id, "normal click selects own ref")
            #expect(
                TrackingBranchNavigation.target(branch: local, data: state.aheadBehind, alternate: true) == remote.id, "Alt local navigates tracking remote")
            #expect(
                TrackingBranchNavigation.target(branch: remote, data: state.aheadBehind, alternate: true) == local.id, "Alt remote navigates tracking local")
            let grid = RevisionGridViewController()
            _ = grid.view
            grid.dataSource = module
            var options = RevisionReadOptions()
            options.showArtificialCommits = false
            let history = try await f.read(state, options: options)
            grid.apply(commits: history, preferredCommitID: .object(head))
            try await wait("grid initial selection") { grid.selectedRevisionIDs == [.object(head)] }
            let target = TrackingBranchNavigation.target(branch: local, data: state.aheadBehind, alternate: true)
            grid.goToRef(target, showNoRevisionMessage: true)
            try await wait("tracking grid navigation") { grid.selectedRevisionIDs == [.object(base)] }
            grid.apply(commits: history.filter { $0.objectID != base }, preferredCommitID: .object(head))
            try await wait("filtered grid initial selection") { grid.selectedRevisionIDs == [.object(head)] }
            let originalMessage = RevisionGridMessages.present
            var filteredMessage = ""
            RevisionGridMessages.present = { message, _ in filteredMessage = message }
            defer { RevisionGridMessages.present = originalMessage }
            grid.goToRef(target, showNoRevisionMessage: true)
            try await wait("filtered tracking target message") { !filteredMessage.isEmpty }
            #expect(
                filteredMessage.contains("not visible") && grid.selectedRevisionIDs == [.object(head)],
                "filtered tracking target retains selection and reports visibility")
            #expect(TrackingBranchNavigation.canNavigate(visible: false, alternate: true), "Alt can navigate from a filtered branch to its counterpart")
            #expect(!TrackingBranchNavigation.canNavigate(visible: false, alternate: false), "ordinary filtered branch handling retained")
            #expect(await module.resolveRevision(target) == base, "tracking navigation selects expected revision")
            #expect(try await f.object(repo, "HEAD") == head, "navigation does not checkout")
            var preferences = RepositoryTreePreferences()
            preferences.prioritizedBranchNames = "zz-local"
            preferences.prioritizedRemoteNames = "other"
            let roots = RepositoryTreeBuilder.build(references: state.references, navigation: state.navigation, preferences: preferences)
            let locals = roots.first { $0.title == "Branches" }!
            #expect(locals.children.first?.title == "zz-local", "existing branch priority remains respected")
            let remotes = roots.first { $0.title == "Remotes" }!
            #expect(remotes.children.first?.title == "other", "existing remote priority remains respected")
            let all = state.references.references
            let sorted = RevisionGridPresentation.sortedReferences(all)
            #expect(sorted.first?.kind == .currentBranch && sorted.dropFirst().first?.id == remote.id, "tracked branch follows current before other locals")
            #expect(
                sorted.firstIndex { $0.id == "refs/heads/zz-local" }! < sorted.firstIndex { $0.id == "refs/remotes/other/main" }!,
                "unrelated remotes retain normal rank")
            #expect(!all.first { $0.id == "refs/heads/origin/main" }!.isSelectedHeadMergeSource, "same short-name local does not receive marker")
            try await f.git(["branch", "--set-upstream-to=origin/different/name", "main"], in: repo)
            state = try await module.loadRepositoryState()
            #expect(
                state.references.references.filter(\.isSelectedHeadMergeSource).map(\.id) == ["refs/remotes/origin/different/name"],
                "differently named slash upstream recomputed")
            #expect(
                TrackingBranchNavigation.target(branch: local, data: state.aheadBehind, alternate: true) == "refs/remotes/origin/different/name",
                "slash tracking target preserved")
            let slashRemote = state.navigation.remotes.first { $0.name == "origin" }!.branches.first { $0.name == "different/name" }!
            #expect(
                TrackingBranchNavigation.target(branch: slashRemote, data: state.aheadBehind, alternate: true) == local.id,
                "slash remote navigates back to differently named local")
            let unrelated = state.navigation.remotes.first { $0.name == "other" }!.branches.first!
            #expect(
                TrackingBranchNavigation.target(branch: unrelated, data: state.aheadBehind, alternate: true) == unrelated.id,
                "unrelated remote falls back to own branch")
            try await f.git(["update-ref", "-d", "refs/remotes/origin/different/name"], in: repo)
            state = try await module.loadRepositoryState()
            #expect(state.references.references.allSatisfy { !$0.isSelectedHeadMergeSource }, "gone upstream has no stale marker")
            #expect(
                TrackingBranchNavigation.target(branch: local, data: state.aheadBehind, alternate: true) == "refs/remotes/origin/different/name",
                "gone related ref still navigated as upstream does")
            #expect(await module.resolveRevision("refs/remotes/origin/different/name") == nil, "gone target does not select wrong branch")
            try await f.git(["branch", "--unset-upstream", "main"], in: repo)
            state = try await module.loadRepositoryState()
            #expect(
                TrackingBranchNavigation.target(branch: local, data: state.aheadBehind, alternate: true) == local.id, "no upstream Alt falls back to own branch"
            )
            #expect(state.references.references.allSatisfy { !$0.isSelectedHeadMergeSource }, "no upstream marker")
            try await f.git(["checkout", "-qb", "alternate"], in: repo)
            try await f.git(["branch", "--set-upstream-to=other/main", "alternate"], in: repo)
            state = try await module.loadRepositoryState()
            marked = state.references.references.filter(\.isSelectedHeadMergeSource)
            #expect(marked.map(\.id) == ["refs/remotes/other/main"], "branch switch recomputes tracking relationship")
            try await f.git(["checkout", "--detach", "-q", head.string], in: repo)
            state = try await module.loadRepositoryState()
            #expect(state.references.references.allSatisfy { !$0.isSelectedHeadMergeSource }, "detached HEAD has no tracked marker")
            try await f.git(["config", "user.email", "changed@example.org"], in: repo)
            state = try await module.loadRepositoryState()
            #expect(state.identity.userEmail == "changed@example.org", "shared identity rereads external config change")
            let other = try await f.repository("other-email")
            try await f.git(["config", "user.email", "other@example.org"], in: other)
            let switched = try await module.openRepository(at: other)
            #expect(switched.identity.userEmail == "other@example.org", "repository switch does not cache user email")
            try await f.git(["config", "--unset", "user.email"], in: other)
            #expect(try await module.loadRepositoryState().identity.userEmail == nil, "missing effective email safe")
        }

        private static func wait(_ message: String, until condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition() {
                #expect(ContinuousClock.now < deadline, Comment(rawValue: message))
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        private final class Fixture {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "GitExtensionsMac-RevisionIdentity-\(UUID().uuidString)", isDirectory: true
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
                    ("user.name", "Revision Parity"), ("user.email", "revision@example.org"), ("commit.gpgsign", "false"), ("core.autocrlf", "false"),
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
            func object(_ repo: URL, _ expression: String) async throws -> ObjectID {
                try ObjectID.parse(try await git(["rev-parse", expression], in: repo).standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            func read(_ state: RepositoryLoadState, options: RevisionReadOptions) async throws -> [Commit] {
                var commits: [Commit] = []
                for try await batch in await state.revisionReadRequest.reader.read(state.revisionReadRequest.context.with(options)) { commits += batch }
                return commits
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
    }
}

typealias RevisionIdentityTests = UIIntegrationTests.RevisionIdentityTests
