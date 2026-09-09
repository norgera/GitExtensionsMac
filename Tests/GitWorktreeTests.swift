@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import Foundation

enum GitWorktreeTests {
    static func run() async throws {
        try commands()
        let fixture = try WorktreeFixture()
        defer { fixture.remove() }
        let module = GitRepositoryModule(repositoryURL: fixture.repo, git: GitProcess())
        _ = try await module.loadRepositoryState()
        let initial = try await module.loadWorktreeContext()
        try require(initial.worktrees.count == 1 && initial.worktrees[0].isMain && initial.worktrees[0].isCurrent, "main/current metadata")
        try require(!initial.worktrees[0].canDelete && !initial.worktrees[0].canOpen, "main/current eligibility")
        try require(initial.availableBranches == ["topic"], "current branch excluded")
        _ = try fixture.git(["tag", "topic"])
        let ambiguousRefs = try await module.loadWorktreeContext()
        try require(ambiguousRefs.availableBranches == ["topic"], "tag collision must not turn a branch name into heads/topic")
        _ = try fixture.git(["tag", "-d", "topic"])
        let linked = fixture.root.appendingPathComponent("linked space é")
        let result = try await module.createWorktree(.init(path: linked.path, branch: "topic", createBranch: false))
        try require(result.succeeded && result.changed, "create existing branch: \(result.output)")
        try require(try fixture.git(["rev-parse", "HEAD"], in: linked) == fixture.head, "created HEAD")
        try require(FileManager.default.fileExists(atPath: linked.appendingPathComponent("tracked.txt").path), "checkout content")
        let loaded = try await module.loadWorktreeContext()
        let entry = try unwrap(loaded.worktrees.first { $0.path == linked.path })
        try require(entry.headID?.string == fixture.head && entry.canDelete && entry.canOpen && !entry.isMain, "linked identity and eligibility")
        let state = try await module.loadRepositoryState()
        try require(state.navigation.worktrees.contains(entry), "Browser navigation receives new worktree")
        let occupied = try await module.createWorktree(.init(path: fixture.root.appendingPathComponent("occupied").path, branch: "topic", createBranch: false))
        try require(!occupied.succeeded && !occupied.changed, "occupied branch must not change state")
        do {
            _ = try await module.createWorktree(.init(path: linked.path, branch: "new", createBranch: true))
            throw WorktreeFailure("nonempty destination accepted")
        } catch is RepositoryWorktreeError {}
        do {
            _ = try await module.createWorktree(.init(path: fixture.root.appendingPathComponent("invalid").path, branch: "bad..name", createBranch: true))
            throw WorktreeFailure("invalid name accepted")
        } catch is RepositoryWorktreeError {}
        do { _ = try await module.deleteWorktree(path: fixture.repo.path); throw WorktreeFailure("main deletion accepted") } catch is RepositoryWorktreeError {}
        do { _ = try await module.deleteWorktree(path: fixture.root.path); throw WorktreeFailure("unregistered deletion accepted") } catch is RepositoryWorktreeError {}

        let newPath = fixture.root.appendingPathComponent("new-branch")
        let newResult = try await module.createWorktree(.init(path: newPath.path, branch: "fresh", createBranch: true))
        try require(newResult.succeeded && newResult.changed, "new branch: \(newResult.output)")
        try require(try fixture.git(["rev-parse", "refs/heads/fresh"]) == fixture.head, "new branch target is current commit")
        let linkedModule = GitRepositoryModule(repositoryURL: newPath, git: GitProcess())
        _ = try await linkedModule.loadRepositoryState()
        let linkedContext = try await linkedModule.loadWorktreeContext()
        try require(linkedContext.worktrees.first?.isMain == true && linkedContext.worktrees.first?.isCurrent == false, "main first from linked context")
        try require(linkedContext.worktrees.first?.canDelete == false && linkedContext.worktrees.first?.canOpen == true, "linked Browser may open but not delete main")
        do { _ = try await linkedModule.deleteWorktree(path: newPath.path); throw WorktreeFailure("current linked deletion accepted") } catch is RepositoryWorktreeError {}
        let detached = fixture.root.appendingPathComponent("detached")
        _ = try fixture.git(["worktree", "add", "--detach", detached.path, fixture.head])
        let detachedContext = try await module.loadWorktreeContext()
        let detachedEntry = try unwrap(detachedContext.worktrees.first { $0.path == detached.path })
        try require(detachedEntry.isDetached && detachedEntry.headID?.string == fixture.head, "detached parsing")
        _ = try fixture.git(["worktree", "lock", "--reason", "external disk", detached.path])
        try FileManager.default.removeItem(at: detached)
        let lockedPrune = try await module.pruneWorktrees()
        try require(!lockedPrune.changed, "prune preserves locked missing worktree")
        _ = try fixture.git(["worktree", "unlock", detached.path])
        let prune = try await module.pruneWorktrees()
        try require(prune.changed && prune.succeeded, "prune unlocked stale worktree")
        let noPrune = try await module.pruneWorktrees()
        try require(!noPrune.changed && noPrune.succeeded, "empty prune is not a mutation")

        try Data("dirty\n".utf8).write(to: linked.appendingPathComponent("tracked.txt"))
        try Data("untracked\n".utf8).write(to: linked.appendingPathComponent("untracked.txt"))
        let deletion = try await module.deleteWorktree(path: linked.path)
        try require(deletion.changed && deletion.succeeded, "confirmed upstream force-equivalent delete")
        try require(!FileManager.default.fileExists(atPath: linked.path), "directory and dirty/untracked files removed")
        let after = try await module.loadWorktreeContext()
        try require(!after.worktrees.contains { $0.path == linked.path }, "registration pruned")
        try require(try fixture.git(["rev-parse", "refs/heads/topic"]) == fixture.head, "deletion preserves branch")
        try require(try fixture.git(["rev-parse", "HEAD"]) == fixture.head, "current HEAD unchanged")

        let bare = fixture.root.appendingPathComponent("bare.git")
        _ = try fixture.git(["clone", "--bare", fixture.repo.path, bare.path])
        let bareModule = GitRepositoryModule(repositoryURL: bare, git: GitProcess())
        _ = try await bareModule.loadRepositoryState()
        let bareContext = try await bareModule.loadWorktreeContext()
        try require(bareContext.worktrees.first?.isBare == true, "bare main metadata")
        let bareAdd = try await bareModule.createWorktree(.init(path: fixture.root.appendingPathComponent("bare-linked").path, branch: "topic", createBranch: false))
        try require(bareAdd.succeeded && bareAdd.changed, "bare linked create")
        let interruptedModule = GitRepositoryModule(repositoryURL: fixture.repo, git: InterruptedWorktreeRunner())
        _ = try await interruptedModule.loadRepositoryState()
        let interrupted = try await interruptedModule.createWorktree(.init(path: fixture.root.appendingPathComponent("interrupted").path, branch: "interrupted", createBranch: true))
        try require(interrupted.changed && !interrupted.succeeded, "cancellation after mutation retains refresh requirement")
        try require(try fixture.git(["rev-parse", "refs/heads/interrupted"]) == fixture.head, "partial/cancelled result corresponds to actual created ref")
        print("GitWorktreeTests: passed")
    }

    private static func commands() throws {
        try require(GitWorktreeCommands.create(relativePath: "../new é", branch: "topic", newBranch: false, defaultRelativePaths: true).arguments == ["-c", "worktree.useRelativePaths=true", "worktree", "add", "../new é", "topic"], "exact existing arguments")
        let new = GitWorktreeCommands.create(relativePath: "../new", branch: "topic", newBranch: true, defaultRelativePaths: false)
        try require(new.arguments == ["worktree", "add", "../new", "-b", "topic"], "exact new branch argument order / config override")
        try require(!new.accessesRemote && new.changesRepositoryState && !GitWorktreeCommands.list.changesRepositoryState, "command semantics")
        try require(GitWorktreeCommands.prune.arguments == ["worktree", "prune"], "prune defaults")
        try require(RepositoryWorktreePaths.destination(basePath: "/repo", branch: "topic/nested") == "/repo_topic_nested", "default folder derivation")
        let nodes = ["/repos/main", "/repos/main.worktrees/topic-a", "/repos/main.worktrees/topic-b"].map { path in
            Worktree(id: path, name: path, path: path, branchName: "topic", isCurrent: false)
        }
        let paths = WorktreePresentation.displayPaths(nodes)
        try require(paths[nodes[0].path] == "main" && paths[nodes[1].path] == "topic-a" && paths[nodes[2].path] == "topic-b", "main-relative display and common directory prefix")
    }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw WorktreeFailure(message) } }
    private static func unwrap<T>(_ value: T?) throws -> T { guard let value else { throw WorktreeFailure("missing value") }; return value }
}

private struct InterruptedWorktreeRunner: GitCommandRunning {
    let process = GitProcess()
    func run(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String]) async throws -> GitCommandResult {
        try await process.run(arguments: arguments, in: directory, standardInput: standardInput, environment: environment)
    }
    func runStreaming(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String], output: @escaping GitOutputHandler) async throws -> GitCommandResult {
        _ = try await process.runStreaming(arguments: arguments, in: directory, standardInput: standardInput, environment: environment, output: output)
        throw CancellationError()
    }
}

private struct WorktreeFailure: LocalizedError { let errorDescription: String?; init(_ message: String) { errorDescription = message } }
private final class WorktreeFixture {
    let root: URL
    let repo: URL
    var head = ""
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-Worktrees-\(UUID().uuidString)")
        repo = root.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try git(["init", "-b", "main", repo.path], in: root)
        _ = try git(["config", "user.name", "Worktree Test"])
        _ = try git(["config", "user.email", "worktrees@example.com"])
        try Data("original\n".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        _ = try git(["add", "tracked.txt"]); _ = try git(["commit", "-m", "Initial"])
        head = try git(["rev-parse", "HEAD"])
        _ = try git(["branch", "topic"])
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func git(_ arguments: [String], in directory: URL? = nil) throws -> String {
        let process = Process(); let out = Pipe(); let err = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = arguments
        process.currentDirectoryURL = directory ?? repo; process.standardOutput = out; process.standardError = err
        var env = ProcessInfo.processInfo.environment; env["GIT_TERMINAL_PROMPT"] = "0"; env["LC_ALL"] = "C"; process.environment = env
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(); let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw WorktreeFailure(String(decoding: errors, as: UTF8.self)) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
