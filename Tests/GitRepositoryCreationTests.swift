@testable import GitCommands
@testable import GitUI
import Foundation

enum GitRepositoryCreationTests {
    static func run() async throws {
        try testCommandConstructionAndNames()
        try await testCloneVariantsAndRemoteBranches()
        try await testRecursiveClone()
        try await testInitializeVariants()
        try await testValidationAndFailures()
        try await testCancellation()
        print("GitRepositoryCreationTests: passed")
    }

    private static func testCommandConstructionAndNames() throws {
        let destination = URL(fileURLWithPath: "/tmp/Clone Destination", isDirectory: true)
        let shallow = GitRepositoryCreationCommands.clone(
            source: "ssh://example/repository.git",
            destination: destination,
            isBare: true,
            initializesSubmodules: true,
            downloadsFullHistory: false,
            branch: .named("topic")
        )
        try creationRequire(shallow.arguments == [
            "clone", "-v", "--bare", "--recurse-submodules", "--depth", "1", "--no-single-branch",
            "--progress", "--branch", "topic", "ssh://example/repository.git", "/tmp/Clone Destination"
        ], "clone command preserves upstream argument ordering")
        try creationRequire(shallow.accessesRemote && shallow.changesRepositoryState, "remote clone metadata")

        let noCheckout = GitRepositoryCreationCommands.clone(
            source: "/tmp/source", destination: destination, isBare: false,
            initializesSubmodules: false, downloadsFullHistory: true, branch: .noCheckout
        )
        try creationRequire(noCheckout.arguments == [
            "clone", "-v", "--progress", "--no-checkout", "/tmp/source", "/tmp/Clone Destination"
        ], "no-checkout clone has exact arguments")
        try creationRequire(!noCheckout.accessesRemote && noCheckout.changesRepositoryState, "local clone metadata")
        let normalInit = GitRepositoryCreationCommands.initialize(isBare: false)
        let bareInit = GitRepositoryCreationCommands.initialize(isBare: true)
        try creationRequire(normalInit.arguments == ["init"] && !normalInit.accessesRemote && normalInit.changesRepositoryState, "personal init metadata")
        try creationRequire(bareInit.arguments == ["init", "--bare", "--shared=all"], "central init arguments")

        let creator = GitRepositoryCreator(git: GitProcess())
        try creationRequire(creator.suggestedCloneSubdirectory(for: "") == "", "empty source has no destination name")
        try creationRequire(creator.suggestedCloneSubdirectory(for: "https://example.test/team/repository.git") == "repository", "URL destination derivation")
        try creationRequire(creator.suggestedCloneSubdirectory(for: "git@example.test:repository.git") == "repository", "SCP destination derivation")
        try creationRequire(creator.suggestedCloneSubdirectory(for: "/tmp/local repository.git/") == "local repository", "local destination derivation")
        try creationRequire(
            CloneSourceParser.extract(from: "git clone https://github.com/gitextensions/gitextensions && cd gitextensions")
                == "https://github.com/gitextensions/gitextensions",
            "clipboard command extracts the first clone URL"
        )
        try creationRequire(CloneSourceParser.extract(from: "blah") == nil, "non-URL clipboard text is ignored")
    }

    private static func testCloneVariantsAndRemoteBranches() async throws {
        let fixture = try CreationFixture.make()
        defer { fixture.remove() }
        let creator = fixture.creator()

        let branches = try await creator.remoteBranches(at: fixture.bareRemote.path)
        try creationRequire(branches == ["feature/topic", "main"], "remote branch discovery returns sorted heads")

        let output = CreationOutputRecorder()
        let result = try await creator.clone(RepositoryCloneRequest(
            source: fixture.bareRemote.path,
            destinationParent: fixture.root,
            subdirectory: "Normal Clone",
            initializesSubmodules: false
        ), output: { event in output.append(event) })
        try creationRequire(!output.events.isEmpty, "clone streams process output")
        try creationRequire(result.command.executionClass == .local, "local clone retains local execution classification")
        try creationRequire(try fixture.git(["rev-parse", "--is-inside-work-tree"], in: result.repositoryURL).trimmed == "true", "normal clone creates a worktree")
        try creationRequire(try fixture.git(["config", "--get", "remote.origin.url"], in: result.repositoryURL).trimmed == fixture.bareRemote.path, "clone configures origin")

        let branchResult = try await creator.clone(RepositoryCloneRequest(
            source: fixture.bareRemote.path,
            destinationParent: fixture.root,
            subdirectory: "Feature Clone",
            initializesSubmodules: false,
            branch: .named("feature/topic")
        ), output: { _ in })
        try creationRequire(try fixture.git(["branch", "--show-current"], in: branchResult.repositoryURL).trimmed == "feature/topic", "specific branch is checked out")

        let noCheckout = try await creator.clone(RepositoryCloneRequest(
            source: fixture.bareRemote.path,
            destinationParent: fixture.root,
            subdirectory: "No Checkout",
            initializesSubmodules: false,
            branch: .noCheckout
        ), output: { _ in })
        try creationRequire(!FileManager.default.fileExists(atPath: noCheckout.repositoryURL.appendingPathComponent("main.txt").path), "no-checkout leaves the worktree empty")

        let shallow = try await creator.clone(RepositoryCloneRequest(
            source: fixture.bareRemote.absoluteString,
            destinationParent: fixture.root,
            subdirectory: "Shallow Clone",
            initializesSubmodules: false,
            downloadsFullHistory: false
        ), output: { _ in })
        try creationRequire(try fixture.git(["rev-list", "--count", "HEAD"], in: shallow.repositoryURL).trimmed == "1", "shallow clone has depth one")
        let shallowRemoteBranches = try fixture.git(["for-each-ref", "--format=%(refname:short)", "refs/remotes/origin"], in: shallow.repositoryURL)
        try creationRequire(shallowRemoteBranches.contains("origin/feature/topic"), "--no-single-branch keeps other remote branches")

        let bare = try await creator.clone(RepositoryCloneRequest(
            source: fixture.bareRemote.path,
            destinationParent: fixture.root,
            subdirectory: "Published.git",
            isBare: true,
            initializesSubmodules: false
        ), output: { _ in })
        try creationRequire(try fixture.git(["rev-parse", "--is-bare-repository"], in: bare.repositoryURL).trimmed == "true", "bare clone creates a bare repository")
        try creationRequire(!FileManager.default.fileExists(atPath: bare.repositoryURL.appendingPathComponent("main.txt").path), "bare clone has no worktree")
    }

    private static func testRecursiveClone() async throws {
        let fixture = try CreationFixture.make(includeSubmodule: true)
        defer { fixture.remove() }
        let result = try await fixture.creator(allowFileTransport: true).clone(RepositoryCloneRequest(
            source: fixture.source.path,
            destinationParent: fixture.root,
            subdirectory: "Recursive Clone",
            initializesSubmodules: true
        ), output: { _ in })
        let childFile = result.repositoryURL.appendingPathComponent("Dependencies/Child/child.txt")
        try creationRequire(FileManager.default.fileExists(atPath: childFile.path), "recursive clone initializes the submodule checkout")
    }

    private static func testInitializeVariants() async throws {
        let fixture = try CreationFixture.make()
        defer { fixture.remove() }
        let creator = fixture.creator()
        let normalURL = fixture.root.appendingPathComponent("Initialized", isDirectory: true)
        let normal = try await creator.initialize(RepositoryInitRequest(directory: normalURL), output: { _ in })
        try creationRequire(normal.command.executionClass == .local, "init retains local execution classification")
        try creationRequire(try fixture.git(["rev-parse", "--is-inside-work-tree"], in: normalURL).trimmed == "true", "personal init creates a worktree repository")

        let bareURL = fixture.root.appendingPathComponent("Central.git", isDirectory: true)
        _ = try await creator.initialize(RepositoryInitRequest(directory: bareURL, isBare: true), output: { _ in })
        try creationRequire(try fixture.git(["rev-parse", "--is-bare-repository"], in: bareURL).trimmed == "true", "central init is bare")
        try creationRequire(!(try fixture.git(["config", "--get", "core.sharedRepository"], in: bareURL).trimmed).isEmpty, "central init applies shared=all")

        _ = try await creator.initialize(RepositoryInitRequest(directory: normalURL), output: { _ in })
        try creationRequire(FileManager.default.fileExists(atPath: normalURL.appendingPathComponent(".git").path), "existing repositories are reinitialized like upstream")
    }

    private static func testValidationAndFailures() async throws {
        let fixture = try CreationFixture.make()
        defer { fixture.remove() }
        let creator = fixture.creator()
        do {
            _ = try await creator.clone(RepositoryCloneRequest(source: "", destinationParent: fixture.root, subdirectory: "Empty"), output: { _ in })
            throw CreationTestError("empty clone source was accepted")
        } catch RepositoryCreationError.emptySource {}
        do {
            _ = try await creator.clone(RepositoryCloneRequest(source: fixture.source.path, destinationParent: fixture.root, subdirectory: "bad/name"), output: { _ in })
            throw CreationTestError("invalid subdirectory was accepted")
        } catch RepositoryCreationError.invalidSubdirectory {}
        do {
            _ = try await creator.clone(RepositoryCloneRequest(
                source: fixture.root.appendingPathComponent("Missing.git").path,
                destinationParent: fixture.root,
                subdirectory: "Missing Source",
                initializesSubmodules: false
            ), output: { _ in })
            throw CreationTestError("missing clone source was accepted")
        } catch GitError.commandFailed {}

        let nonempty = fixture.root.appendingPathComponent("Nonempty", isDirectory: true)
        try FileManager.default.createDirectory(at: nonempty, withIntermediateDirectories: true)
        try Data("occupied".utf8).write(to: nonempty.appendingPathComponent("file.txt"))
        do {
            _ = try await creator.clone(RepositoryCloneRequest(source: fixture.source.path, destinationParent: fixture.root, subdirectory: "Nonempty", initializesSubmodules: false), output: { _ in })
            throw CreationTestError("clone accepted a nonempty destination")
        } catch GitError.commandFailed {}

        let file = fixture.root.appendingPathComponent("Not a directory")
        try Data().write(to: file)
        do {
            _ = try await creator.initialize(RepositoryInitRequest(directory: file), output: { _ in })
            throw CreationTestError("init accepted a file path")
        } catch RepositoryCreationError.destinationIsFile {}
    }

    private static func testCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-CreationCancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let creator = GitRepositoryCreator(git: CancellingCreationRunner(), executionDirectory: root)
        let task = Task {
            try await creator.clone(RepositoryCloneRequest(source: "https://example.invalid/repository.git", destinationParent: root, subdirectory: "Cancelled"), output: { _ in })
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        do {
            _ = try await task.value
            throw CreationTestError("cancelled clone completed")
        } catch is CancellationError {}
    }
}

private final class CancellingCreationRunner: GitCommandRunning, @unchecked Sendable {
    func run(arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String]) async throws -> GitCommandResult {
        try await Task.sleep(nanoseconds: 10_000_000_000)
        throw CancellationError()
    }

    func runStreaming(
        arguments: [String], in directory: URL, standardInput: Data?, environment: [String: String], output: @escaping GitOutputHandler
    ) async throws -> GitCommandResult {
        try await run(arguments: arguments, in: directory, standardInput: standardInput, environment: environment)
    }
}

private final class CreationOutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [GitOutputEvent] = []
    var events: [GitOutputEvent] { lock.withLock { storage } }
    func append(_ event: GitOutputEvent) { lock.withLock { storage.append(event) } }
}

private final class CreationFixture {
    let root: URL
    let source: URL
    let bareRemote: URL

    private init(root: URL, source: URL, bareRemote: URL) {
        self.root = root; self.source = source; self.bareRemote = bareRemote
    }

    static func make(includeSubmodule: Bool = false) throws -> CreationFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-Creation-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Source Repository", isDirectory: true)
        let bareRemote = root.appendingPathComponent("Remote Repository.git", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = CreationFixture(root: root, source: source, bareRemote: bareRemote)
        try fixture.git(["init", "-b", "main", source.path], in: root)
        try fixture.git(["config", "user.name", "Clone Fixture"], in: source)
        try fixture.git(["config", "user.email", "clone@example.com"], in: source)
        try Data("one\n".utf8).write(to: source.appendingPathComponent("main.txt"))
        try fixture.git(["add", "main.txt"], in: source)
        try fixture.git(["commit", "-m", "First"], in: source)
        try Data("two\n".utf8).write(to: source.appendingPathComponent("main.txt"))
        try fixture.git(["commit", "-am", "Second"], in: source)
        try fixture.git(["checkout", "-b", "feature/topic"], in: source)
        try Data("feature\n".utf8).write(to: source.appendingPathComponent("feature.txt"))
        try fixture.git(["add", "feature.txt"], in: source)
        try fixture.git(["commit", "-m", "Feature"], in: source)
        try fixture.git(["checkout", "main"], in: source)

        if includeSubmodule {
            let child = root.appendingPathComponent("Child", isDirectory: true)
            try fixture.git(["init", "-b", "main", child.path], in: root)
            try fixture.git(["config", "user.name", "Clone Fixture"], in: child)
            try fixture.git(["config", "user.email", "clone@example.com"], in: child)
            try Data("child\n".utf8).write(to: child.appendingPathComponent("child.txt"))
            try fixture.git(["add", "child.txt"], in: child)
            try fixture.git(["commit", "-m", "Child"], in: child)
            try fixture.git(["-c", "protocol.file.allow=always", "submodule", "add", child.path, "Dependencies/Child"], in: source)
            try fixture.git(["commit", "-am", "Submodule"], in: source)
        }
        try fixture.git(["clone", "--bare", source.path, bareRemote.path], in: root)
        return fixture
    }

    func creator(allowFileTransport: Bool = false) -> GitRepositoryCreator {
        GitRepositoryCreator(
            git: GitProcess(), executionDirectory: root,
            environment: allowFileTransport ? ["GIT_ALLOW_PROTOCOL": "file"] : [:]
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process(); let stdout = Pipe(); let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = arguments; process.currentDirectoryURL = directory
        process.standardOutput = stdout; process.standardError = stderr
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"; environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        try process.run(); process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw CreationTestError("git \(arguments.joined(separator: " ")) failed: \(String(decoding: error, as: UTF8.self))")
        }
        return String(decoding: output, as: UTF8.self)
    }
}

private struct CreationTestError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func creationRequire(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CreationTestError(message) }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
