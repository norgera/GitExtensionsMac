import GitExtensionsCore
import Foundation

package enum RepositoryResetMode: String, CaseIterable, Hashable, Sendable {
    case soft
    case mixed
    case keep
    case merge
    case hard

    package var argument: String { "--\(rawValue)" }
}

package struct RepositoryResetCurrentBranchRequest: Hashable, Sendable {
    package let target: ObjectID
    package let mode: RepositoryResetMode
    package let updateSubmodules: Bool

    package init(target: ObjectID, mode: RepositoryResetMode, updateSubmodules: Bool = false) {
        self.target = target
        self.mode = mode
        self.updateSubmodules = updateSubmodules
    }
}

package struct RepositoryResetAnotherBranchRequest: Hashable, Sendable {
    package let branch: String
    package let target: ObjectID
    package let force: Bool

    package init(branch: String, target: ObjectID, force: Bool) {
        self.branch = branch
        self.target = target
        self.force = force
    }
}

package enum RepositoryBranchResetSafety: Equatable, Sendable {
    case safe
    case requiresForce
}

package enum RepositoryResetOutcome: Equatable, Sendable {
    case completed
    case completedWithSubmoduleUpdateFailure(String)
}

package struct RepositoryResetResult: Sendable {
    package let selectedCommitID: RevisionID
    package let mode: RepositoryResetMode
    package let outcome: RepositoryResetOutcome
    package let message: String
}

package enum RepositoryResetError: LocalizedError, Sendable, Equatable {
    case invalidBranch(String)
    case currentBranch(String)
    case branchAlreadyAtTarget(String)
    case forceRequired(String)

    package var errorDescription: String? {
        switch self {
        case .invalidBranch(let branch):
            "‘\(branch)’ is not an existing local branch."
        case .currentBranch(let branch):
            "Use Reset current branch to reset ‘\(branch)’."
        case .branchAlreadyAtTarget(let branch):
            "‘\(branch)’ already points to the selected revision."
        case .forceRequired(let branch):
            "Resetting ‘\(branch)’ is not a fast-forward. Enable Force reset to continue."
        }
    }
}

package protocol RepositoryResettingDataSource: RepositoryMutationStateDataSource {
    func resetChanges(_ request: RepositoryResetChangesRequest) async throws -> RepositoryMutationResult
    func resetCurrentBranch(_ request: RepositoryResetCurrentBranchRequest) async throws -> RepositoryResetResult
    func resetSafety(for branch: String, target: ObjectID) async throws -> RepositoryBranchResetSafety
    func resetAnotherBranch(_ request: RepositoryResetAnotherBranchRequest) async throws -> RepositoryMutationResult
}

package enum GitResetCommands {
    package static func resetCurrentBranch(_ request: RepositoryResetCurrentBranchRequest) -> GitCommand {
        GitCommand(
            arguments: ["reset", request.mode.argument, request.target.string, "--"],
            accessesRemote: false,
            changesRepositoryState: true
        )
    }

    package static func resetAnotherBranch(_ request: RepositoryResetAnotherBranchRequest) -> GitCommand {
        GitCommand(
            arguments: ["update-ref", "refs/heads/\(request.branch)", request.target.string],
            accessesRemote: false,
            changesRepositoryState: true
        )
    }

    package static func isAncestor(branch: String, target: ObjectID) -> GitCommand {
        GitCommand(
            arguments: ["merge-base", "--is-ancestor", "refs/heads/\(branch)", target.string],
            accessesRemote: false,
            changesRepositoryState: false
        )
    }
}

extension GitRepositoryModule: RepositoryResettingDataSource {
    package func resetCurrentBranch(
        _ request: RepositoryResetCurrentBranchRequest
    ) async throws -> RepositoryResetResult {
        let repository = try mutationRepository()
        let before = try await mutationState(in: repository)
        let command = GitResetCommands.resetCurrentBranch(request)
        let result = try await git.run(command, in: repository.rootURL)
        guard result.succeeded else { throw commandError(from: result) }

        var outcome: RepositoryResetOutcome = .completed
        if request.updateSubmodules, before.headID != request.target {
            do {
                _ = try await checkedMutation(["submodule", "update", "--init", "--recursive"], in: repository)
            } catch {
                outcome = .completedWithSubmoduleUpdateFailure(error.localizedDescription)
            }
        }

        return RepositoryResetResult(
            selectedCommitID: .object(request.target),
            mode: request.mode,
            outcome: outcome,
            message: "Reset \(request.mode.rawValue) to \(request.target.shortString)."
        )
    }

    package func resetSafety(
        for branch: String,
        target: ObjectID
    ) async throws -> RepositoryBranchResetSafety {
        let repository = try mutationRepository()
        let normalized = try await validatedOtherBranch(branch, target: target, repository: repository)
        let result = try await git.run(
            GitResetCommands.isAncestor(branch: normalized, target: target),
            in: repository.rootURL
        )
        switch result.exitStatus {
        case 0: return .safe
        case 1: return .requiresForce
        default: throw commandError(from: result)
        }
    }

    package func resetAnotherBranch(
        _ request: RepositoryResetAnotherBranchRequest
    ) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let branch = try await validatedOtherBranch(request.branch, target: request.target, repository: repository)
        if !request.force,
           try await resetSafety(for: branch, target: request.target) == .requiresForce {
            throw RepositoryResetError.forceRequired(branch)
        }
        let normalized = RepositoryResetAnotherBranchRequest(
            branch: branch,
            target: request.target,
            force: request.force
        )
        let result = try await git.run(GitResetCommands.resetAnotherBranch(normalized), in: repository.rootURL)
        guard result.succeeded else { throw commandError(from: result) }
        return RepositoryMutationResult(
            selectedCommitID: .object(request.target),
            outcome: .completed,
            message: "Reset branch ‘\(branch)’ to \(request.target.shortString)."
        )
    }

    private func validatedOtherBranch(
        _ branch: String,
        target: ObjectID,
        repository: ResolvedGitRepository
    ) async throws -> String {
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, !branch.hasPrefix("-"), !branch.contains("\0") else {
            throw RepositoryResetError.invalidBranch(branch)
        }
        let ref = "refs/heads/\(branch)"
        let branchResult = try await git.run(
            GitCommand(
                arguments: ["rev-parse", "--verify", ref],
                accessesRemote: false,
                changesRepositoryState: false
            ),
            in: repository.rootURL
        )
        guard branchResult.succeeded,
              let branchID = try? ObjectID.parse(branchResult.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw RepositoryResetError.invalidBranch(branch) }

        let currentResult = try await git.run(
            GitCommand(
                arguments: ["branch", "--show-current"],
                accessesRemote: false,
                changesRepositoryState: false
            ),
            in: repository.rootURL
        )
        guard currentResult.succeeded else { throw commandError(from: currentResult) }
        let current = currentResult.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        if current == branch { throw RepositoryResetError.currentBranch(branch) }
        if branchID == target { throw RepositoryResetError.branchAlreadyAtTarget(branch) }
        return branch
    }
}
