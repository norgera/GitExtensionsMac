import GitExtensionsCore
import Foundation

package struct RepositoryRevertRequest: Hashable, Sendable {
    package let commitID: ObjectID
    package let automaticallyCommit: Bool
    package let mainlineParent: Int?

    package init(commitID: ObjectID, automaticallyCommit: Bool, mainlineParent: Int? = nil) {
        self.commitID = commitID
        self.automaticallyCommit = automaticallyCommit
        self.mainlineParent = mainlineParent
    }
}

package enum RepositoryRevertError: LocalizedError, Equatable, Sendable {
    case invalidMainline(commitID: ObjectID, parent: Int?, parentCount: Int)
    case notInProgress

    package var errorDescription: String? {
        switch self {
        case .invalidMainline(let commitID, let parent, let parentCount):
            if parentCount > 1 {
                return "Reverting merge \(commitID.shortString) requires a mainline parent from 1 through \(parentCount); received \(parent.map(String.init) ?? "none")."
            }
            return "Revision \(commitID.shortString) is not a merge and cannot use a mainline parent."
        case .notInProgress:
            return "No revert is currently in progress."
        }
    }
}

package protocol RepositoryRevertingDataSource: RepositoryConflictResolutionDataSource {
    func revert(_ request: RepositoryRevertRequest) async throws -> RepositoryMutationResult
    func continueRevert() async throws -> RepositoryMutationResult
    func abortRevert() async throws -> RepositoryMutationResult
}

package enum GitRevertCommands {
    package static func revert(_ request: RepositoryRevertRequest) -> GitCommand {
        var arguments = ["revert"]
        if !request.automaticallyCommit { arguments.append("--no-commit") }
        if let mainline = request.mainlineParent { arguments += ["-m", String(mainline)] }
        arguments.append(request.commitID.string)
        return GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: true)
    }

    package static let continueRevert = GitCommand(
        arguments: ["revert", "--continue"],
        accessesRemote: false,
        changesRepositoryState: true
    )

    package static let abortRevert = GitCommand(
        arguments: ["revert", "--abort"],
        accessesRemote: false,
        changesRepositoryState: true
    )
}

extension GitRepositoryModule: RepositoryRevertingDataSource {
    package func revert(_ request: RepositoryRevertRequest) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        if state.cherryPickInProgress { throw RepositoryMutationError.operationInProgress("a cherry-pick") }
        if state.rebaseInProgress { throw RepositoryMutationError.operationInProgress("a rebase") }
        if state.mergeInProgress { throw RepositoryMutationError.operationInProgress("a merge") }
        guard state.conflictedPaths.isEmpty else {
            throw RepositoryMutationError.unresolvedConflicts(state.conflictedPaths)
        }
        try await validate(request, repository: repository)
        let existingCommitMessage = await revertCommitMessage(in: repository)

        let command = try await git.run(GitRevertCommands.revert(request), in: repository.rootURL)
        if !existingCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await preserveRevertCommitMessage(existingCommitMessage, in: repository)
        }
        return try await resolveRevertExecution(
            command,
            request: request,
            repository: repository,
            completionMessage: request.automaticallyCommit
                ? "Reverted \(request.commitID.shortString)."
                : "Applied revert for \(request.commitID.shortString) without committing."
        )
    }

    package func continueRevert() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        guard state.revertInProgress else { throw RepositoryRevertError.notInProgress }
        guard state.conflictedPaths.isEmpty else {
            throw RepositoryMutationError.unresolvedConflicts(state.conflictedPaths)
        }
        let command = try await git.run(
            GitRevertCommands.continueRevert,
            in: repository.rootURL,
            environment: ["GIT_EDITOR": "true"]
        )
        return try await resolveRevertExecution(
            command,
            request: nil,
            repository: repository,
            completionMessage: "Revert continued."
        )
    }

    package func abortRevert() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        guard state.revertInProgress else { throw RepositoryRevertError.notInProgress }
        let command = try await git.run(GitRevertCommands.abortRevert, in: repository.rootURL)
        guard command.succeeded else { throw commandError(from: command) }
        let headID = try await mutationState(in: repository).headID
        return RepositoryMutationResult(
            selectedCommitID: headID.map(RevisionID.object),
            outcome: .completed,
            message: "Revert aborted."
        )
    }

    private func validate(
        _ request: RepositoryRevertRequest,
        repository: ResolvedGitRepository
    ) async throws {
        let parents = try await git.run(
            GitCommand(
                arguments: ["rev-list", "--parents", "-n", "1", request.commitID.string],
                accessesRemote: false,
                changesRepositoryState: false
            ),
            in: repository.rootURL
        )
        guard parents.succeeded else { throw commandError(from: parents) }
        let values = parents.standardOutputString.split(whereSeparator: \Character.isWhitespace)
        guard values.first.map(String.init) == request.commitID.string else {
            throw RepositoryMutationError.invalidRevision(request.commitID.string)
        }
        let parentCount = max(0, values.count - 1)
        if parentCount > 1 {
            guard let mainline = request.mainlineParent, (1...parentCount).contains(mainline) else {
                throw RepositoryRevertError.invalidMainline(
                    commitID: request.commitID,
                    parent: request.mainlineParent,
                    parentCount: parentCount
                )
            }
        } else if request.mainlineParent != nil {
            throw RepositoryRevertError.invalidMainline(
                commitID: request.commitID,
                parent: request.mainlineParent,
                parentCount: parentCount
            )
        }
    }

    private func resolveRevertExecution(
        _ command: GitCommandResult,
        request: RepositoryRevertRequest?,
        repository: ResolvedGitRepository,
        completionMessage: String
    ) async throws -> RepositoryMutationResult {
        let state = try await mutationState(in: repository)
        let selected = state.headID.map(RevisionID.object) ?? request.map { .object($0.commitID) }
        if command.succeeded {
            return RepositoryMutationResult(
                selectedCommitID: request?.automaticallyCommit == false ? .workingDirectory : selected,
                outcome: .completed,
                message: completionMessage
            )
        }

        let output = command.standardErrorString.isEmpty
            ? command.standardOutputString
            : command.standardErrorString
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !state.conflictedPaths.isEmpty {
            let message = request.map { "Revert of \($0.commitID.shortString) stopped with conflicts." }
                ?? "Revert remains stopped with conflicts."
            return RepositoryMutationResult(
                selectedCommitID: .workingDirectory,
                outcome: .conflicts(state.conflictedPaths),
                message: detail.isEmpty ? message : "\(message) \(detail)"
            )
        }
        if state.revertInProgress {
            return RepositoryMutationResult(
                selectedCommitID: .workingDirectory,
                outcome: .paused(detail.isEmpty ? "Revert is paused." : detail),
                message: detail.isEmpty ? "Revert is paused." : detail
            )
        }
        throw commandError(from: command)
    }

    private func revertCommitMessage(in repository: ResolvedGitRepository) async -> String {
        let mergeURL = repository.gitDirectoryURL.appendingPathComponent("MERGE_MSG")
        let draftURL = repository.gitDirectoryURL.appendingPathComponent("COMMITMESSAGE")
        let messageURL = FileManager.default.fileExists(atPath: mergeURL.path) ? mergeURL : draftURL
        guard FileManager.default.fileExists(atPath: messageURL.path) else { return "" }
        let encodingName = await commitEncodingName(in: repository)
        guard let encoding = try? GitCommitMessageFormatter.encoding(named: encodingName),
              let message = try? String(contentsOf: messageURL, encoding: encoding) else { return "" }
        return message
    }

    private func preserveRevertCommitMessage(
        _ existing: String,
        in repository: ResolvedGitRepository
    ) async {
        let current = await revertCommitMessage(in: repository)
        let combined = GitCommitMessageFormatter.format(
            "\(existing)\n\n\(current)",
            usingTemplate: false,
            ensureSecondLineEmpty: false
        )
        let encodingName = await commitEncodingName(in: repository)
        guard let encoding = try? GitCommitMessageFormatter.encoding(named: encodingName),
              let data = combined.data(using: encoding, allowLossyConversion: false) else { return }
        let mergeURL = repository.gitDirectoryURL.appendingPathComponent("MERGE_MSG")
        try? data.write(to: mergeURL, options: .atomic)
    }
}
