import GitExtensionsCore
import Foundation

package enum RepositoryBisectMark: String, CaseIterable, Hashable, Sendable {
    case good
    case bad
    case skip
}

package struct RepositoryBisectState: Equatable, Sendable {
    package let isActive: Bool
    package let currentCommitID: ObjectID?

    package init(isActive: Bool, currentCommitID: ObjectID?) {
        self.isActive = isActive
        self.currentCommitID = currentCommitID
    }
}

package enum RepositoryBisectError: LocalizedError, Equatable, Sendable {
    case alreadyInProgress
    case notInProgress

    package var errorDescription: String? {
        switch self {
        case .alreadyInProgress:
            return "A bisect operation is already in progress."
        case .notInProgress:
            return "No bisect operation is currently in progress."
        }
    }
}

package protocol RepositoryBisectingDataSource: RepositoryMutationStateDataSource {
    func loadBisectState() async throws -> RepositoryBisectState
    func startBisect() async throws -> RepositoryMutationResult
    func markBisect(_ mark: RepositoryBisectMark, revisions: [ObjectID]) async throws -> RepositoryMutationResult
    func resetBisect() async throws -> RepositoryMutationResult
}

package enum GitBisectCommands {
    package static let start = GitCommand(
        arguments: ["bisect", "start"],
        accessesRemote: false,
        changesRepositoryState: true
    )

    package static func mark(_ mark: RepositoryBisectMark, revisions: [ObjectID] = []) -> GitCommand {
        GitCommand(
            arguments: ["bisect", mark.rawValue] + revisions.map(\.string),
            accessesRemote: false,
            changesRepositoryState: true
        )
    }

    package static let reset = GitCommand(
        arguments: ["bisect", "reset"],
        accessesRemote: false,
        changesRepositoryState: true
    )
}

extension GitRepositoryModule: RepositoryBisectingDataSource {
    package func loadBisectState() async throws -> RepositoryBisectState {
        let repository = try mutationRepository()
        return try await bisectState(in: repository)
    }

    package func startBisect() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        guard !(try await bisectState(in: repository)).isActive else {
            throw RepositoryBisectError.alreadyInProgress
        }
        return try await executeBisect(
            GitBisectCommands.start,
            in: repository,
            successMessage: "Bisect started."
        )
    }

    package func markBisect(
        _ mark: RepositoryBisectMark,
        revisions: [ObjectID] = []
    ) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        guard (try await bisectState(in: repository)).isActive else {
            throw RepositoryBisectError.notInProgress
        }
        try await validateBisectRevisions(revisions, in: repository)
        let target = revisions.isEmpty ? "current revision" : revisions.map(\.shortString).joined(separator: ", ")
        return try await executeBisect(
            GitBisectCommands.mark(mark, revisions: revisions),
            in: repository,
            successMessage: "Marked \(target) as \(mark.rawValue)."
        )
    }

    package func resetBisect() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        guard (try await bisectState(in: repository)).isActive else {
            throw RepositoryBisectError.notInProgress
        }
        return try await executeBisect(
            GitBisectCommands.reset,
            in: repository,
            successMessage: "Bisect stopped."
        )
    }

    private func executeBisect(
        _ command: GitCommand,
        in repository: ResolvedGitRepository,
        successMessage: String
    ) async throws -> RepositoryMutationResult {
        let before = await bisectFingerprint(in: repository)
        let result = try await git.run(command, in: repository.rootURL)
        let after = await bisectFingerprint(in: repository)
        guard result.succeeded || before != after else { throw commandError(from: result) }

        let detail = (result.standardErrorString.isEmpty
            ? result.standardOutputString
            : result.standardErrorString).trimmingCharacters(in: .whitespacesAndNewlines)
        let state = try await bisectState(in: repository)
        let selection = state.currentCommitID.map(RevisionID.object)
        if result.succeeded {
            return RepositoryMutationResult(
                selectedCommitID: selection,
                outcome: .completed,
                message: detail.isEmpty ? successMessage : detail
            )
        }
        return RepositoryMutationResult(
            selectedCommitID: selection,
            outcome: .paused(detail.isEmpty ? "Bisect changed repository state but did not complete the command." : detail),
            message: detail.isEmpty ? successMessage : detail
        )
    }

    private func bisectState(in repository: ResolvedGitRepository) async throws -> RepositoryBisectState {
        let isActive = FileManager.default.fileExists(
            atPath: repository.gitDirectoryURL.appendingPathComponent("BISECT_START").path
        )
        let mutation = try await mutationState(in: repository)
        return RepositoryBisectState(isActive: isActive, currentCommitID: mutation.headID)
    }

    private func validateBisectRevisions(
        _ revisions: [ObjectID],
        in repository: ResolvedGitRepository
    ) async throws {
        for revision in revisions {
            let result = try await git.run(
                GitCommand(
                    arguments: ["rev-parse", "--verify", "\(revision.string)^{commit}"],
                    accessesRemote: false,
                    changesRepositoryState: false
                ),
                in: repository.rootURL
            )
            guard result.succeeded else { throw RepositoryMutationError.invalidRevision(revision.string) }
        }
    }

    private func bisectFingerprint(in repository: ResolvedGitRepository) async -> BisectFingerprint {
        let state = try? await mutationState(in: repository)
        return BisectFingerprint(
            headID: state?.headID,
            start: try? Data(contentsOf: repository.gitDirectoryURL.appendingPathComponent("BISECT_START")),
            log: try? Data(contentsOf: repository.gitDirectoryURL.appendingPathComponent("BISECT_LOG"))
        )
    }
}

private struct BisectFingerprint: Equatable {
    let headID: ObjectID?
    let start: Data?
    let log: Data?
}
