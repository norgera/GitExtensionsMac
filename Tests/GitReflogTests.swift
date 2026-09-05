@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import Foundation

enum GitReflogTests {
    static func run() async throws {
        try testSelectorAndParser()
        try testCommandsAndEligibility()
        try await testRepositoryOrderingAndMovement()
        try await testDeletedBranchAndBareRepository()
        print("GitReflogTests: passed")
    }

    private static func testSelectorAndParser() throws {
        let first = reflogObjectID("first")
        let second = reflogObjectID("second")
        let output = """
        \(first.string) HEAD@{0}: reset: moving to HEAD~1
        malformed line
        \(second.string) refs/heads/main@{12}: commit: subject: with colon
        invalid HEAD@{2}: ignored

        """
        let entries = GitReflogParser.parse(output)
        try reflogRequire(entries.count == 2, "malformed reflog lines are ignored")
        try reflogRequire(entries[0].objectID == first, "first object ID")
        try reflogRequire(entries[0].selector.reference == "HEAD" && entries[0].selector.index == 0, "HEAD selector metadata")
        try reflogRequire(entries[0].action == "reset: moving to HEAD~1", "action preserves colon text")
        try reflogRequire(entries[1].objectID == second, "second object ID")
        try reflogRequire(entries[1].selector.reference == "refs/heads/main" && entries[1].selector.index == 12, "branch selector metadata")
        try reflogRequire(entries[1].selector.rawValue == "refs/heads/main@{12}", "selector round trip")
        try reflogRequire(GitReflogParser.parse("").isEmpty, "empty output")
        try reflogRequire(RepositoryReflogSelector(rawValue: "HEAD@{x}") == nil, "invalid selector index")
    }

    private static func testCommandsAndEligibility() throws {
        let revisionID = reflogObjectID("revision")
        try reflogRequire(
            GitReflogCommands.entries(reference: "origin/main").arguments
                == ["reflog", "--no-abbrev", "origin/main"],
            "exact reflog arguments"
        )
        try reflogRequire(
            GitReflogCommands.revision(revisionID).arguments == [
                "log", "-z", "-1",
                "--format=%H%x00%P%x00%at%x00%ct%x00%aN%x00%aE%x00%cN%x00%cE%x00%B",
                revisionID.string
            ],
            "exact reflog action revision arguments"
        )
        for command in [
            GitReflogCommands.currentBranch,
            GitReflogCommands.references,
            GitReflogCommands.status,
            GitReflogCommands.entries(reference: "HEAD"),
            GitReflogCommands.revision(revisionID)
        ] {
            try reflogRequire(!command.accessesRemote && !command.changesRepositoryState, "reflog reads are local and read-only")
        }
        try reflogRequire(
            ReflogActionEligibility(hasSelection: true, isBranchCheckedOut: true)
                == .init(hasSelection: true, isBranchCheckedOut: true),
            "eligibility equality"
        )
        let detached = ReflogActionEligibility(hasSelection: true, isBranchCheckedOut: false)
        try reflogRequire(detached.canCopyObjectID && detached.canCreateBranch && !detached.canResetCurrentBranch, "detached action eligibility")
        let empty = ReflogActionEligibility(hasSelection: false, isBranchCheckedOut: true)
        try reflogRequire(!empty.canCopyObjectID && !empty.canCreateBranch && !empty.canResetCurrentBranch, "empty selection eligibility")
    }

    private static func testRepositoryOrderingAndMovement() async throws {
        let fixture = try ReflogFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.repository(named: "Movement", commitCount: 4)
        try fixture.git(["branch", "feature", repository.commits[1].string], in: repository.url)
        try fixture.git(["update-ref", "refs/remotes/origin/main", repository.commits[3].string], in: repository.url)
        try fixture.git(["checkout", "feature"], in: repository.url)
        try fixture.git(["checkout", "main"], in: repository.url)
        try fixture.git(["reset", "--hard", repository.commits[1].string], in: repository.url)

        let module = try await fixture.module(for: repository.url)
        let context = try await module.loadReflogContext()
        try reflogRequire(context.references == ["HEAD", "feature", "main", "origin/main"], "HEAD/local/remote reference ordering")
        try reflogRequire(context.currentBranch == "main" && !context.isBare, "current branch context")

        let entries = try await module.loadReflog(reference: "HEAD")
        try reflogRequire(!entries.isEmpty, "HEAD reflog entries")
        try reflogRequire(entries.map(\.selector.index) == Array(0..<entries.count), "newest-first selector ordering")
        try reflogRequire(entries[0].objectID == repository.commits[1], "reset target is newest reflog entry")
        try reflogRequire(entries.contains { $0.action.hasPrefix("checkout:") }, "checkout movement is parsed")
        try reflogRequire(entries.contains { $0.action.hasPrefix("reset:") }, "reset movement is parsed")

        let branchEntries = try await module.loadReflog(reference: "main")
        try reflogRequire(branchEntries.first?.selector.reference == "main", "selected branch reflog semantics")
        let loadedRevision = try await module.loadReflogRevision(repository.commits[2])
        try reflogRequire(
            loadedRevision.objectID == repository.commits[2]
                && loadedRevision.subject == "Revision 2"
                && loadedRevision.authorName == "Reflog Fixture",
            "reflog action loads complete revision metadata"
        )

        try Data("dirty\n".utf8).write(to: repository.url.appendingPathComponent("untracked file.txt"))
        let dirty = try await module.loadReflogContext()
        try reflogRequire(dirty.isDirty, "dirty working directory detection")

        try fixture.git(["checkout", "--detach", "HEAD"], in: repository.url)
        let detached = try await module.loadReflogContext()
        try reflogRequire(detached.currentBranch == nil && !detached.isBare, "detached HEAD context")
    }

    private static func testDeletedBranchAndBareRepository() async throws {
        let fixture = try ReflogFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.repository(named: "Deleted", commitCount: 3)
        try fixture.git(["branch", "temporary", repository.commits[1].string], in: repository.url)
        try fixture.git(["branch", "-D", "temporary"], in: repository.url)
        let module = try await fixture.module(for: repository.url)
        let context = try await module.loadReflogContext()
        try reflogRequire(!context.references.contains("temporary"), "deleted branch is absent from selectable refs")
        let headEntries = try await module.loadReflog(reference: "HEAD")
        try reflogRequire(!headEntries.isEmpty, "HEAD reflog survives branch deletion")
        do {
            _ = try await module.loadReflog(reference: "temporary")
            throw ReflogTestError("missing branch reflog was accepted")
        } catch let error as RepositoryReflogError {
            try reflogRequire(error == .invalidReference("temporary"), "missing branch error")
        }

        let bare = fixture.root.appendingPathComponent("Bare.git", isDirectory: true)
        try fixture.git(["clone", "--bare", repository.url.path, bare.path], in: fixture.root)
        let bareModule = try await fixture.module(for: bare)
        let bareContext = try await bareModule.loadReflogContext()
        try reflogRequire(bareContext.isBare && !bareContext.isDirty, "bare repository read context")
    }
}

private final class ReflogFixture {
    struct RepositoryInfo { let url: URL; let commits: [ObjectID] }
    let root: URL

    private init(root: URL) { self.root = root }

    static func make() throws -> ReflogFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitExtensionsMac-Reflog-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ReflogFixture(root: root)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func repository(named name: String, commitCount: Int) throws -> RepositoryInfo {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try git(["init", "-b", "main", url.path], in: root)
        try git(["config", "user.name", "Reflog Fixture"], in: url)
        try git(["config", "user.email", "reflog@example.com"], in: url)
        var commits: [ObjectID] = []
        for index in 0..<commitCount {
            try Data("revision \(index)\n".utf8).write(to: url.appendingPathComponent("tracked.txt"))
            try git(["add", "tracked.txt"], in: url)
            try git(["commit", "-m", "Revision \(index)"], in: url)
            commits.append(try ObjectID.parse(git(["rev-parse", "HEAD"], in: url).trimmed))
        }
        return RepositoryInfo(url: url, commits: commits)
    }

    func module(for repository: URL) async throws -> GitRepositoryModule {
        let module = GitRepositoryModule(repositoryURL: repository, git: GitProcess())
        _ = try await module.loadRepositoryState()
        return module
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
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw ReflogTestError("git \(arguments.joined(separator: " ")) failed: \(String(decoding: error, as: UTF8.self))")
        }
        return String(decoding: output, as: UTF8.self)
    }
}

private struct ReflogTestError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func reflogRequire(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw ReflogTestError(message) }
}

private func reflogObjectID(_ seed: String) -> ObjectID {
    let scalar = seed.utf8.reduce(UInt64(5381)) { (($0 << 5) &+ $0) &+ UInt64($1) }
    return try! ObjectID.parse(String(format: "%040llx", scalar))
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
