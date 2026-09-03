@testable import GitExtensionsCore
@testable import GitCommands
import Foundation

enum GitCleanTests {
    static func run() async throws {
        try testCommandConstruction()
        try await testUntrackedAndIgnoredModes()
        try await testPathFiltersAndUnicode()
        try await testNestedRepositoryProtection()
        try await testRecursiveSubmoduleCleaning()
        try await testEmptyAndBareRepositories()
        print("GitCleanTests: passed")
    }

    private static func testCommandConstruction() throws {
        let defaults = RepositoryCleanRequest()
        let preview = GitCleanCommands.clean(defaults, dryRun: true)
        try cleanRequire(preview.arguments == ["clean", "-x", "-d", "--dry-run"], "default preview arguments")
        try cleanRequire(!preview.accessesRemote && !preview.changesRepositoryState, "preview metadata")

        let cleanup = GitCleanCommands.clean(defaults, dryRun: false)
        try cleanRequire(cleanup.arguments == ["clean", "-x", "-d", "-f"], "default cleanup arguments")
        try cleanRequire(!cleanup.accessesRemote && cleanup.changesRepositoryState, "cleanup metadata")

        let nonIgnored = GitCleanCommands.clean(.init(mode: .onlyNonIgnored, removeDirectories: false), dryRun: true)
        try cleanRequire(nonIgnored.arguments == ["clean", "--dry-run"], "non-ignored arguments omit a mode switch")

        let ignored = GitCleanCommands.clean(.init(mode: .onlyIgnored, removeDirectories: false), dryRun: false)
        try cleanRequire(ignored.arguments == ["clean", "-X", "-f"], "ignored-only arguments")

        let filtered = RepositoryCleanRequest(
            mode: .all,
            removeDirectories: true,
            cleanSubmodules: true,
            includePaths: ["folder with space", "unicodé.txt", ""],
            excludePaths: ["keep this.txt", #"nested\keep.txt"#, ""]
        )
        let filteredCommand = GitCleanCommands.clean(filtered, dryRun: false)
        try cleanRequire(
            filteredCommand.arguments == [
                "clean", "-x", "-d", "-f",
                "folder with space", "unicodé.txt",
                "--exclude=keep?this.txt", "--exclude=nested/keep.txt"
            ],
            "path arguments preserve ordering and use upstream exclude normalization"
        )
        let submodules = GitCleanCommands.cleanSubmodules(filtered, dryRun: true)
        try cleanRequire(
            submodules.arguments == [
                "submodule", "foreach", "--recursive", "git", "clean",
                "-x", "-d", "--dry-run", "folder with space", "unicodé.txt"
            ],
            "submodule arguments preserve upstream ordering and omit excludes"
        )
        try cleanRequire(!submodules.accessesRemote && !submodules.changesRepositoryState, "submodule preview metadata")
    }

    private static func testUntrackedAndIgnoredModes() async throws {
        let fixture = try CleanFixture.make()
        defer { fixture.remove() }

        let nonIgnoredURL = try fixture.repository(named: "NonIgnored")
        try fixture.populateUntrackedState(in: nonIgnoredURL)
        let nonIgnoredModule = try await fixture.module(for: nonIgnoredURL)
        let preview = try await nonIgnoredModule.previewClean(.init(mode: .onlyNonIgnored, removeDirectories: true))
        try cleanRequire(preview.hasCandidates, "non-ignored preview finds candidates")
        try cleanRequire(preview.output.contains("loose.txt"), "preview is produced by git clean")
        try cleanRequire(!preview.output.contains("ignored.ignored"), "non-ignored preview excludes ignored files")
        let nonIgnoredResult = try await nonIgnoredModule.clean(.init(mode: .onlyNonIgnored, removeDirectories: true))
        try cleanRequire(nonIgnoredResult.didChange, "non-ignored cleanup reports a mutation")
        try cleanRequire(!fixture.exists("loose.txt", in: nonIgnoredURL), "ordinary untracked file removed")
        try cleanRequire(!fixture.exists("untracked directory", in: nonIgnoredURL), "untracked directory removed when requested")
        try cleanRequire(fixture.exists("ignored.ignored", in: nonIgnoredURL), "ignored file preserved")
        try cleanRequire(fixture.exists("ignored directory", in: nonIgnoredURL), "ignored directory preserved")

        let ignoredURL = try fixture.repository(named: "Ignored")
        try fixture.populateUntrackedState(in: ignoredURL)
        let ignoredModule = try await fixture.module(for: ignoredURL)
        let ignoredResult = try await ignoredModule.clean(.init(mode: .onlyIgnored, removeDirectories: true))
        try cleanRequire(ignoredResult.didChange, "ignored-only cleanup reports a mutation")
        try cleanRequire(fixture.exists("loose.txt", in: ignoredURL), "ordinary untracked file preserved by ignored-only mode")
        try cleanRequire(fixture.exists("untracked directory", in: ignoredURL), "ordinary untracked directory preserved")
        try cleanRequire(!fixture.exists("ignored.ignored", in: ignoredURL), "ignored file removed")
        try cleanRequire(!fixture.exists("ignored directory", in: ignoredURL), "ignored directory removed")

        let filesOnlyURL = try fixture.repository(named: "FilesOnly")
        try fixture.populateUntrackedState(in: filesOnlyURL)
        let filesOnlyModule = try await fixture.module(for: filesOnlyURL)
        _ = try await filesOnlyModule.clean(.init(mode: .all, removeDirectories: false))
        try cleanRequire(!fixture.exists("loose.txt", in: filesOnlyURL), "files-only mode removes a root file")
        try cleanRequire(fixture.exists("untracked directory", in: filesOnlyURL), "files-only mode preserves an untracked directory")
        try cleanRequire(fixture.exists("ignored directory", in: filesOnlyURL), "files-only mode preserves an ignored directory")
    }

    private static func testPathFiltersAndUnicode() async throws {
        let fixture = try CleanFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.repository(named: "Path Filters")
        try fixture.write("remove\n", to: repository.appendingPathComponent("remove ü.txt"))
        try fixture.write("keep\n", to: repository.appendingPathComponent("keep me.txt"))
        try fixture.write("outside\n", to: repository.appendingPathComponent("outside.txt"))
        let module = try await fixture.module(for: repository)
        let request = RepositoryCleanRequest(
            mode: .all,
            removeDirectories: true,
            includePaths: ["remove ü.txt", "keep me.txt"],
            excludePaths: ["keep me.txt"]
        )
        let preview = try await module.previewClean(request)
        try cleanRequire(preview.hasCandidates && preview.output.contains("remove \\303\\274.txt"), "preview retains Unicode path identity")
        _ = try await module.clean(request)
        try cleanRequire(!fixture.exists("remove ü.txt", in: repository), "included Unicode/spaced path removed")
        try cleanRequire(fixture.exists("keep me.txt", in: repository), "question-mark exclude preserves spaced path")
        try cleanRequire(fixture.exists("outside.txt", in: repository), "path filter preserves paths outside the selection")
    }

    private static func testNestedRepositoryProtection() async throws {
        let fixture = try CleanFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.repository(named: "Nested")
        let nested = repository.appendingPathComponent("nested repository", isDirectory: true)
        try fixture.git(["init", "-b", "main", nested.path], in: fixture.root)
        try fixture.write("nested\n", to: nested.appendingPathComponent("content.txt"))
        try fixture.write("ordinary\n", to: repository.appendingPathComponent("ordinary.txt"))
        let module = try await fixture.module(for: repository)
        let result = try await module.clean(.init(mode: .all, removeDirectories: true))
        try cleanRequire(result.didChange, "clean removes the ordinary candidate")
        try cleanRequire(!fixture.exists("ordinary.txt", in: repository), "ordinary untracked file removed beside nested repository")
        try cleanRequire(FileManager.default.fileExists(atPath: nested.appendingPathComponent(".git").path), "single-force Git clean protects nested repository")
        try cleanRequire(FileManager.default.fileExists(atPath: nested.appendingPathComponent("content.txt").path), "nested repository contents remain")
    }

    private static func testRecursiveSubmoduleCleaning() async throws {
        let fixture = try CleanFixture.make()
        defer { fixture.remove() }
        let submoduleSource = try fixture.repository(named: "Submodule Source")
        let repository = try fixture.repository(named: "Superproject")
        try fixture.git(
            ["-c", "protocol.file.allow=always", "submodule", "add", submoduleSource.path, "nested module"],
            in: repository
        )
        try fixture.git(["commit", "-am", "Add submodule"], in: repository)
        let nestedFile = repository.appendingPathComponent("nested module/untracked.txt")
        try fixture.write("nested\n", to: nestedFile)
        let module = try await fixture.module(for: repository)

        let mainOnlyPreview = try await module.previewClean(.init(cleanSubmodules: false))
        try cleanRequire(!mainOnlyPreview.hasCandidates, "tracked submodule is not a main-repository clean candidate")
        let recursivePreview = try await module.previewClean(.init(cleanSubmodules: true))
        try cleanRequire(recursivePreview.hasCandidates && recursivePreview.output.contains("untracked.txt"), "recursive preview finds submodule candidates")
        let result = try await module.clean(.init(cleanSubmodules: true))
        try cleanRequire(result.didChange, "recursive submodule clean reports a mutation")
        try cleanRequire(!FileManager.default.fileExists(atPath: nestedFile.path), "recursive submodule clean removes nested untracked file")
    }

    private static func testEmptyAndBareRepositories() async throws {
        let fixture = try CleanFixture.make()
        defer { fixture.remove() }
        let repository = try fixture.repository(named: "Empty")
        let module = try await fixture.module(for: repository)
        let preview = try await module.previewClean(.init())
        try cleanRequire(!preview.hasCandidates, "empty preview has no candidates")
        let result = try await module.clean(.init())
        try cleanRequire(result.outcome == .noChanges && !result.didChange, "empty cleanup is a notifier-safe no-op")

        let bare = fixture.root.appendingPathComponent("Bare.git", isDirectory: true)
        try fixture.git(["clone", "--bare", repository.path, bare.path], in: fixture.root)
        let bareModule = try await fixture.module(for: bare)
        do {
            _ = try await bareModule.previewClean(.init())
            throw CleanTestError("bare repository accepted Clean")
        } catch RepositoryMutationError.bareRepository {}
    }
}

private final class CleanFixture {
    let root: URL

    private init(root: URL) { self.root = root }

    static func make() throws -> CleanFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-Clean-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return CleanFixture(root: root)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func repository(named name: String) throws -> URL {
        let repository = root.appendingPathComponent(name, isDirectory: true)
        try git(["init", "-b", "main", repository.path], in: root)
        try git(["config", "user.name", "Clean Fixture"], in: repository)
        try git(["config", "user.email", "clean@example.com"], in: repository)
        try write("*.ignored\nignored directory/\n", to: repository.appendingPathComponent(".gitignore"))
        try write("tracked\n", to: repository.appendingPathComponent("tracked.txt"))
        try git(["add", ".gitignore", "tracked.txt"], in: repository)
        try git(["commit", "-m", "Initial"], in: repository)
        return repository
    }

    func populateUntrackedState(in repository: URL) throws {
        try write("loose\n", to: repository.appendingPathComponent("loose.txt"))
        try write("ignored\n", to: repository.appendingPathComponent("ignored.ignored"))
        let ordinaryDirectory = repository.appendingPathComponent("untracked directory", isDirectory: true)
        let ignoredDirectory = repository.appendingPathComponent("ignored directory", isDirectory: true)
        try FileManager.default.createDirectory(at: ordinaryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)
        try write("ordinary\n", to: ordinaryDirectory.appendingPathComponent("child.txt"))
        try write("ignored\n", to: ignoredDirectory.appendingPathComponent("child.txt"))
    }

    func module(for repository: URL) async throws -> GitRepositoryModule {
        let module = GitRepositoryModule(repositoryURL: repository, git: GitProcess())
        _ = try await module.loadRepositoryState()
        return module
    }

    func exists(_ path: String, in repository: URL) -> Bool {
        FileManager.default.fileExists(atPath: repository.appendingPathComponent(path).path)
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
            throw CleanTestError("git \(arguments.joined(separator: " ")) failed: \(String(decoding: error, as: UTF8.self))")
        }
        return String(decoding: output, as: UTF8.self)
    }
}

private struct CleanTestError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func cleanRequire(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CleanTestError(message) }
}
