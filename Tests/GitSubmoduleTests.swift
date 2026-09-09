@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import Foundation
import AppKit

enum GitSubmoduleTests {
    static func run() async throws {
        let request = RepositoryAddSubmoduleRequest(source: "../remote.git", path: "deps/space é", branch: " main ", force: true)
        try require(GitSubmoduleCommands.add(request).arguments == ["submodule", "add", "-f", "-b", "main", "../remote.git", "deps/space é"], "add argument order")
        try require(GitSubmoduleCommands.update(path: nil).arguments == ["submodule", "update", "--init", "--recursive"], "update includes recursive init")
        try require(GitSubmoduleCommands.synchronize(path: "deps/a").arguments == ["submodule", "sync", "deps/a"], "sync is nonrecursive upstream")
        try require(!GitSubmoduleCommands.synchronize(path: nil).accessesRemote && GitSubmoduleCommands.update(path: nil).accessesRemote, "metadata")
        try require(GitSubmoduleCommands.directoryName(from: "git@example.com:project.git") == "project", "source name")
        try require(GitSubmoduleCommands.branches(from: "warning: text\nabc\trefs/heads/topic/a\nxyz\trefs/heads/main\n") == ["topic/a", "main"], "remote branch parsing")
        let fixture = try SubmoduleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: LocalSubmoduleRunner())
        _ = try await module.loadRepositoryState()
        let empty = try await module.loadSubmoduleContext()
        try require(empty.submodules.isEmpty, "empty repository")
        let invalid = try await module.addSubmodule(.init(source: "../nonexistent", path: "invalid"), output: { _ in })
        try require(!invalid.succeeded && !invalid.changed, "invalid source has no repository changes")
        let noop = try await module.performSubmoduleAction(.update(path: nil), output: { _ in })
        try require(noop.succeeded && !noop.changed, "empty update is not a mutation")
        let path = "deps/space é"
        let added = try await module.addSubmodule(.init(source: "../child", path: path, branch: "main"), output: { _ in })
        try require(added.succeeded && added.changed, "add: \(added.output)")
        let head = try fixture.git(["rev-parse", "HEAD"], in: fixture.child)
        try require(try fixture.git(["config", "-f", ".gitmodules", "--get", "submodule.\(path).url"]) == "../child", "relative URL preserved")
        try require(try fixture.git(["config", "-f", ".gitmodules", "--get", "submodule.\(path).branch"]) == "main", "branch persisted")
        try require(try fixture.git(["ls-files", "--stage", "--", path]).hasPrefix("160000 \(head) 0"), "index gitlink target")
        let state = try await module.loadRepositoryState()
        try require(state.navigation.submodules.first?.commitID?.string == head, "notifier reload receives typed child HEAD")
        let duplicate = try await module.addSubmodule(.init(source: "../child", path: path), output: { _ in })
        try require(!duplicate.succeeded && !duplicate.changed, "occupied path must not mutate")
        do { _ = try await module.addSubmodule(.init(source: "../child", path: "../escape"), output: { _ in }); throw SubmoduleFailure("outside path accepted") } catch is RepositorySubmoduleError {}
        do { _ = try await module.performSubmoduleAction(.update(path: "missing"), output: { _ in }); throw SubmoduleFailure("missing path accepted") } catch is RepositorySubmoduleError {}
        _ = try fixture.git(["commit", "-am", "Add child"])
        let childPath = fixture.repo.appendingPathComponent(path)
        try Data("dirty\n".utf8).write(to: childPath.appendingPathComponent("file.txt"))
        let dirtyUpdate = try await module.performSubmoduleAction(.update(path: path), output: { _ in })
        try require(dirtyUpdate.succeeded && !dirtyUpdate.changed, "update same HEAD does not overwrite dirty child")
        try require(try String(contentsOf: childPath.appendingPathComponent("file.txt"), encoding: .utf8) == "dirty\n", "dirty child preserved")
        _ = try fixture.git(["checkout", "--", "file.txt"], in: childPath)
        _ = try fixture.git(["submodule", "deinit", "--", path])
        let uninitialized = try await module.loadSubmoduleContext()
        try require(uninitialized.submodules.first?.state == .uninitialized, "external deinit detected")
        let initialized = try await module.performSubmoduleAction(.update(path: path), output: { _ in })
        try require(initialized.succeeded && initialized.changed, "recursive init: \(initialized.output)")
        try require(FileManager.default.fileExists(atPath: childPath.appendingPathComponent("file.txt").path), "initialized checkout")
        _ = try fixture.git(["config", "--local", "submodule.\(path).url", "wrong"])
        let synchronized = try await module.performSubmoduleAction(.synchronize(path: path), output: { _ in })
        try require(synchronized.succeeded && synchronized.changed, "sync repairs config")
        try require(try fixture.git(["config", "--get", "submodule.\(path).url"]).hasSuffix("/child"), "relative URL resolved for local config")
        let syncNoop = try await module.performSubmoduleAction(.synchronize(path: nil), output: { _ in })
        try require(syncNoop.succeeded && !syncNoop.changed, "unchanged sync does not notify")
        let removed = try await module.performSubmoduleAction(.remove(path: path), output: { _ in })
        try require(removed.succeeded && removed.changed, "remove: \(removed.output)")
        try require(try fixture.git(["ls-files", "--", path, ".gitmodules"]).isEmpty, "last removal untracks gitlink and .gitmodules")
        try require(FileManager.default.fileExists(atPath: childPath.appendingPathComponent("file.txt").path), "removal retains checkout")
        let after = try await module.loadSubmoduleContext()
        try require(after.submodules.isEmpty, "stale on-disk .gitmodules does not leave stale nodes")
        try await nestedAndPartialChanges()
        try await gitlinkConflict()
        try await navigationAndCommitState()
        try await openingSelectionAfterGridReload()
        try await notifications()
        let bare = fixture.root.appendingPathComponent("bare.git")
        _ = try fixture.git(["init", "--bare", bare.path])
        let bareModule = GitRepositoryModule(repositoryURL: bare, git: LocalSubmoduleRunner())
        _ = try await bareModule.loadRepositoryState()
        do { _ = try await bareModule.loadSubmoduleContext(); throw SubmoduleFailure("bare management accepted") } catch is RepositoryMutationError {}
        print("GitSubmoduleTests passed")
    }

    @MainActor private static func openingSelectionAfterGridReload() async throws {
        _ = NSApplication.shared
        let source = MockRepositoryDataSource()
        let state = try await source.loadRepositoryState()
        var commits: [Commit] = []
        for try await batch in await state.revisionReadRequest.reader.read(state.revisionReadRequest.context) { commits += batch }
        let requested = [commits.first!.id, commits.last!.id]
        let grid = RevisionGridViewController()
        _ = grid.view
        grid.beginIncrementalLoad(preferredCommitID: requested[0])
        grid.appendIncrementalBatch(commits)
        grid.selectCommits(ids: requested)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while Set(grid.selectedRevisionIDs) != Set(requested) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(Set(grid.selectedRevisionIDs) == Set(requested), "opening selection survives asynchronous grid layout publication")
    }

    private static func navigationAndCommitState() async throws {
        let fixture = try SubmoduleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let leaf = fixture.root.appendingPathComponent("leaf")
        _ = try fixture.git(["clone", fixture.child.path, leaf.path], in: fixture.root)
        _ = try fixture.git(["submodule", "add", "../leaf", "nested/leaf"], in: fixture.child)
        _ = try fixture.git(["commit", "-am", "Nested"], in: fixture.child)
        for path in ["deps/child", "sibling"] {
            _ = try fixture.git(["submodule", "add", "../child", path])
        }
        _ = try fixture.git(["submodule", "update", "--init", "--recursive"])
        _ = try fixture.git(["commit", "-am", "Children"])
        let childURL = fixture.repo.appendingPathComponent("deps/child")
        let nestedURL = childURL.appendingPathComponent("nested/leaf")
        let module = GitRepositoryModule(repositoryURL: nestedURL, git: LocalSubmoduleRunner())
        let state = try await module.loadRepositoryState()
        let tree = state.navigation.submoduleTree
        try require(tree.first?.isTop == true && tree.first?.repositoryURL.resolvingSymlinksInPath() == fixture.repo.resolvingSymlinksInPath(), "nested Browser tree is rooted at top superproject")
        try require(tree.filter(\.isCurrent).map(\.path) == ["deps/child/nested/leaf"], "exactly the nested current repository is marked")
        let parent = try unwrap(tree.first { $0.path == "deps/child" }, "parent tree item")
        let sibling = try unwrap(tree.first { $0.path == "sibling" }, "sibling tree item")
        try require(try await module.submoduleTreeLocation(parent).resolvingSymlinksInPath() == childURL.resolvingSymlinksInPath(), "parent opening uses existing repository location")
        try require(try await module.submoduleTreeLocation(sibling).resolvingSymlinksInPath() == fixture.repo.appendingPathComponent("sibling").resolvingSymlinksInPath(), "sibling opening is not relative to current child")
        let siblingUpdate = try await module.updateSubmoduleTreeItem(sibling, output: { _ in })
        try require(siblingUpdate.succeeded && !siblingUpdate.changed, "sibling update uses its immediate parent and preserves no-op notifier behavior")
        let current = try unwrap(tree.first(where: \.isCurrent), "current tree item")
        let same = try await module.submoduleTreeRepository(current)
        try require((same as? GitRepositoryModule) === module, "current node reuses the open module for workflows")
        let rootModule = GitRepositoryModule(repositoryURL: fixture.repo, git: LocalSubmoduleRunner())
        _ = try await rootModule.loadRepositoryState()
        _ = try fixture.git(["config", "user.name", "Submodule Test"], in: childURL)
        _ = try fixture.git(["config", "user.email", "submodules@example.com"], in: childURL)
        let recorded = try fixture.git(["rev-parse", "HEAD"], in: childURL)
        try Data("ahead\n".utf8).write(to: childURL.appendingPathComponent("ahead.txt"))
        _ = try fixture.git(["add", "ahead.txt"], in: childURL)
        _ = try fixture.git(["commit", "-m", "Ahead"], in: childURL, environment: ["GIT_COMMITTER_DATE": "2001-01-01T00:00:00Z"])
        let aheadID = try fixture.git(["rev-parse", "HEAD"], in: childURL)
        var item = try unwrap(try await rootModule.loadRepositoryState().navigation.submoduleTree.first { $0.path == "deps/child" }, "ahead item")
        try require(item.commitState == .ahead && item.addedCommits == 1 && item.removedCommits == 0, "ahead counts use current...recorded orientation")
        try require(item.recordedID?.string == recorded && item.commitID?.string == aheadID, "recorded gitlink and checkout IDs stay distinct")
        _ = try fixture.git(["update-index", "--cacheinfo", "160000,\(aheadID),deps/child"])
        _ = try fixture.git(["checkout", "--detach", recorded], in: childURL)
        item = try unwrap(try await rootModule.loadRepositoryState().navigation.submoduleTree.first { $0.path == "deps/child" }, "behind item")
        try require(item.commitState == .behind && item.addedCommits == 0 && item.removedCommits == 1, "behind compares against INDEX, not parent HEAD")
        try Data("diverged\n".utf8).write(to: childURL.appendingPathComponent("different.txt"))
        _ = try fixture.git(["add", "different.txt"], in: childURL)
        _ = try fixture.git(["commit", "-m", "Diverged"], in: childURL, environment: ["GIT_COMMITTER_DATE": "2002-01-01T00:00:00Z"])
        item = try unwrap(try await rootModule.loadRepositoryState().navigation.submoduleTree.first { $0.path == "deps/child" }, "divergent item")
        try require(item.addedCommits == 1 && item.removedCommits == 1 && item.commitState == .newer, "divergence counts both sides; newer committer date determines semi-up arrow")
        _ = try fixture.git(["commit", "--amend", "--no-edit"], in: childURL, environment: ["GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z"])
        item = try unwrap(try await rootModule.loadRepositoryState().navigation.submoduleTree.first { $0.path == "deps/child" }, "older divergent item")
        try require(item.commitState == .older && item.addedCommits == 1 && item.removedCommits == 1, "older divergent commit uses semi-down, not rewind")
        _ = try fixture.git(["update-index", "--cacheinfo", "160000,\(String(repeating: "a", count: recorded.count)),deps/child"])
        item = try unwrap(try await rootModule.loadRepositoryState().navigation.submoduleTree.first { $0.path == "deps/child" }, "unavailable object item")
        try require(item.commitState == .modified && item.addedCommits == nil && item.removedCommits == nil, "unavailable recorded object is unknown-count modified, never falsely ahead")
        _ = try fixture.git(["update-index", "--cacheinfo", "160000,\(aheadID),deps/child"])
        try Data("dirty\n".utf8).write(to: childURL.appendingPathComponent("dirty.txt"))
        item = try unwrap(try await rootModule.loadRepositoryState().navigation.submoduleTree.first { $0.path == "deps/child" }, "dirty item")
        try require(item.isDirty, "dirty state is independent of commit direction")
        _ = try fixture.git(["submodule", "deinit", "-f", "--", "sibling"])
        item = try unwrap(try await rootModule.loadRepositoryState().navigation.submoduleTree.first { $0.path == "sibling" }, "uninitialized item")
        try require(!item.isInitialized && item.commitID == nil && item.recordedID != nil && item.commitState == .uninitialized, "uninitialized checkout has no fake current object ID")
        try FileManager.default.removeItem(at: fixture.repo.appendingPathComponent("sibling"))
        item = try unwrap(try await rootModule.loadRepositoryState().navigation.submoduleTree.first { $0.path == "sibling" }, "missing item")
        try require(item.commitState == .missing && !item.isInitialized, "missing directory stays visible with truthful state")
    }

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SubmoduleFailure(message) }; return value
    }

    private static func nestedAndPartialChanges() async throws {
        let fixture = try SubmoduleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let leaf = fixture.root.appendingPathComponent("leaf")
        _ = try fixture.git(["clone", fixture.child.path, leaf.path], in: fixture.root)
        _ = try fixture.git(["submodule", "add", "../leaf", "nested"], in: fixture.child)
        _ = try fixture.git(["commit", "-am", "Nested child"], in: fixture.child)
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: LocalSubmoduleRunner())
        _ = try await module.loadRepositoryState()
        let added = try await module.addSubmodule(.init(source: "../child", path: "outer"), output: { _ in })
        try require(added.succeeded, "outer add: \(added.output)")
        let update = try await module.performSubmoduleAction(.update(path: nil), output: { _ in })
        try require(update.succeeded && update.changed, "update recursively initializes nested module: \(update.output)")
        let state = try await module.loadRepositoryState()
        let nested = state.navigation.submodules.first { $0.path == "outer/nested" }
        try require(nested?.parentPath == "outer" && nested?.localPath == "nested" && nested?.commitID != nil, "nested model parent and typed identity")
        let nestedUpdate = try await module.performSubmoduleAction(.update(path: "outer/nested"), output: { _ in })
        try require(nestedUpdate.succeeded && !nestedUpdate.changed, "nested entry executes relative to its immediate parent")
        let context = try await module.loadSubmoduleContext()
        try require(context.submodules.count == 1, "manager displays immediate children only")
        let second = try await module.addSubmodule(.init(source: "../leaf", path: "second"), output: { _ in })
        try require(second.succeeded, "second add")
        _ = try fixture.git(["commit", "-am", "Children"])
        let removed = try await module.performSubmoduleAction(.remove(path: "second"), output: { _ in })
        try require(removed.succeeded, "remove one of several modules: \(removed.output)")
        try require(try fixture.git(["config", "-f", ".gitmodules", "--get", "submodule.outer.path"]) == "outer", "other config sections preserved")
        try require(!(try fixture.git(["ls-files", "--", ".gitmodules"])).isEmpty, ".gitmodules remains staged/tracked")
        let interrupted = GitRepositoryModule(repositoryURL: fixture.repo, git: LocalSubmoduleRunner(interruptAfterMutation: true))
        _ = try await interrupted.loadRepositoryState()
        let partial = try await interrupted.addSubmodule(.init(source: "../leaf", path: "interrupted"), output: { _ in })
        try require(!partial.succeeded && partial.changed, "interruption after a completed mutation still requests refresh")
        try require(try fixture.git(["ls-files", "--stage", "--", "interrupted"]).hasPrefix("160000"), "partial outcome records actual index state")
        try Data("ignored/\n".utf8).write(to: fixture.repo.appendingPathComponent(".gitignore"))
        let ignored = try await module.addSubmodule(.init(source: "../leaf", path: "ignored"), output: { _ in })
        try require(!ignored.succeeded, "ignored destination requires explicit force: \(ignored.output)")
        try require(try fixture.git(["ls-files", "--stage", "--", "ignored"]).isEmpty, "refused add must not stage the ignored gitlink")
        if FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent("ignored/.git").path) {
            try require(ignored.changed, "failed add that cloned a child still refreshes repository state")
        }
        let forced = try await module.addSubmodule(.init(source: "../leaf", path: "ignored", force: true), output: { _ in })
        try require(forced.succeeded && forced.changed, "force adds ignored submodule: \(forced.output)")
        try require(try fixture.git(["ls-files", "--stage", "--", "ignored"]).hasPrefix("160000"), "forced add stages gitlink")
        try Data("new child content\n".utf8).write(to: fixture.child.appendingPathComponent("file.txt"))
        _ = try fixture.git(["commit", "-am", "New child target"], in: fixture.child)
        let target = try fixture.git(["rev-parse", "HEAD"], in: fixture.child)
        let outer = fixture.repo.appendingPathComponent("outer")
        _ = try fixture.git(["fetch", "origin"], in: outer)
        _ = try fixture.git(["update-index", "--cacheinfo", "160000,\(target),outer"])
        try Data("do not overwrite\n".utf8).write(to: outer.appendingPathComponent("file.txt"))
        let dirty = try await module.performSubmoduleAction(.update(path: "outer"), output: { _ in })
        try require(!dirty.succeeded && !dirty.changed, "dirty checkout refusal without partial changes does not notify")
        try require(try String(contentsOf: outer.appendingPathComponent("file.txt"), encoding: .utf8) == "do not overwrite\n", "update protects dirty files")
    }

    @MainActor private static func notifications() throws {
        let mock = MockRepositoryDataSource()
        let browser = RepositoryBrowserViewController(repositoryModule: mock)
        let commands = GitUICommands(repositoryModule: mock, browser: browser)
        var count = 0
        _ = commands.repositoryChangedNotifier.subscribe { _, _ in count += 1 }
        commands.completeSubmoduleOperation(.init(succeeded: true, changed: false, output: ""))
        commands.completeSubmoduleOperation(.init(succeeded: false, changed: false, output: ""))
        try require(count == 0, "no-op/failure does not notify")
        commands.repositoryChangedNotifier.lock()
        commands.completeSubmoduleOperation(.init(succeeded: true, changed: true, output: ""))
        commands.completeSubmoduleOperation(.init(succeeded: false, changed: true, output: ""))
        try require(count == 0, "compound mutation stays coalesced")
        commands.repositoryChangedNotifier.unlock(requestNotify: false)
        try require(count == 1, "partial changes and success coalesce to one authoritative refresh")
    }

    private static func gitlinkConflict() async throws {
        let fixture = try SubmoduleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let base = try fixture.git(["rev-parse", "HEAD"], in: fixture.child)
        try Data("local\n".utf8).write(to: fixture.child.appendingPathComponent("local.txt"))
        _ = try fixture.git(["add", "."], in: fixture.child); _ = try fixture.git(["commit", "-m", "Local"], in: fixture.child)
        let local = try fixture.git(["rev-parse", "HEAD"], in: fixture.child)
        _ = try fixture.git(["checkout", "-b", "remote-side", base], in: fixture.child)
        try Data("remote\n".utf8).write(to: fixture.child.appendingPathComponent("remote.txt"))
        _ = try fixture.git(["add", "."], in: fixture.child); _ = try fixture.git(["commit", "-m", "Remote"], in: fixture.child)
        let remote = try fixture.git(["rev-parse", "HEAD"], in: fixture.child)
        _ = try fixture.git(["checkout", "main"], in: fixture.child)
        _ = try fixture.git(["merge", "--no-edit", "remote-side"], in: fixture.child)
        let resolved = try fixture.git(["rev-parse", "HEAD"], in: fixture.child)
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: LocalSubmoduleRunner())
        _ = try await module.loadRepositoryState()
        let result = try await module.addSubmodule(.init(source: "../child", path: "child"), output: { _ in })
        try require(result.succeeded, "conflict setup add")
        let child = fixture.repo.appendingPathComponent("child")
        _ = try fixture.git(["checkout", "--detach", base], in: child)
        _ = try fixture.git(["add", "child"]); _ = try fixture.git(["commit", "-am", "Base child"])
        _ = try fixture.git(["branch", "other"])
        _ = try fixture.git(["checkout", "--detach", local], in: child)
        _ = try fixture.git(["add", "child"]); _ = try fixture.git(["commit", "-m", "Local child"])
        _ = try fixture.git(["checkout", "other"])
        _ = try fixture.git(["checkout", "--detach", remote], in: child)
        _ = try fixture.git(["add", "child"]); _ = try fixture.git(["commit", "-m", "Remote child"])
        _ = try fixture.git(["checkout", "main"])
        _ = try fixture.git(["merge", "other"], acceptedStatuses: [1])
        let conflict = try await module.loadSubmoduleConflict(path: "child")
        try require(try await !module.submoduleConflictChanged(since: conflict), "read-only conflict inspection does not notify")
        try require(conflict.conflict.base?.objectID.string == base && conflict.conflict.local?.objectID.string == local && conflict.conflict.remote?.objectID.string == remote, "gitlink base/local/remote stages")
        let choices = try await module.loadSubmoduleConflictCheckout(path: "child")
        try require(choices.branches.branches.map(\.name) == ["main"], "only branches containing both sides are offered")
        try require(choices.branches.remotes.flatMap(\.branches).allSatisfy { $0.name != "remote-side" }, "one-sided remote branch excluded")
        _ = try fixture.git(["checkout", "main"], in: child)
        let staged = try await module.performSubmoduleAction(.stageCurrent(path: "child"), output: { _ in })
        try require(staged.succeeded && staged.changed, "stage current gitlink")
        try require(try await module.submoduleConflictChanged(since: conflict), "conflict lifecycle observes actual change once")
        try require(try fixture.git(["ls-files", "--stage", "child"]).hasPrefix("160000 \(resolved) 0"), "resolved child commit staged exactly")
        try require(try fixture.git(["ls-files", "--unmerged"]).isEmpty, "unmerged index cleared")
        _ = try await module.commit(.init(message: "Resolve child merge", mode: .normal, stageAllBeforeCommit: false, allowEmpty: false, signOff: false, author: nil, resetAuthor: false))
        try require(try fixture.git(["rev-list", "--parents", "-n", "1", "HEAD"]).split(separator: " ").count == 3, "closed Commit finishes merge with both parents")
    }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw SubmoduleFailure(message) } }
}

private struct LocalSubmoduleRunner: GitCommandRunning {
    let process = GitProcess()
    var interruptAfterMutation = false
    func run(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String]) async throws -> GitCommandResult {
        try await process.run(arguments: arguments, in: directory, standardInput: standardInput, environment: environment.merging(["GIT_ALLOW_PROTOCOL": "file"]) { _, new in new })
    }
    func runStreaming(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String], output: @escaping GitOutputHandler) async throws -> GitCommandResult {
        let result = try await process.runStreaming(arguments: arguments, in: directory, standardInput: standardInput, environment: environment.merging(["GIT_ALLOW_PROTOCOL": "file"]) { _, new in new }, output: output)
        if interruptAfterMutation { throw CancellationError() }
        return result
    }
}
private struct SubmoduleFailure: LocalizedError { let errorDescription: String?; init(_ message: String) { errorDescription = message } }
private final class SubmoduleFixture {
    let root: URL
    let repo: URL
    let child: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-Submodules-\(UUID().uuidString)")
        repo = root.appendingPathComponent("parent"); child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for url in [repo, child] {
            _ = try git(["init", "-b", "main", url.path], in: root)
            _ = try git(["config", "user.name", "Submodule Test"], in: url)
            _ = try git(["config", "user.email", "submodules@example.com"], in: url)
            try Data("original\n".utf8).write(to: url.appendingPathComponent("file.txt"))
            _ = try git(["add", "file.txt"], in: url); _ = try git(["commit", "-m", "Initial"], in: url)
        }
    }
    func git(_ arguments: [String], in directory: URL? = nil, acceptedStatuses: Set<Int32> = [0], environment: [String: String] = [:]) throws -> String {
        let process = Process(); let out = Pipe(); let err = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = arguments
        process.currentDirectoryURL = directory ?? repo; process.standardOutput = out; process.standardError = err
        var env = ProcessInfo.processInfo.environment; env["GIT_TERMINAL_PROMPT"] = "0"; env["GIT_ALLOW_PROTOCOL"] = "file"; env["LC_ALL"] = "C"; env.merge(environment) { _, value in value }; process.environment = env
        try process.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); let errors = err.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard acceptedStatuses.contains(process.terminationStatus) else { throw SubmoduleFailure(String(decoding: errors, as: UTF8.self)) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
