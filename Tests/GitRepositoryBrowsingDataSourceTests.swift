import Foundation

enum GitRepositoryBrowsingDataSourceTests {
    static func run() async throws {
        let fixture = try GitFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let source = GitRepositoryBrowsingDataSource(repositoryURL: fixture.repositoryURL)
        let snapshot = try await source.loadSnapshot()
        let actualHead = try fixture.git(["rev-parse", "HEAD"], in: fixture.repositoryURL).trimmingCharacters(in: .whitespacesAndNewlines)
        let failedCommand = try await GitProcess().run(arguments: ["definitely-not-a-git-command"], in: fixture.repositoryURL)

        let concurrentGit = GitProcess()
        async let branchResult = concurrentGit.run(arguments: ["branch", "--show-current"], in: fixture.repositoryURL)
        async let headResult = concurrentGit.run(arguments: ["rev-parse", "--verify", "HEAD"], in: fixture.repositoryURL)
        async let statusResult = concurrentGit.run(
            arguments: ["--no-optional-locks", "status", "--porcelain=2", "-z", "--untracked-files=normal"],
            in: fixture.repositoryURL
        )
        let concurrentResults = try await [branchResult, headResult, statusResult]

        require(failedCommand.exitStatus != 0 && failedCommand.standardOutput.isEmpty && !failedCommand.standardError.isEmpty, "real Git: process result keeps status/stdout/stderr separate")
        require(concurrentResults.allSatisfy(\.succeeded), "real Git: concurrent process execution drains stdout/stderr without deadlocking")
        require(snapshot.currentRepository.path == fixture.repositoryURL.path, "real Git: path containing spaces is preserved")
        require(snapshot.commits.contains { $0.id == actualHead }, "real Git: HEAD is loaded")
        require(snapshot.commits.contains { $0.subject == "Merge feature" && $0.parentIDs.count == 2 }, "real Git: merge topology is loaded")
        require(snapshot.commits.contains { $0.authorName == "Fixture Author" && $0.authorEmail == "fixture@example.com" }, "real Git: author metadata is loaded")
        require(snapshot.branches.contains { $0.name == "main" && $0.remoteName == "origin" }, "real Git: explicit tracking relationship is loaded")
        let expectedRemotePath = fixture.rootURL.appendingPathComponent("Fixture remote.git").path
        require(snapshot.remotes.contains { $0.name == "origin" && $0.fetchURL == expectedRemotePath }, "real Git: remote URL containing spaces is loaded")
        require(snapshot.remotes.flatMap(\.branches).contains { $0.name == "main" }, "real Git: remote-tracking branch is loaded")
        require(snapshot.tags.contains { $0.name == "v1.0" }, "real Git: annotated tag is peeled to its commit")
        require(snapshot.stashes.count == 1 && snapshot.commits.contains { $0.id == snapshot.stashes[0].commitID }, "real Git: stash and stash revision are loaded")
        require(snapshot.worktrees.count >= 2 && snapshot.worktrees.contains { $0.branchName == "worktree-branch" }, "real Git: linked worktree is loaded")
        require(snapshot.submodules.contains { $0.path == "Modules/Test Submodule" }, "real Git: submodule metadata is loaded")
        require(snapshot.branches.allSatisfy { !$0.isCurrent }, "real Git: detached HEAD has no current branch")
        require(snapshot.commits.contains { $0.id == actualHead && $0.isHEAD }, "real Git: detached HEAD still marks the checked-out revision")
        require(snapshot.commits.contains { $0.kind == .workingDirectory } && snapshot.commits.contains { $0.kind == .index }, "real Git: artificial revisions are present")

        let feature = try required(snapshot.commits.first { $0.subject == "Feature changes" }, "real Git: feature commit exists")
        let featureDetails = try await source.loadRevisionDetails(for: feature)
        require(featureDetails.files.contains { $0.changeType == .renamed && $0.path == "renamed file.txt" && $0.oldPath == "rename-me.txt" }, "real Git: renamed path is parsed")
        require(featureDetails.files.contains { $0.changeType == .deleted && $0.path == "delete-me.txt" }, "real Git: deleted path is parsed")
        require(featureDetails.files.contains { $0.path == "binary.dat" }, "real Git: binary path is parsed")
        let renamedChangedFile = try required(featureDetails.files.first { $0.path == "renamed file.txt" }, "real Git: renamed changed file exists")
        let renamedDiff = try await source.loadDiff(for: feature, file: renamedChangedFile)
        require(renamedDiff?.lines.isEmpty == false, "real Git: unified rename diff is parsed lazily")
        let featureTree = try await source.loadRepositoryFiles(for: feature)
        require(featureTree.contains { $0.path == "renamed file.txt" }, "real Git: complete revision file tree is loaded on demand")
        require(!featureTree.contains { $0.path == "delete-me.txt" }, "real Git: deleted file is absent from revision tree")

        let renamedEntry = try required(featureTree.first { $0.path == "renamed file.txt" }, "real Git: renamed tree entry exists")
        let renamedContent = try await source.loadFileContent(for: feature, file: renamedEntry)
        require(renamedContent.content.contains("renamed content"), "real Git: blob content is loaded lazily")

        let indexCommit = try required(snapshot.commits.first { $0.kind == .index }, "real Git: index revision exists")
        let indexDetails = try await source.loadRevisionDetails(for: indexCommit)
        require(indexDetails.files.contains { $0.path == "staged.txt" && $0.changeType == .added }, "real Git: staged state populates Commit index")

        let worktreeCommit = try required(snapshot.commits.first { $0.kind == .workingDirectory }, "real Git: worktree revision exists")
        let worktreeDetails = try await source.loadRevisionDetails(for: worktreeCommit)
        require(worktreeDetails.files.contains { $0.path == "working.txt" && $0.changeType == .added }, "real Git: untracked state populates Working directory")
        require(worktreeDetails.files.contains { $0.path == "base.txt" && $0.changeType == .deleted }, "real Git: unstaged deletion populates Working directory")
        let worktreeTree = try await source.loadRepositoryFiles(for: worktreeCommit)
        require(!worktreeTree.contains { $0.path == "base.txt" }, "real Git: a worktree-deleted file is absent from the working file tree")

        let realCommits = snapshot.commits.filter { !$0.isArtificial }
        let graph = RevisionGraphLayout.build(commits: realCommits)
        require(graph.rows.count == realCommits.count && graph.maximumLaneCount >= 2, "real Git: existing graph layout consumes real topology")

        let switched = try await source.openRepository(at: fixture.submoduleRepositoryURL)
        require(switched.currentRepository.path == fixture.submoduleRepositoryURL.path, "real Git: repository switching replaces the snapshot")
        require(switched.commits.contains { $0.subject == "Submodule initial" }, "real Git: switched repository history is loaded")
    }

    static func verifyRealRepository(at repositoryURL: URL) async throws {
        let git = GitProcess()
        let before = try await fingerprint(git: git, repositoryURL: repositoryURL)
        let started = Date()
        let source = GitRepositoryBrowsingDataSource(repositoryURL: repositoryURL, git: git)
        let snapshot = try await source.loadSnapshot()
        let snapshotSeconds = Date().timeIntervalSince(started)

        let selected = snapshot.commits.first(where: \.isHEAD)
            ?? snapshot.commits.first(where: { !$0.isArtificial })
        let detailStarted = Date()
        let details: RepositoryRevisionDetails?
        if let selected {
            details = try await source.loadRevisionDetails(for: selected)
        } else {
            details = nil
        }
        let detailSeconds = Date().timeIntervalSince(detailStarted)
        let treeStarted = Date()
        let tree = if let selected { try await source.loadRepositoryFiles(for: selected) } else { [] }
        let treeSeconds = Date().timeIntervalSince(treeStarted)
        let after = try await fingerprint(git: git, repositoryURL: repositoryURL)
        guard before == after else {
            throw FixtureError("Read-only verification changed HEAD, refs, or working-tree status for \(repositoryURL.path)")
        }

        let expectedHistory = try await git.run(
            arguments: ["rev-list", "--count", "--branches", "--remotes", "--tags", "HEAD"],
            in: repositoryURL
        ).standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        let loadedHistory = snapshot.commits.filter { !$0.isArtificial && $0.references.allSatisfy { $0.kind != .stash } }.count
        let mergeCount = snapshot.commits.filter { !$0.isArtificial && $0.parentIDs.count > 1 }.count
        print(
            "READ_ONLY_VERIFY path=\(repositoryURL.path) " +
            "snapshot=\(String(format: "%.3f", snapshotSeconds))s " +
            "details=\(String(format: "%.3f", detailSeconds))s " +
            "tree=\(String(format: "%.3f", treeSeconds))s " +
            "commits=\(loadedHistory)/\(expectedHistory) merges=\(mergeCount) " +
            "local=\(snapshot.branches.count) remote=\(snapshot.remotes.flatMap(\.branches).count) " +
            "tags=\(snapshot.tags.count) stashes=\(snapshot.stashes.count) " +
            "worktrees=\(snapshot.worktrees.count) submodules=\(snapshot.submodules.count) " +
            "headFiles=\(details?.files.count ?? 0) treeFiles=\(tree.count) unchanged=true"
        )
    }


    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    private static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw FixtureError(message) }
        return value
    }

    private static func fingerprint(git: GitProcess, repositoryURL: URL) async throws -> Data {
        var data = Data()
        for arguments in [
            ["rev-parse", "HEAD"],
            ["--no-optional-locks", "for-each-ref", "--format=%(refname)%00%(objectname)%00"],
            ["--no-optional-locks", "status", "--porcelain=2", "-z", "--untracked-files=normal"],
            ["stash", "list", "--format=%gd%x00%H", "-z"],
            ["worktree", "list", "--porcelain", "-z"]
        ] {
            let result = try await git.run(arguments: arguments, in: repositoryURL)
            guard result.exitStatus == 0 else {
                throw FixtureError("Fingerprint command failed: git \(arguments.joined(separator: " "))")
            }
            data.append(result.standardOutput)
            data.append(0xff)
        }
        return data
    }
}

private struct FixtureError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct GitFixture {
    let rootURL: URL
    let repositoryURL: URL
    let submoduleRepositoryURL: URL

    static func make() throws -> GitFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitExtensionsMac-read-only-tests-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("Fixture repo with spaces", isDirectory: true)
        let remote = root.appendingPathComponent("Fixture remote.git", isDirectory: true)
        let submodule = root.appendingPathComponent("Submodule source", isDirectory: true)
        let linkedWorktree = root.appendingPathComponent("Linked worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: submodule, withIntermediateDirectories: true)

        let fixture = GitFixture(rootURL: root, repositoryURL: repository, submoduleRepositoryURL: submodule)

        try fixture.git(["init", "--initial-branch=main"], in: submodule)
        try fixture.configureIdentity(in: submodule)
        try fixture.write("submodule\n", to: submodule.appendingPathComponent("submodule.txt"))
        try fixture.git(["add", "submodule.txt"], in: submodule)
        try fixture.commit("Submodule initial", number: 1, in: submodule)

        try fixture.git(["init", "--bare", remote.path], in: root)
        try fixture.git(["init", "--initial-branch=main"], in: repository)
        try fixture.configureIdentity(in: repository)
        try fixture.write("base\n", to: repository.appendingPathComponent("base.txt"))
        try fixture.write("delete me\n", to: repository.appendingPathComponent("delete-me.txt"))
        try fixture.write("rename me\nline two\nline three\nline four\n", to: repository.appendingPathComponent("rename-me.txt"))
        try fixture.git(["add", "."], in: repository)
        try fixture.commit("Initial", number: 2, in: repository)

        try fixture.git(["checkout", "-b", "feature/topic"], in: repository)
        try FileManager.default.moveItem(
            at: repository.appendingPathComponent("rename-me.txt"),
            to: repository.appendingPathComponent("renamed file.txt")
        )
        try fixture.write("rename me\nline two\nline three\nline four\nrenamed content\n", to: repository.appendingPathComponent("renamed file.txt"))
        try FileManager.default.removeItem(at: repository.appendingPathComponent("delete-me.txt"))
        try fixture.write(Data([0, 1, 2, 3, 255]), to: repository.appendingPathComponent("binary.dat"))
        try fixture.git(["add", "-A"], in: repository)
        try fixture.commit("Feature changes", number: 3, in: repository)

        try fixture.git(["checkout", "main"], in: repository)
        try fixture.write("base\nmain update\n", to: repository.appendingPathComponent("base.txt"))
        try fixture.git(["add", "base.txt"], in: repository)
        try fixture.commit("Main update", number: 4, in: repository)
        try fixture.git(["merge", "--no-ff", "feature/topic", "-m", "Merge feature"], in: repository, dateNumber: 5)
        try fixture.git(["tag", "-a", "v1.0", "-m", "Version 1.0"], in: repository, dateNumber: 6)

        try fixture.git(["remote", "add", "origin", remote.path], in: repository)
        try fixture.git(["push", "-u", "origin", "main"], in: repository)

        try fixture.write("stashed\n", to: repository.appendingPathComponent("stash.txt"))
        try fixture.git(["add", "stash.txt"], in: repository)
        try fixture.git(["stash", "push", "-m", "fixture stash"], in: repository, dateNumber: 7)

        try fixture.git(["worktree", "add", "-b", "worktree-branch", linkedWorktree.path], in: repository)
        try fixture.git(["-c", "protocol.file.allow=always", "submodule", "add", submodule.path, "Modules/Test Submodule"], in: repository)
        try fixture.git(["add", ".gitmodules", "Modules/Test Submodule"], in: repository)
        try fixture.commit("Add submodule", number: 8, in: repository)
        try fixture.git(["checkout", "--detach", "HEAD"], in: repository)

        try fixture.write("staged\n", to: repository.appendingPathComponent("staged.txt"))
        try fixture.git(["add", "staged.txt"], in: repository)
        try fixture.write("working\n", to: repository.appendingPathComponent("working.txt"))
        try FileManager.default.removeItem(at: repository.appendingPathComponent("base.txt"))
        return fixture
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL, dateNumber: Int? = nil) throws -> String {
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
        if let dateNumber {
            let date = "2024-01-\(String(format: "%02d", dateNumber))T12:00:00+0000"
            environment["GIT_AUTHOR_DATE"] = date
            environment["GIT_COMMITTER_DATE"] = date
        }
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw FixtureError("Fixture git \(arguments.joined(separator: " ")) failed: \(String(decoding: error, as: UTF8.self))")
        }
        return String(decoding: output, as: UTF8.self)
    }

    private func configureIdentity(in directory: URL) throws {
        try git(["config", "user.name", "Fixture Author"], in: directory)
        try git(["config", "user.email", "fixture@example.com"], in: directory)
    }

    private func commit(_ message: String, number: Int, in directory: URL) throws {
        try git(["commit", "-m", message], in: directory, dateNumber: number)
    }

    private func write(_ string: String, to url: URL) throws {
        try write(Data(string.utf8), to: url)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
