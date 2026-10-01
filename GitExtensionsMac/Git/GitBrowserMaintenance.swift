import Foundation
import GitExtensionsCore


package protocol RepositoryBrowserMaintenanceDataSource: Sendable {

    func compressGitDatabase(output: @escaping GitOutputHandler) async throws -> GitCommandResult

    func deleteIndexLocks() async throws -> [URL]

    func undoLastCommit() async throws -> RepositoryMutationResult
}

package enum RepositoryBrowserMaintenanceCommands {
    package static let compressGitDatabase = GitCommand(arguments: ["gc"], accessesRemote: false, changesRepositoryState: true)
    package static let undoLastCommit = GitCommand(arguments: ["reset", "--soft", "HEAD~1"], accessesRemote: false, changesRepositoryState: true)
    package static let gitDirectory = GitCommand(arguments: ["rev-parse", "--absolute-git-dir"], accessesRemote: false, changesRepositoryState: false)

    package static let submodulePaths = GitCommand(arguments: ["ls-files", "-z", "--stage"], accessesRemote: false, changesRepositoryState: false)

    package static func parseSubmodulePaths(_ output: String) -> [String] {
        output.split(separator: "\0").compactMap { record in
            let parts = record.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, parts[0].hasPrefix("160000 ") else { return nil }
            return String(parts[1])
        }
    }
}

package enum RepositoryBrowserMaintenanceError: LocalizedError, Equatable {
    case indexLockCannotBeDeleted(String)
    package var errorDescription: String? {
        switch self {
        case .indexLockCannotBeDeleted(let path): "Failed to delete index.lock.\n\(path)"
        }
    }
}

extension GitRepositoryModule: RepositoryBrowserMaintenanceDataSource {
    package func compressGitDatabase(output: @escaping GitOutputHandler) async throws -> GitCommandResult {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        return try await git.runStreaming(RepositoryBrowserMaintenanceCommands.compressGitDatabase, in: repository.rootURL, output: output)
    }

    package func deleteIndexLocks() async throws -> [URL] {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        var deleted: [URL] = []
        var pending = [repository.rootURL]
        var visited: Set<String> = []
        while let directory = pending.popLast() {
            guard visited.insert(directory.standardizedFileURL.path).inserted,
                  let gitDir = try? await git.run(RepositoryBrowserMaintenanceCommands.gitDirectory, in: directory), gitDir.succeeded
            else { continue }
            let lock = URL(fileURLWithPath: gitDir.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines))
                .appendingPathComponent("index.lock")
            if FileManager.default.fileExists(atPath: lock.path) {
                do { try FileManager.default.removeItem(at: lock) } catch {
                    throw RepositoryBrowserMaintenanceError.indexLockCannotBeDeleted(lock.path)
                }
                deleted.append(lock)
            }
            if let listing = try? await git.run(RepositoryBrowserMaintenanceCommands.submodulePaths, in: directory), listing.succeeded {
                for path in RepositoryBrowserMaintenanceCommands.parseSubmodulePaths(listing.standardOutputString) {
                    let submodule = directory.appendingPathComponent(path, isDirectory: true)
                    if FileManager.default.fileExists(atPath: submodule.appendingPathComponent(".git").path) { pending.append(submodule) }
                }
            }
        }
        return deleted
    }

    package func undoLastCommit() async throws -> RepositoryMutationResult {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        let result = try await git.run(RepositoryBrowserMaintenanceCommands.undoLastCommit, in: repository.rootURL)
        guard result.succeeded else {
            throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString)
        }
        let head = try? await git.run(GitCommand(arguments: ["rev-parse", "--verify", "--quiet", "HEAD"], accessesRemote: false,
                                                 changesRepositoryState: false), in: repository.rootURL)
        let headID = head.flatMap { try? ObjectID.parse($0.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return RepositoryMutationResult(selectedCommitID: headID.map(RevisionID.object), outcome: .completed, message: "Last commit undone.")
    }
}
