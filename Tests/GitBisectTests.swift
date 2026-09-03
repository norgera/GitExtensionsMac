@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import Foundation

enum GitBisectTests {
    static func run() async throws {
        try testCommandsAndMenuEligibility()
        try await testStartRangeMarksAndReset()
        try await testSkipAndStateDetection()
        try await testInvalidRevision()
        try await testLifecycleAndBareValidation()
        print("GitBisectTests: passed")
    }

    private static func testCommandsAndMenuEligibility() throws {
        let first = bisectObjectID("first")
        let second = bisectObjectID("second")
        try bisectRequire(GitBisectCommands.start.arguments == ["bisect", "start"], "start arguments")
        try bisectRequire(
            GitBisectCommands.mark(.good).arguments == ["bisect", "good"],
            "current-good arguments"
        )
        try bisectRequire(
            GitBisectCommands.mark(.bad, revisions: [first, second]).arguments
                == ["bisect", "bad", first.string, second.string],
            "explicit bad arguments and ordering"
        )
        try bisectRequire(GitBisectCommands.mark(.skip).arguments == ["bisect", "skip"], "skip arguments")
        try bisectRequire(GitBisectCommands.reset.arguments == ["bisect", "reset"], "reset arguments")
        for command in [
            GitBisectCommands.start,
            GitBisectCommands.mark(.good),
            GitBisectCommands.mark(.bad, revisions: [first]),
            GitBisectCommands.mark(.skip),
            GitBisectCommands.reset
        ] {
            try bisectRequire(!command.accessesRemote && command.changesRepositoryState, "bisect command metadata")
        }

        let real = bisectCommit(first)
        var context = RevisionContextMenuContext(
            focusedCommit: real,
            selectedCommits: [real],
            history: [real],
            currentBranchName: "main"
        )
        try bisectRequire(
            RevisionContextMenuBuilder.build(context).entry(id: "revision.bisect.good") == nil,
            "inactive bisect actions are absent"
        )
        context.isBisecting = true
        let active = RevisionContextMenuBuilder.build(context)
        try bisectRequire(active.entry(id: "revision.bisect.good")?.isEnabled == true, "active good action")
        try bisectRequire(active.entry(id: "revision.bisect.bad")?.isEnabled == true, "active bad action")
        try bisectRequire(active.entry(id: "revision.bisect.skip")?.isEnabled == true, "active skip action")
        try bisectRequire(active.entry(id: "revision.bisect.stop")?.isEnabled == true, "active stop action")

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
            references: [],
            kind: .workingDirectory
        )
        let artificialMenu = RevisionContextMenuBuilder.build(.init(
            focusedCommit: artificial,
            selectedCommits: [artificial],
            history: [artificial, real],
            currentBranchName: "main",
            isBisecting: true
        ))
        try bisectRequire(artificialMenu.entry(id: "revision.bisect.good")?.isEnabled == false, "artificial good disabled")
        try bisectRequire(artificialMenu.entry(id: "revision.bisect.stop")?.isEnabled == true, "stop remains available")
    }

    private static func testStartRangeMarksAndReset() async throws {
        let fixture = try BisectFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.repository(named: "Range", commitCount: 7)
        let module = try await fixture.module(for: repository.url)
        let originalHead = repository.commits.last!

        var state = try await module.loadBisectState()
        try bisectRequire(!state.isActive && state.currentCommitID == originalHead, "initial state")
        let started = try await module.startBisect()
        state = try await module.loadBisectState()
        try bisectRequire(started.outcome == .completed && state.isActive, "start activates bisect")
        try bisectRequire(state.currentCommitID == originalHead, "start alone preserves HEAD")
        try bisectRequire(fixture.existsGitFile("BISECT_START", in: repository.url), "BISECT_START detects active state")

        _ = try await module.markBisect(.good, revisions: [repository.commits[0]])
        _ = try await module.markBisect(.bad, revisions: [originalHead])
        state = try await module.loadBisectState()
        try bisectRequire(state.isActive, "range remains active")
        try bisectRequire(state.currentCommitID != originalHead, "completed range checks out a candidate")
        let refs = try fixture.git(["for-each-ref", "--format=%(refname) %(objectname)", "refs/bisect"], in: repository.url)
        try bisectRequire(refs.contains("refs/bisect/bad \(originalHead.string)"), "bad ref records upper boundary")
        try bisectRequire(refs.contains(repository.commits[0].string), "good ref records lower boundary")

        let current = state.currentCommitID!
        _ = try await module.markBisect(.good, revisions: [])
        let log = try fixture.readGitFile("BISECT_LOG", in: repository.url)
        try bisectRequire(log.contains("git bisect good \(current.string)"), "current-good records checked-out revision")

        let reset = try await module.resetBisect()
        state = try await module.loadBisectState()
        try bisectRequire(reset.outcome == .completed && !state.isActive, "reset stops bisect")
        try bisectRequire(state.currentCommitID == originalHead, "reset restores original HEAD")
        try bisectRequire(!fixture.existsGitFile("BISECT_START", in: repository.url), "reset removes active state")
        try bisectRequire(try fixture.git(["for-each-ref", "--format=%(refname)", "refs/bisect"], in: repository.url).trimmed.isEmpty, "reset removes bisect refs")
    }

    private static func testSkipAndStateDetection() async throws {
        let fixture = try BisectFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.repository(named: "Skip", commitCount: 8)
        let module = try await fixture.module(for: repository.url)
        _ = try await module.startBisect()
        _ = try await module.markBisect(.good, revisions: [repository.commits[0]])
        _ = try await module.markBisect(.bad, revisions: [repository.commits.last!])
        let skipped = try await module.loadBisectState().currentCommitID!
        let result = try await module.markBisect(.skip, revisions: [])
        try bisectRequire(result.outcome == .completed, "skip completes")
        let log = try fixture.readGitFile("BISECT_LOG", in: repository.url)
        try bisectRequire(log.contains("git bisect skip \(skipped.string)"), "skip records current revision")
        let state = try await module.loadBisectState()
        try bisectRequire(state.isActive, "skip retains active state")
        _ = try await module.resetBisect()
    }

    private static func testInvalidRevision() async throws {
        let fixture = try BisectFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.repository(named: "Invalid", commitCount: 4)
        let module = try await fixture.module(for: repository.url)
        _ = try await module.startBisect()
        let before = try fixture.readGitFile("BISECT_LOG", in: repository.url)
        do {
            _ = try await module.markBisect(.good, revisions: [bisectObjectID("missing")])
            throw BisectTestError("missing revision was accepted")
        } catch RepositoryMutationError.invalidRevision {}
        try bisectRequire(try fixture.readGitFile("BISECT_LOG", in: repository.url) == before, "invalid revision does not mutate bisect state")
        _ = try await module.resetBisect()
    }

    private static func testLifecycleAndBareValidation() async throws {
        let fixture = try BisectFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.repository(named: "Lifecycle", commitCount: 3)
        let module = try await fixture.module(for: repository.url)
        do {
            _ = try await module.markBisect(.good, revisions: [])
            throw BisectTestError("marking outside a bisect was accepted")
        } catch RepositoryBisectError.notInProgress {}
        do {
            _ = try await module.resetBisect()
            throw BisectTestError("reset outside a bisect was accepted")
        } catch RepositoryBisectError.notInProgress {}
        _ = try await module.startBisect()
        do {
            _ = try await module.startBisect()
            throw BisectTestError("a second bisect start was accepted")
        } catch RepositoryBisectError.alreadyInProgress {}
        _ = try await module.resetBisect()

        let bare = fixture.root.appendingPathComponent("Bare.git", isDirectory: true)
        try fixture.git(["clone", "--bare", repository.url.path, bare.path], in: fixture.root)
        let bareModule = try await fixture.module(for: bare)
        do {
            _ = try await bareModule.startBisect()
            throw BisectTestError("bare repository accepted bisect")
        } catch RepositoryMutationError.bareRepository {}
    }
}

private final class BisectFixture {
    struct RepositoryInfo { let url: URL; let commits: [ObjectID] }
    let root: URL

    private init(root: URL) { self.root = root }

    static func make() throws -> BisectFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitExtensionsMac-Bisect-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return BisectFixture(root: root)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func repository(named name: String, commitCount: Int) throws -> RepositoryInfo {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try git(["init", "-b", "main", url.path], in: root)
        try git(["config", "user.name", "Bisect Fixture"], in: url)
        try git(["config", "user.email", "bisect@example.com"], in: url)
        var commits: [ObjectID] = []
        for index in 0..<commitCount {
            try Data("revision \(index)\n".utf8).write(to: url.appendingPathComponent("tracked.txt"))
            try git(["add", "tracked.txt"], in: url)
            try git(["commit", "-m", "Revision \(index)"], in: url)
            commits.append(try objectID(["rev-parse", "HEAD"], in: url))
        }
        return RepositoryInfo(url: url, commits: commits)
    }

    func module(for repository: URL) async throws -> GitRepositoryModule {
        let module = GitRepositoryModule(repositoryURL: repository, git: GitProcess())
        _ = try await module.loadRepositoryState()
        return module
    }

    func existsGitFile(_ path: String, in repository: URL) -> Bool {
        guard let gitDirectory = try? git(["rev-parse", "--git-dir"], in: repository).trimmed else { return false }
        return FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: gitDirectory, relativeTo: repository)
                .standardizedFileURL.appendingPathComponent(path).path
        )
    }

    func readGitFile(_ path: String, in repository: URL) throws -> String {
        let gitDirectory = try git(["rev-parse", "--git-dir"], in: repository).trimmed
        let url = URL(fileURLWithPath: gitDirectory, relativeTo: repository)
            .standardizedFileURL.appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

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
            throw BisectTestError(
                "git \(arguments.joined(separator: " ")) failed: \(String(decoding: error, as: UTF8.self))"
            )
        }
        return String(decoding: output, as: UTF8.self)
    }
}

private struct BisectTestError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func bisectRequire(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw BisectTestError(message) }
}

private func bisectObjectID(_ seed: String) -> ObjectID {
    let scalar = seed.utf8.reduce(UInt64(5381)) { (($0 << 5) &+ $0) &+ UInt64($1) }
    return try! ObjectID.parse(String(format: "%040llx", scalar))
}

private func bisectCommit(_ objectID: ObjectID) -> Commit {
    Commit(
        id: .object(objectID),
        shortID: objectID.shortString,
        subject: "Bisect revision",
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
