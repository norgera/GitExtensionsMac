@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import Foundation

enum GitRevertTests {
    static func run() async throws {
        try testCommandConstructionAndOrdering()
        try await testAutomaticCommit()
        try await testNoCommitAndMultipleRevisions()
        try await testMergeMainline()
        try await testConflictContinueAndAbort()
        try await testInvalidAndBareRepositories()
        print("GitRevertTests: passed")
    }

    private static func testCommandConstructionAndOrdering() throws {
        let commit = testObjectID("revert-command")
        let automatic = GitRevertCommands.revert(.init(commitID: commit, automaticallyCommit: true))
        try revertRequire(automatic.arguments == ["revert", commit.string], "automatic revert arguments")
        try revertRequire(!automatic.accessesRemote && automatic.changesRepositoryState, "automatic revert metadata")

        let noCommit = GitRevertCommands.revert(.init(commitID: commit, automaticallyCommit: false))
        try revertRequire(noCommit.arguments == ["revert", "--no-commit", commit.string], "no-commit arguments")

        let mainline = GitRevertCommands.revert(.init(commitID: commit, automaticallyCommit: true, mainlineParent: 2))
        try revertRequire(mainline.arguments == ["revert", "-m", "2", commit.string], "merge mainline arguments")
        try revertRequire(GitRevertCommands.continueRevert.arguments == ["revert", "--continue"], "continue arguments")
        try revertRequire(GitRevertCommands.abortRevert.arguments == ["revert", "--abort"], "abort arguments")

        let newest = revertCommit("newest")
        let middle = revertCommit("middle")
        let oldest = revertCommit("oldest")
        let artificial = Commit(
            id: .workingDirectory,
            shortID: "Working directory",
            subject: "Working directory",
            body: "",
            authorName: "",
            authorEmail: "",
            authorDate: .distantPast,
            committerName: "",
            committerEmail: "",
            commitDate: .distantPast,
            parentIDs: [],
            references: []
        )
        let ordered = RevertWorkflowOrdering.ordered(
            [oldest, artificial, newest, middle],
            in: [newest, middle, oldest]
        )
        try revertRequire(ordered.map(\.id) == [newest.id, middle.id, oldest.id], "multiple selection follows upstream ascending grid-row order")
    }

    private static func testAutomaticCommit() async throws {
        let fixture = try RevertFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.linearRepository(named: "Automatic")
        let before = try fixture.objectID(["rev-parse", "HEAD"], in: repository.url)
        let module = try await fixture.module(for: repository.url)
        let result = try await module.revert(.init(commitID: repository.change, automaticallyCommit: true))
        let after = try fixture.objectID(["rev-parse", "HEAD"], in: repository.url)
        try revertRequire(after != before, "automatic revert creates a commit")
        try revertRequire(try fixture.objectID(["rev-parse", "HEAD^"], in: repository.url) == before, "revert commit is based on previous HEAD")
        try revertRequire(try fixture.read("tracked.txt", in: repository.url) == "base\n", "automatic revert restores prior content")
        try revertRequire(try fixture.git(["status", "--porcelain"], in: repository.url).trimmed.isEmpty, "automatic revert leaves index/worktree clean")
        try revertRequire(result.outcome == .completed && result.selectedCommitID == .object(after), "automatic result selects new HEAD")
    }

    private static func testNoCommitAndMultipleRevisions() async throws {
        let fixture = try RevertFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.linearRepository(named: "No Commit")
        let head = try fixture.objectID(["rev-parse", "HEAD"], in: repository.url)
        let module = try await fixture.module(for: repository.url)
        let result = try await module.revert(.init(commitID: repository.change, automaticallyCommit: false))
        try revertRequire(try fixture.objectID(["rev-parse", "HEAD"], in: repository.url) == head, "no-commit leaves HEAD unchanged")
        try revertRequire(try fixture.git(["diff", "--cached", "--name-only"], in: repository.url).trimmed == "tracked.txt", "no-commit stages inverse changes")
        try revertRequire(try fixture.read("tracked.txt", in: repository.url) == "base\n", "no-commit updates worktree")
        try revertRequire(result.selectedCommitID == .workingDirectory, "no-commit selects working-directory state")

        let multiple = try fixture.multiRepository(named: "Multiple")
        let multipleModule = try await fixture.module(for: multiple.url)
        _ = try await multipleModule.revert(.init(commitID: multiple.newest, automaticallyCommit: false))
        _ = try await multipleModule.revert(.init(commitID: multiple.oldest, automaticallyCommit: false))
        try revertRequire(!fixture.exists("one.txt", in: multiple.url), "newest-to-oldest sequence reverts older addition")
        try revertRequire(!fixture.exists("two.txt", in: multiple.url), "newest-to-oldest sequence reverts newer addition")
        try revertRequire(try fixture.git(["rev-parse", "HEAD"], in: multiple.url).trimmed == multiple.newest.string, "multi no-commit sequence leaves HEAD unchanged")
        let message = try fixture.readGitFile("MERGE_MSG", in: multiple.url)
        try revertRequire(message.contains("Revert \"Two\"") && message.contains("Revert \"One\""), "multi no-commit sequence preserves every generated revert message")
    }

    private static func testMergeMainline() async throws {
        let fixture = try RevertFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.mergeRepository(named: "Merge")
        let module = try await fixture.module(for: repository.url)

        do {
            _ = try await module.revert(.init(commitID: repository.merge, automaticallyCommit: true))
            throw RevertTestError("merge revert accepted no mainline")
        } catch RepositoryRevertError.invalidMainline(_, let parent, let count) {
            try revertRequire(parent == nil && count == 2, "merge validation reports available parents")
        }

        let result = try await module.revert(.init(commitID: repository.merge, automaticallyCommit: true, mainlineParent: 1))
        try revertRequire(result.outcome == .completed, "merge mainline revert completes")
        try revertRequire(fixture.exists("main.txt", in: repository.url), "mainline-one content remains")
        try revertRequire(!fixture.exists("side.txt", in: repository.url), "changes introduced by the other parent are reverted")
    }

    private static func testConflictContinueAndAbort() async throws {
        let fixture = try RevertFixture.make()
        defer { fixture.remove() }

        let continued = try fixture.conflictRepository(named: "Continue")
        let continuedModule = try await fixture.module(for: continued.url)
        let conflict = try await continuedModule.revert(.init(commitID: continued.target, automaticallyCommit: true))
        guard case .conflicts(let paths) = conflict.outcome else {
            throw RevertTestError("conflicting revert did not return a typed conflict outcome")
        }
        try revertRequire(paths == ["tracked.txt"], "conflicting path is preserved")
        var state = try await continuedModule.loadMutationState()
        try revertRequire(state.revertInProgress && !state.conflictedPaths.isEmpty, "revert sequencer state is visible")
        try fixture.write("base\n", to: continued.url.appendingPathComponent("tracked.txt"))
        try fixture.git(["add", "tracked.txt"], in: continued.url)
        let continuedResult = try await continuedModule.continueRevert()
        state = try await continuedModule.loadMutationState()
        try revertRequire(continuedResult.outcome == .completed, "resolved revert continues")
        try revertRequire(!state.revertInProgress && state.conflictedPaths.isEmpty, "continue clears revert sequencer and conflicts")
        try revertRequire(try fixture.read("tracked.txt", in: continued.url) == "base\n", "continued revert keeps resolved content")
        try revertRequire(try fixture.git(["status", "--porcelain"], in: continued.url).trimmed.isEmpty, "continued automatic revert commits resolution")

        let aborted = try fixture.conflictRepository(named: "Abort")
        let originalHead = try fixture.objectID(["rev-parse", "HEAD"], in: aborted.url)
        let abortedModule = try await fixture.module(for: aborted.url)
        _ = try await abortedModule.revert(.init(commitID: aborted.target, automaticallyCommit: true))
        let abortResult = try await abortedModule.abortRevert()
        let abortedState = try await abortedModule.loadMutationState()
        try revertRequire(abortResult.outcome == .completed, "abort completes")
        try revertRequire(!abortedState.revertInProgress && abortedState.conflictedPaths.isEmpty, "abort clears sequencer/index conflict")
        try revertRequire(try fixture.objectID(["rev-parse", "HEAD"], in: aborted.url) == originalHead, "abort restores original HEAD")
        try revertRequire(try fixture.read("tracked.txt", in: aborted.url) == "head\n", "abort restores pre-revert worktree")
    }

    private static func testInvalidAndBareRepositories() async throws {
        let fixture = try RevertFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.linearRepository(named: "Invalid")
        let module = try await fixture.module(for: repository.url)
        do {
            _ = try await module.revert(.init(commitID: testObjectID("stale-revert"), automaticallyCommit: true))
            throw RevertTestError("stale revision was accepted")
        } catch GitError.commandFailed {}

        let bare = fixture.root.appendingPathComponent("Bare.git", isDirectory: true)
        try fixture.git(["clone", "--bare", repository.url.path, bare.path], in: fixture.root)
        let bareModule = try await fixture.module(for: bare)
        do {
            _ = try await bareModule.revert(.init(commitID: repository.change, automaticallyCommit: true))
            throw RevertTestError("bare repository accepted revert")
        } catch RepositoryMutationError.bareRepository {}
    }
}

private final class RevertFixture {
    struct LinearInfo { let url: URL; let change: ObjectID }
    struct MultipleInfo { let url: URL; let oldest: ObjectID; let newest: ObjectID }
    struct MergeInfo { let url: URL; let merge: ObjectID }
    struct ConflictInfo { let url: URL; let target: ObjectID }
    let root: URL

    private init(root: URL) { self.root = root }

    static func make() throws -> RevertFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-Revert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return RevertFixture(root: root)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func linearRepository(named name: String) throws -> LinearInfo {
        let url = try repository(named: name)
        try write("base\n", to: url.appendingPathComponent("tracked.txt"))
        try git(["add", "tracked.txt"], in: url)
        try git(["commit", "-m", "Base"], in: url)
        try write("change\n", to: url.appendingPathComponent("tracked.txt"))
        try git(["commit", "-am", "Change"], in: url)
        return LinearInfo(url: url, change: try objectID(["rev-parse", "HEAD"], in: url))
    }

    func multiRepository(named name: String) throws -> MultipleInfo {
        let url = try repository(named: name)
        try write("base\n", to: url.appendingPathComponent("base.txt"))
        try git(["add", "base.txt"], in: url)
        try git(["commit", "-m", "Base"], in: url)
        try write("one\n", to: url.appendingPathComponent("one.txt"))
        try git(["add", "one.txt"], in: url)
        try git(["commit", "-m", "One"], in: url)
        let oldest = try objectID(["rev-parse", "HEAD"], in: url)
        try write("two\n", to: url.appendingPathComponent("two.txt"))
        try git(["add", "two.txt"], in: url)
        try git(["commit", "-m", "Two"], in: url)
        return MultipleInfo(url: url, oldest: oldest, newest: try objectID(["rev-parse", "HEAD"], in: url))
    }

    func mergeRepository(named name: String) throws -> MergeInfo {
        let url = try repository(named: name)
        try write("base\n", to: url.appendingPathComponent("base.txt"))
        try git(["add", "base.txt"], in: url)
        try git(["commit", "-m", "Base"], in: url)
        try git(["checkout", "-b", "side"], in: url)
        try write("side\n", to: url.appendingPathComponent("side.txt"))
        try git(["add", "side.txt"], in: url)
        try git(["commit", "-m", "Side"], in: url)
        try git(["checkout", "main"], in: url)
        try write("main\n", to: url.appendingPathComponent("main.txt"))
        try git(["add", "main.txt"], in: url)
        try git(["commit", "-m", "Main"], in: url)
        try git(["merge", "--no-ff", "side", "-m", "Merge side"], in: url)
        return MergeInfo(url: url, merge: try objectID(["rev-parse", "HEAD"], in: url))
    }

    func conflictRepository(named name: String) throws -> ConflictInfo {
        let url = try repository(named: name)
        try write("base\n", to: url.appendingPathComponent("tracked.txt"))
        try git(["add", "tracked.txt"], in: url)
        try git(["commit", "-m", "Base"], in: url)
        try write("target\n", to: url.appendingPathComponent("tracked.txt"))
        try git(["commit", "-am", "Target"], in: url)
        let target = try objectID(["rev-parse", "HEAD"], in: url)
        try write("head\n", to: url.appendingPathComponent("tracked.txt"))
        try git(["commit", "-am", "Head"], in: url)
        return ConflictInfo(url: url, target: target)
    }

    func repository(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try git(["init", "-b", "main", url.path], in: root)
        try git(["config", "user.name", "Revert Fixture"], in: url)
        try git(["config", "user.email", "revert@example.com"], in: url)
        return url
    }

    func module(for repository: URL) async throws -> GitRepositoryModule {
        let module = GitRepositoryModule(repositoryURL: repository, git: GitProcess())
        _ = try await module.loadRepositoryState()
        return module
    }

    func exists(_ path: String, in repository: URL) -> Bool {
        FileManager.default.fileExists(atPath: repository.appendingPathComponent(path).path)
    }

    func read(_ path: String, in repository: URL) throws -> String {
        try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
    }

    func readGitFile(_ path: String, in repository: URL) throws -> String {
        let gitDirectory = try git(["rev-parse", "--git-dir"], in: repository).trimmed
        let gitURL = URL(fileURLWithPath: gitDirectory, relativeTo: repository).standardizedFileURL
        return try String(contentsOf: gitURL.appendingPathComponent(path), encoding: .utf8)
    }

    func write(_ value: String, to url: URL) throws { try Data(value.utf8).write(to: url) }

    func objectID(_ arguments: [String], in directory: URL) throws -> ObjectID {
        try ObjectID.parse(git(arguments, in: directory).trimmed)
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL) throws -> String {
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
        environment["GIT_EDITOR"] = "true"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw RevertTestError("git \(arguments.joined(separator: " ")) failed: \(String(decoding: error, as: UTF8.self))")
        }
        return String(decoding: output, as: UTF8.self)
    }
}

private struct RevertTestError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func revertRequire(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw RevertTestError(message) }
}

private func revertCommit(_ label: String) -> Commit {
    let id = testObjectID(label)
    return Commit(
        id: .object(id),
        shortID: id.shortString,
        subject: label,
        body: "",
        authorName: "Test",
        authorEmail: "test@example.com",
        authorDate: .distantPast,
        committerName: "Test",
        committerEmail: "test@example.com",
        commitDate: .distantPast,
        parentIDs: [],
        references: []
    )
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
