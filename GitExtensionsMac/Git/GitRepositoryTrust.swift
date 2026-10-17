import Foundation
import GitExtensionsCore

package struct DubiousRepositoryOwnership: LocalizedError, Sendable, Equatable {
    package let repositoryURL: URL
    package let output: String
    package var errorDescription: String? { output }
    package static func recognize(_ output: String, accessing url: URL) -> Self? {
        let prefix = "fatal: detected dubious ownership in repository at '"
        let legacy = "fatal: unsafe repository ('"
        guard let line = output.components(separatedBy: "\n").first(where: { $0.hasPrefix(prefix) || $0.hasPrefix(legacy) }),
              output.contains("config --global --add safe.directory") else { return nil }
        let path: String
        if line.hasPrefix(prefix), line.hasSuffix("'") { path = String(line.dropFirst(prefix.count).dropLast()) }
        else if line.hasPrefix(legacy), line.hasSuffix("' is owned by someone else)") {
            path = String(line.dropFirst(legacy.count).dropLast("' is owned by someone else)".count))
        } else { return nil }
        let reported = URL(fileURLWithPath: path).standardizedFileURL
        let requested = url.standardizedFileURL.resolvingSymlinksInPath()
        let canonical = URL(fileURLWithPath: reported.resolvingSymlinksInPath().path, isDirectory: true).standardizedFileURL
        guard path != "*", !canonical.path.hasSuffix("/*") else { return nil }
        if canonical.path != requested.path {
            guard requested.path.hasPrefix(canonical.path + "/") else { return nil }
            var candidate = requested
            while candidate.path != canonical.path {
                if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".git").path) { return nil }
                let parent = candidate.deletingLastPathComponent()
                guard parent.path != candidate.path else { return nil }
                candidate = parent
            }
            guard FileManager.default.fileExists(atPath: canonical.appendingPathComponent(".git").path) else { return nil }
        }
        return Self(repositoryURL: canonical, output: output)
    }
}

package protocol RepositoryTrustDataSource: Sendable {
    func trustRepository(_ failure: DubiousRepositoryOwnership) async throws
}

extension GitRepositoryModule: RepositoryTrustDataSource {
    package func trustRepository(_ failure: DubiousRepositoryOwnership) async throws {
        guard failure == pendingOwnershipFailure else {
            throw GitError.invalidRepository(failure.repositoryURL.path)
        }
        let directory = failure.repositoryURL
        let read = try await git.run(GitCommand(arguments: ["config", "--global", "--get-all", "safe.directory"],
                                              accessesRemote: false, changesRepositoryState: false), in: directory)
        guard read.succeeded || read.exitStatus == 1 else {
            throw GitError.commandFailed(arguments: read.arguments, status: read.exitStatus, stderr: read.standardErrorString)
        }
        try Task.checkCancellation()
        guard pendingOwnershipFailure == failure else { throw GitError.invalidRepository(directory.path) }
        if !read.standardOutputString.components(separatedBy: "\n").contains(directory.path) {
            let result = try await git.run(GitCommand(arguments: ["config", "--global", "--add", "safe.directory", directory.path],
                                                    accessesRemote: false, changesRepositoryState: true), in: directory)
            guard result.succeeded else {
                throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString)
            }
        }
        if pendingOwnershipFailure == failure { pendingOwnershipFailure = nil }
    }
}
