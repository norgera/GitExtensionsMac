import Foundation
@testable import GitExtensionsCore
@testable import GitCommands

enum GitArchiveTests {
    static func run() async throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw GitError.malformedOutput(command: "Archive test", detail: message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-Archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let runner = GitProcess()
        func git(_ args: [String], at url: URL? = nil) async throws -> String {
            let result = try await runner.run(GitCommand(arguments: args, accessesRemote: false, changesRepositoryState: true), in: url ?? repo)
            guard result.succeeded else { throw GitError.commandFailed(arguments: args, status: result.exitStatus, stderr: result.standardErrorString) }
            return result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func archiveContent(_ archive: URL, path: String? = nil) throws -> String {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = path.map { ["-xOf", archive.path, $0] } ?? ["-tf", archive.path]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
            try process.run(); let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            try require(process.terminationStatus == 0, "archive must be readable by native tar")
            return String(decoding: bytes, as: UTF8.self)
        }
        _ = try await git(["init", "-b", "main"])
        _ = try await git(["config", "user.name", "Archive Test"])
        _ = try await git(["config", "user.email", "archive@example.invalid"])
        for (name, value) in [("file.txt", "original\n"), ("deleted.txt", "deleted later\n"), ("unchanged.txt", "unchanged\n")] {
            try Data(value.utf8).write(to: repo.appendingPathComponent(name))
        }
        _ = try await git(["add", "."]); _ = try await git(["commit", "-m", "Original tree"])
        let first = try ObjectID.parse(await git(["rev-parse", "HEAD"]))
        _ = try await git(["tag", "v1"])
        _ = try await git(["branch", "original"])
        _ = try await git(["rm", "deleted.txt"])
        try Data("updated\n".utf8).write(to: repo.appendingPathComponent("file.txt"))
        let folder = repo.appendingPathComponent("folder é")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("nested\n".utf8).write(to: folder.appendingPathComponent("space name.txt"))
        _ = try await git(["add", "."]); _ = try await git(["commit", "-m", "Changed tree"])
        let head = try ObjectID.parse(await git(["rev-parse", "HEAD"]))
        let module = GitRepositoryModule(repositoryURL: repo); _ = try await module.loadRepositoryState()
        for format in ArchiveFormat.allCases {
            let destination = root.appendingPathComponent("output.\(format.rawValue)")
            let request = ArchiveRequest(revision: head, format: format, destination: destination)
            let command = GitArchiveCommands.archive(request, paths: [])
            try require(command.arguments == ["archive", "--format=\(format.rawValue)", head.string, "--output", destination.path], "exact archive arguments")
            try require(!command.accessesRemote && !command.changesRepositoryState, "export never requests repository refresh")
            let result = try await module.archive(request, output: { _ in })
            try require(result.succeeded, "HEAD archive")
            let contents = try archiveContent(destination)
            try require(contents.contains("folder é/space name.txt") && !contents.contains("deleted.txt"), "tree paths without invented prefix")
            try require(try archiveContent(destination, path: "file.txt") == "updated\n", "HEAD content")
            let overwritten = try await module.archive(ArchiveRequest(revision: first, format: format, destination: destination), output: { _ in })
            try require(overwritten.succeeded && (try archiveContent(destination, path: "file.txt")) == "original\n", "confirmed destination overwrite truncates old archive")
            let filtered = try await module.archive(ArchiveRequest(revision: head, format: format, destination: destination, filter: .paths(["folder é", ""])), output: { _ in })
            try require(filtered.succeeded && !(try archiveContent(destination)).contains("file.txt"), "path filter and empty lines")
            let differential = try await module.archive(ArchiveRequest(revision: head, format: format, destination: destination, filter: .changedSince(first)), output: { _ in })
            let names = try archiveContent(destination)
            try require(differential.succeeded && names.contains("file.txt") && !names.contains("unchanged.txt") && !names.contains("deleted.txt"), "differential archive excludes deletes/unchanged")
            let emptyDiff = try await module.archive(ArchiveRequest(revision: head, format: format, destination: destination, filter: .changedSince(head)), output: { _ in })
            try require(emptyDiff.succeeded && (try archiveContent(destination)).contains("unchanged.txt"), "empty path suffix preserves upstream full-tree behavior")
        }
        for ref in ["original", "v1", "HEAD~1"] {
            let id = try ObjectID.parse(await git(["rev-parse", ref]))
            let file = root.appendingPathComponent("ref.tar")
            let result = try await module.archive(ArchiveRequest(revision: id, format: .tar, destination: file), output: { _ in })
            try require(result.succeeded && (try archiveContent(file, path: "file.txt")) == "original\n", "resolved ref/arbitrary target")
        }
        _ = try await git(["checkout", "--detach", head.string])
        let detached = try await module.archive(ArchiveRequest(revision: head, format: .zip, destination: root.appendingPathComponent("detached.zip")), output: { _ in })
        try require(detached.succeeded, "detached eligibility")
        let bare = root.appendingPathComponent("bare.git")
        _ = try await git(["clone", "--bare", repo.path, bare.path], at: root)
        let bareModule = GitRepositoryModule(repositoryURL: bare); _ = try await bareModule.loadRepositoryState()
        let bareFile = root.appendingPathComponent("bare.tar")
        let bareResult = try await bareModule.archive(ArchiveRequest(revision: head, format: .tar, destination: bareFile), output: { _ in })
        try require(bareResult.succeeded && (try archiveContent(bareFile, path: "file.txt")) == "updated\n", "bare repository archive")
        let invalid = try await module.archive(ArchiveRequest(revision: head, format: .zip, destination: root.appendingPathComponent("missing/output.zip")), output: { _ in })
        try require(!invalid.succeeded, "invalid destination reports Git failure")
        let unknown = try ObjectID.parse(String(repeating: "f", count: 40))
        let invalidRevision = try await module.archive(ArchiveRequest(revision: unknown, format: .tar, destination: root.appendingPathComponent("invalid.tar")), output: { _ in })
        try require(!invalidRevision.succeeded, "stale target reports Git failure")
        let renamed = try GitArchiveCommands.changedPaths(Data(":100644 100644 aaaa bbbb R100\0old name\0new name\0:100644 000000 aaaa 0000 D\0removed\0".utf8))
        try require(renamed == ["new name"], "raw rename destination and deleted-path exclusion")
        try require(try await git(["status", "--porcelain"]) == "", "export leaves index/worktree unchanged")
        try require(try await git(["rev-parse", "HEAD"]) == head.string, "export leaves HEAD unchanged")
        try require(GitArchiveCommands.suggestedFilename(repositoryName: "repo", revision: first, paths: ["file.txt"]) == "repo_\(first.string)_file_txt", "upstream filename suggestion")
        print("GitArchiveTests: passed")
    }
}
