@testable import GitExtensionsCore
@testable import GitCommands
import Foundation

enum GitResetTests {
    static func run() async throws {
        try testCommandConstruction()
        try await testCurrentBranchModes()
        try await testDetachedAndRepositoryEligibility()
        try await testAnotherBranchSafetyAndReset()
        try await testConflictReset()
        print("GitResetTests: passed")
    }

    private static func testCommandConstruction() throws {
        let target = testObjectID("reset-target")
        for mode in RepositoryResetMode.allCases {
            let command = GitResetCommands.resetCurrentBranch(.init(target: target, mode: mode))
            try resetRequire(
                command.arguments == ["reset", "--\(mode.rawValue)", target.string, "--"],
                "reset \(mode.rawValue): exact upstream arguments"
            )
            try resetRequire(!command.accessesRemote && command.changesRepositoryState, "reset \(mode.rawValue): mutation metadata")
        }
        let branch = RepositoryResetAnotherBranchRequest(branch: "feature/topic", target: target, force: true)
        let update = GitResetCommands.resetAnotherBranch(branch)
        try resetRequire(update.arguments == ["update-ref", "refs/heads/feature/topic", target.string], "another branch: update-ref arguments")
        try resetRequire(!update.accessesRemote && update.changesRepositoryState, "another branch: mutation metadata")
        let ancestry = GitResetCommands.isAncestor(branch: "feature/topic", target: target)
        try resetRequire(ancestry.arguments == ["merge-base", "--is-ancestor", "refs/heads/feature/topic", target.string], "another branch: ancestry arguments")
        try resetRequire(!ancestry.accessesRemote && !ancestry.changesRepositoryState, "ancestry: read-only metadata")
    }

    private static func testCurrentBranchModes() async throws {
        let fixture = try ResetFixture.make()
        defer { fixture.remove() }

        let soft = try fixture.repository(named: "Soft")
        let softModule = try await fixture.module(for: soft.url)
        let softResult = try await softModule.resetCurrentBranch(.init(target: soft.second, mode: .soft))
        try resetRequire(softResult.selectedCommitID == .object(soft.second), "soft: target remains preferred selection")
        try resetRequire(try fixture.git(["rev-parse", "HEAD"], in: soft.url).trimmed == soft.second.string, "soft: HEAD moves")
        try resetRequire(!(try fixture.git(["diff", "--cached", "--name-only"], in: soft.url).trimmed).isEmpty, "soft: index remains at old HEAD")
        try resetRequire((try fixture.git(["diff", "--name-only"], in: soft.url).trimmed).isEmpty, "soft: worktree and index remain aligned")

        let mixed = try fixture.repository(named: "Mixed")
        try fixture.write("staged\n", to: mixed.url.appendingPathComponent("staged.txt"))
        try fixture.git(["add", "staged.txt"], in: mixed.url)
        try fixture.write("unstaged\n", to: mixed.url.appendingPathComponent("tracked.txt"))
        let mixedModule = try await fixture.module(for: mixed.url)
        _ = try await mixedModule.resetCurrentBranch(.init(target: mixed.second, mode: .mixed))
        try resetRequire(try fixture.git(["rev-parse", "HEAD"], in: mixed.url).trimmed == mixed.second.string, "mixed: HEAD moves")
        try resetRequire((try fixture.git(["diff", "--cached", "--name-only"], in: mixed.url).trimmed).isEmpty, "mixed: index resets")
        try resetRequire(!(try fixture.git(["diff", "--name-only"], in: mixed.url).trimmed).isEmpty, "mixed: worktree changes remain")

        let hard = try fixture.repository(named: "Hard")
        try fixture.write("staged\n", to: hard.url.appendingPathComponent("staged.txt"))
        try fixture.git(["add", "staged.txt"], in: hard.url)
        try fixture.write("unstaged\n", to: hard.url.appendingPathComponent("tracked.txt"))
        try fixture.write("untracked\n", to: hard.url.appendingPathComponent("untracked.txt"))
        let hardModule = try await fixture.module(for: hard.url)
        _ = try await hardModule.resetCurrentBranch(.init(target: hard.second, mode: .hard))
        try resetRequire(try fixture.git(["rev-parse", "HEAD"], in: hard.url).trimmed == hard.second.string, "hard: HEAD moves")
        try resetRequire((try fixture.git(["status", "--porcelain", "--untracked-files=no"], in: hard.url).trimmed).isEmpty, "hard: tracked index/worktree reset")
        try resetRequire(FileManager.default.fileExists(atPath: hard.url.appendingPathComponent("untracked.txt").path), "hard: untracked files are not removed")

        for (name, mode) in [("Keep", RepositoryResetMode.keep), ("Merge", .merge)] {
            let repository = try fixture.repository(named: name)
            let module = try await fixture.module(for: repository.url)
            _ = try await module.resetCurrentBranch(.init(target: repository.second, mode: mode))
            try resetRequire(try fixture.git(["rev-parse", "HEAD"], in: repository.url).trimmed == repository.second.string, "\(mode.rawValue): HEAD moves")
            try resetRequire(try String(contentsOf: repository.url.appendingPathComponent("tracked.txt"), encoding: .utf8) == "second\n", "\(mode.rawValue): worktree updates to target")
        }
    }

    private static func testDetachedAndRepositoryEligibility() async throws {
        let fixture = try ResetFixture.make()
        defer { fixture.remove() }
        let detached = try fixture.repository(named: "Detached")
        try fixture.git(["checkout", "--detach", detached.third.string], in: detached.url)
        let module = try await fixture.module(for: detached.url)
        _ = try await module.resetCurrentBranch(.init(target: detached.second, mode: .mixed))
        try resetRequire(try fixture.git(["rev-parse", "HEAD"], in: detached.url).trimmed == detached.second.string, "detached: HEAD resets")
        try resetRequire(try fixture.git(["rev-parse", "main"], in: detached.url).trimmed == detached.third.string, "detached: branch ref remains unchanged")

        let bare = fixture.root.appendingPathComponent("Bare.git", isDirectory: true)
        try fixture.git(["clone", "--bare", detached.url.path, bare.path], in: fixture.root)
        let bareModule = try await fixture.module(for: bare)
        do {
            _ = try await bareModule.resetCurrentBranch(.init(target: detached.second, mode: .hard))
            throw ResetTestError("bare repository accepted current-branch reset")
        } catch RepositoryMutationError.bareRepository {}

        let unborn = fixture.root.appendingPathComponent("Unborn", isDirectory: true)
        try fixture.git(["init", "-b", "main", unborn.path], in: fixture.root)
        let unbornModule = try await fixture.module(for: unborn)
        do {
            _ = try await unbornModule.resetCurrentBranch(.init(target: testObjectID("missing-reset-target"), mode: .soft))
            throw ResetTestError("unborn repository accepted an unavailable target")
        } catch GitError.commandFailed {}
    }

    private static func testAnotherBranchSafetyAndReset() async throws {
        let fixture = try ResetFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.repository(named: "Other Branch")
        try fixture.git(["branch", "topic", repository.first.string], in: repository.url)
        let module = try await fixture.module(for: repository.url)
        let safe = try await module.resetSafety(for: "topic", target: repository.second)
        try resetRequire(safe == .safe, "another branch: ancestor move is safe")
        _ = try await module.resetAnotherBranch(.init(branch: "topic", target: repository.second, force: false))
        try resetRequire(try fixture.git(["rev-parse", "topic"], in: repository.url).trimmed == repository.second.string, "another branch: ref moves")
        try resetRequire(try fixture.git(["rev-parse", "HEAD"], in: repository.url).trimmed == repository.third.string, "another branch: current HEAD stays put")
        try resetRequire((try fixture.git(["status", "--porcelain"], in: repository.url).trimmed).isEmpty, "another branch: index/worktree stay untouched")

        try fixture.git(["checkout", "-b", "diverged", repository.first.string], in: repository.url)
        try fixture.write("diverged\n", to: repository.url.appendingPathComponent("diverged.txt"))
        try fixture.git(["add", "diverged.txt"], in: repository.url)
        try fixture.git(["commit", "-m", "Diverged"], in: repository.url)
        try fixture.git(["checkout", "main"], in: repository.url)
        let divergent = try await module.resetSafety(for: "diverged", target: repository.second)
        try resetRequire(divergent == .requiresForce, "another branch: divergent move requires force")
        do {
            _ = try await module.resetAnotherBranch(.init(branch: "diverged", target: repository.second, force: false))
            throw ResetTestError("another branch: unsafe reset succeeded without force")
        } catch RepositoryResetError.forceRequired(let branch) {
            try resetRequire(branch == "diverged", "another branch: force error identifies branch")
        }
        _ = try await module.resetAnotherBranch(.init(branch: "diverged", target: repository.second, force: true))
        try resetRequire(try fixture.git(["rev-parse", "diverged"], in: repository.url).trimmed == repository.second.string, "another branch: forced ref move succeeds")

        do {
            _ = try await module.resetAnotherBranch(.init(branch: "main", target: repository.second, force: true))
            throw ResetTestError("another branch: current branch was accepted")
        } catch RepositoryResetError.currentBranch(let branch) {
            try resetRequire(branch == "main", "another branch: current-branch error identifies branch")
        }
        do {
            _ = try await module.resetSafety(for: "missing", target: repository.second)
            throw ResetTestError("another branch: missing branch was accepted")
        } catch RepositoryResetError.invalidBranch(let branch) {
            try resetRequire(branch == "missing", "another branch: missing-branch error identifies branch")
        }
    }

    private static func testConflictReset() async throws {
        let fixture = try ResetFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.repository(named: "Conflict")
        try fixture.git(["checkout", "-b", "side", repository.second.string], in: repository.url)
        try fixture.write("side\n", to: repository.url.appendingPathComponent("tracked.txt"))
        try fixture.git(["commit", "-am", "Side"], in: repository.url)
        try fixture.git(["checkout", "main"], in: repository.url)
        try fixture.write("main conflict\n", to: repository.url.appendingPathComponent("tracked.txt"))
        try fixture.git(["commit", "-am", "Main conflict"], in: repository.url)
        let head = try ObjectID.parse(fixture.git(["rev-parse", "HEAD"], in: repository.url).trimmed)
        _ = try? fixture.git(["merge", "side"], in: repository.url)
        try resetRequire(FileManager.default.fileExists(atPath: repository.url.appendingPathComponent(".git/MERGE_HEAD").path), "conflict reset: merge is in progress")
        let module = try await fixture.module(for: repository.url)
        _ = try await module.resetCurrentBranch(.init(target: head, mode: .hard))
        try resetRequire(!FileManager.default.fileExists(atPath: repository.url.appendingPathComponent(".git/MERGE_HEAD").path), "conflict reset: hard reset clears merge state")
        try resetRequire((try fixture.git(["ls-files", "--unmerged"], in: repository.url).trimmed).isEmpty, "conflict reset: index is resolved")
    }
}

private final class ResetFixture {
    struct RepositoryInfo {
        let url: URL
        let first: ObjectID
        let second: ObjectID
        let third: ObjectID
    }

    let root: URL

    private init(root: URL) { self.root = root }

    static func make() throws -> ResetFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-Reset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ResetFixture(root: root)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func repository(named name: String) throws -> RepositoryInfo {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try git(["init", "-b", "main", url.path], in: root)
        try git(["config", "user.name", "Reset Fixture"], in: url)
        try git(["config", "user.email", "reset@example.com"], in: url)
        try write("first\n", to: url.appendingPathComponent("tracked.txt"))
        try git(["add", "tracked.txt"], in: url)
        try git(["commit", "-m", "First"], in: url)
        let first = try ObjectID.parse(git(["rev-parse", "HEAD"], in: url).trimmed)
        try write("second\n", to: url.appendingPathComponent("tracked.txt"))
        try git(["commit", "-am", "Second"], in: url)
        let second = try ObjectID.parse(git(["rev-parse", "HEAD"], in: url).trimmed)
        try write("third\n", to: url.appendingPathComponent("tracked.txt"))
        try git(["commit", "-am", "Third"], in: url)
        let third = try ObjectID.parse(git(["rev-parse", "HEAD"], in: url).trimmed)
        return RepositoryInfo(url: url, first: first, second: second, third: third)
    }

    func module(for repository: URL) async throws -> GitRepositoryModule {
        let module = GitRepositoryModule(repositoryURL: repository, git: GitProcess())
        _ = try await module.loadRepositoryState()
        return module
    }

    func write(_ value: String, to url: URL) throws { try Data(value.utf8).write(to: url) }

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
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw ResetTestError("git \(arguments.joined(separator: " ")) failed: \(String(decoding: error, as: UTF8.self))")
        }
        return String(decoding: output, as: UTF8.self)
    }
}

private struct ResetTestError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func resetRequire(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw ResetTestError(message) }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
