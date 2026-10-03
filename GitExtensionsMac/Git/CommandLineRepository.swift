import Foundation
import GitExtensionsCore

package enum CommandLineRepository {
    package static func superproject(of directory: URL, git: any GitCommandRunning) async throws -> URL? {
        let command = GitCommand(arguments: ["rev-parse", "--show-superproject-working-tree"], accessesRemote: false, changesRepositoryState: false)
        let result = try await git.run(command, in: directory)
        let path = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !path.isEmpty ? URL(fileURLWithPath: path) : nil
    }
    package static func discover(candidate: URL?, currentDirectory: URL) -> URL? {
        func find(_ input: URL) -> URL? {
            var directory = input.standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                directory.deleteLastPathComponent()
            }
            while true {
                if RepositoryHistory.isValidGitWorkingDir(directory.path) { return directory }
                if directory.path == "/" || directory.path.isEmpty { return nil }
                let parent = directory.deletingLastPathComponent().standardizedFileURL
                if parent.path == directory.path { return nil }
                directory = parent
            }
        }
        return candidate.flatMap(find) ?? find(currentDirectory)
    }

    package static func partialCommitIDCommand(_ prefix: String) -> GitCommand {
        GitCommand(arguments: ["rev-parse", "--verify", "--quiet", prefix + "^{commit}"], accessesRemote: false, changesRepositoryState: false)
    }

    package static func resolvePartialCommitID(_ prefix: String, git: any GitCommandRunning, in directory: URL) async -> ObjectID? {
        if let id = try? ObjectID.parse(prefix) { return id }
        guard let result = try? await git.run(partialCommitIDCommand(prefix), in: directory) else { return nil }
        let output = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.hasPrefix(prefix), let id = try? ObjectID.parse(output) else { return nil }
        return id
    }

    package static func commitSelection(_ argument: String, git: any GitCommandRunning, in directory: URL) async -> (selected: ObjectID, first: ObjectID?)? {
        var selected: ObjectID?
        for part in argument.components(separatedBy: ",") {
            guard let id = await resolvePartialCommitID(part, git: git, in: directory) else { return nil }
            if selected == nil { selected = id } else { return (selected!, id) }
        }
        return selected.map { ($0, nil) }
    }

    package static func repositoryPathFile(_ file: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = text.split(separator: "\n").first else { return nil }
        let url = URL(fileURLWithPath: String(line).trimmingCharacters(in: .whitespacesAndNewlines))
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue ? url : nil
    }

    package static func removeOwnEditor(applicationPath: String, git: any GitCommandRunning, directory: URL) async throws {
        let read = GitCommand(arguments: ["config", "--global", "--get", "core.editor"], accessesRemote: false, changesRepositoryState: false)
        let value = try await git.run(read, in: directory)
        guard value.succeeded || value.exitStatus == 1 else { throw GitError.commandFailed(arguments: read.arguments, status: value.exitStatus, stderr: value.standardErrorString) }
        guard value.succeeded, !applicationPath.isEmpty,
              value.standardOutputString.range(of: applicationPath, options: .caseInsensitive) != nil else { return }
        let command = GitCommand(arguments: ["config", "--global", "--unset-all", "core.editor"], accessesRemote: false, changesRepositoryState: true)
        let result = try await git.run(command, in: directory)
        guard result.succeeded else { throw GitError.commandFailed(arguments: command.arguments, status: result.exitStatus, stderr: result.standardErrorString) }
    }

    package static func addFiles(_ filter: String, force: Bool, dryRun: Bool) throws -> GitCommand {
        let paths = try ScriptExecution.arguments(filter)
        return GitCommand(arguments: ["add"] + (dryRun ? ["--dry-run"] : []) + (force ? ["-f"] : []) + paths,
                          accessesRemote: false, changesRepositoryState: !dryRun)
    }
}

package struct CommandLineAddResult: Sendable {
    package let command: GitCommandResult
    package let changed: Bool
}

package protocol RepositoryAddingFilesDataSource: Sendable {
    func addFiles(filter: String, force: Bool, dryRun: Bool, output: @escaping GitOutputHandler) async throws -> CommandLineAddResult
    func commandLineResetTarget() async throws -> ObjectID
}

extension GitRepositoryModule: RepositoryAddingFilesDataSource {
    package func commandLineResetTarget() async throws -> ObjectID {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        if let head = await resolveRevision("HEAD") { return head }
        let command = GitCommand(arguments: ["hash-object", "-t", "tree", "--stdin"], accessesRemote: false, changesRepositoryState: false)
        let result = try await git.run(command, in: repository.rootURL, standardInput: Data())
        guard result.succeeded else { throw GitError.commandFailed(arguments: command.arguments, status: result.exitStatus, stderr: result.standardErrorString) }
        return try ObjectID.parse(result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    package func addFiles(filter: String, force: Bool, dryRun: Bool, output: @escaping GitOutputHandler) async throws -> CommandLineAddResult {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        guard !repository.isBare else { throw RepositoryMutationError.bareRepository }
        let command = try CommandLineRepository.addFiles(filter, force: force, dryRun: dryRun)
        let state = GitCommand(arguments: ["diff", "--cached", "--raw", "-z"], accessesRemote: false, changesRepositoryState: false)
        let before = dryRun ? nil : try await git.run(state, in: repository.rootURL).standardOutput
        let result = try await git.runStreaming(command, in: repository.rootURL, output: output)
        let after = dryRun ? nil : try await git.run(state, in: repository.rootURL).standardOutput
        return CommandLineAddResult(command: result, changed: !dryRun && before != after)
    }
}

package struct StandaloneFileEditingDataSource: RepositoryFileEditingDataSource {
    package init() {}
    package func editableFileURL(_ file: RepositoryEditableFile) async throws -> URL { throw RepositoryDataSourceError.unavailable }
    package func ignoredFiles(matching patterns: [String]) async throws -> [String] { [] }
    package func loadEditableFile(at url: URL) async throws -> EditableFileText { try EditableFileIO.load(url, configuredEncoding: nil) }
}
