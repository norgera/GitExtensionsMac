import Foundation

struct RepositoryMergeRequest: Sendable {
    let targets: [String]
    let allowFastForward: Bool
    let squash: Bool
    let noCommit: Bool
    let strategy: String?
    let allowUnrelatedHistories: Bool
    let message: String?
    let logCount: Int?
    let updateSubmodulesAfterMerge: Bool
    let environment: [String: String]

    init(
        targets: [String],
        allowFastForward: Bool = true,
        squash: Bool = false,
        noCommit: Bool = false,
        strategy: String? = nil,
        allowUnrelatedHistories: Bool = false,
        message: String? = nil,
        logCount: Int? = nil,
        updateSubmodulesAfterMerge: Bool = false,
        environment: [String: String] = [:]
    ) {
        self.targets = targets
        self.allowFastForward = allowFastForward
        self.squash = squash
        self.noCommit = noCommit
        self.strategy = strategy
        self.allowUnrelatedHistories = allowUnrelatedHistories
        self.message = message
        self.logCount = logCount
        self.updateSubmodulesAfterMerge = updateSubmodulesAfterMerge
        self.environment = environment
    }
}

enum RepositoryMergeOutcome: Equatable, Sendable {
    case completed
    case alreadyUpToDate
    case readyToCommit
    case conflicts([String])
    case failed
}

struct RepositoryMergeResult: Sendable {
    let snapshot: RepositorySnapshot
    let selectedCommitID: String?
    let outcome: RepositoryMergeOutcome
    let command: GitCommandResult
    let followUpCommands: [GitCommandResult]

    var message: String {
        let displayedCommand = followUpCommands.first(where: { !$0.succeeded }) ?? command
        let stderr = displayedCommand.standardErrorString.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = displayedCommand.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        if !stdout.isEmpty { return stdout }
        switch outcome {
        case .completed: return "Merge completed."
        case .alreadyUpToDate: return "Already up to date."
        case .readyToCommit: return "Automatic merge completed; commit the staged result when ready."
        case .conflicts(let paths): return "Merge stopped with \(paths.count) conflict(s)."
        case .failed: return "Git exited with status \(displayedCommand.exitStatus)."
        }
    }
}

enum RepositoryMergeError: LocalizedError, Equatable, Sendable {
    case unavailable
    case bareRepository
    case missingTarget
    case unresolvedConflicts([String])
    case operationInProgress(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Merge is unavailable because no repository is open."
        case .bareRepository:
            "Merge is unavailable in a bare repository."
        case .missingTarget:
            "Select at least one branch, tag, or revision to merge."
        case .unresolvedConflicts(let paths):
            "Resolve existing conflicts before Merge: \(paths.joined(separator: ", "))."
        case .operationInProgress(let operation):
            "Cannot start Merge while \(operation) is in progress."
        }
    }
}

protocol RepositoryMergingDataSource: RepositoryConflictResolutionDataSource {
    func performMerge(
        _ request: RepositoryMergeRequest,
        output: @escaping GitOutputHandler
    ) async throws -> RepositoryMergeResult
}

enum GitMergeCommandBuilder {
    static func arguments(for request: RepositoryMergeRequest, messageFile: String?) throws -> [String] {
        let targets = request.targets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !targets.isEmpty else { throw RepositoryMergeError.missingTarget }

        var arguments = ["merge"]
        if !request.allowFastForward { arguments.append("--no-ff") }
        if let strategy = request.strategy?.trimmingCharacters(in: .whitespacesAndNewlines),
           !strategy.isEmpty {
            arguments.append("--strategy=\(strategy)")
        }
        if request.squash { arguments.append("--squash") }
        if request.noCommit { arguments.append("--no-commit") }
        if request.allowUnrelatedHistories { arguments.append("--allow-unrelated-histories") }
        if let messageFile { arguments += ["-F", messageFile] }
        if let count = request.logCount, count > 0 { arguments.append("--log=\(count)") }
        arguments.append("--no-edit")
        arguments.append(contentsOf: targets)
        return arguments
    }
}

extension GitRepositoryBrowsingDataSource: RepositoryMergingDataSource {
    func performMerge(
        _ request: RepositoryMergeRequest,
        output: @escaping GitOutputHandler
    ) async throws -> RepositoryMergeResult {
        guard let repository = resolvedRepository else { throw RepositoryMergeError.unavailable }
        if repository.isBare { throw RepositoryMergeError.bareRepository }

        let before = try await mutationState(in: repository)
        if !before.conflictedPaths.isEmpty { throw RepositoryMergeError.unresolvedConflicts(before.conflictedPaths) }
        if before.rebaseInProgress { throw RepositoryMergeError.operationInProgress("a rebase") }
        if before.cherryPickInProgress { throw RepositoryMergeError.operationInProgress("a cherry-pick") }
        if before.mergeInProgress { throw RepositoryMergeError.operationInProgress("a merge") }

        let messageFile = try await writeMergeMessage(request.message, repository: repository)
        let arguments = try GitMergeCommandBuilder.arguments(for: request, messageFile: messageFile)
        let command = try await git.runStreaming(
            arguments: arguments,
            in: repository.rootURL,
            standardInput: nil,
            environment: request.environment,
            output: output
        )

        let mergeState = try await mutationState(in: repository)
        var followUpCommands: [GitCommandResult] = []
        if command.succeeded,
           mergeState.conflictedPaths.isEmpty,
           request.updateSubmodulesAfterMerge,
           FileManager.default.fileExists(atPath: repository.rootURL.appendingPathComponent(".gitmodules").path) {
            let submodules = try await git.runStreaming(
                arguments: ["submodule", "update", "--init", "--recursive"],
                in: repository.rootURL,
                standardInput: nil,
                environment: request.environment,
                output: output
            )
            followUpCommands.append(submodules)
        }

        let after = try await mutationState(in: repository)
        let combinedOutput = (command.standardOutputString + "\n" + command.standardErrorString).lowercased()
        let outcome: RepositoryMergeOutcome
        if !after.conflictedPaths.isEmpty {
            outcome = .conflicts(after.conflictedPaths)
        } else if command.succeeded, followUpCommands.allSatisfy(\.succeeded), after.mergeInProgress {
            outcome = .readyToCommit
        } else if command.succeeded, followUpCommands.allSatisfy(\.succeeded),
                  combinedOutput.contains("already up-to-date") || combinedOutput.contains("already up to date") {
            outcome = .alreadyUpToDate
        } else {
            outcome = command.succeeded && followUpCommands.allSatisfy(\.succeeded) ? .completed : .failed
        }

        let snapshot = try await loadSnapshot()
        return RepositoryMergeResult(
            snapshot: snapshot,
            selectedCommitID: snapshot.commits.first(where: \.isHEAD)?.id
                ?? snapshot.commits.first(where: { !$0.isArtificial })?.id,
            outcome: outcome,
            command: command,
            followUpCommands: followUpCommands
        )
    }

    private func writeMergeMessage(
        _ message: String?,
        repository: ResolvedGitRepository
    ) async throws -> String? {
        guard let message else { return nil }
        let configured = try await git.run(
            arguments: ["config", "--get", "i18n.commitEncoding"],
            in: repository.rootURL
        )
        let encodingName = configured.succeeded
            ? configured.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
            : "UTF-8"
        let encoding = try GitCommitMessageFormatter.encoding(named: encodingName.isEmpty ? "UTF-8" : encodingName)
        let formatted = GitCommitMessageFormatter.format(
            message,
            usingTemplate: false,
            ensureSecondLineEmpty: false
        )
        guard let data = formatted.data(using: encoding) else {
            throw RepositoryMutationError.commitMessageNotRepresentable(encodingName)
        }
        let url = repository.gitDirectoryURL.appendingPathComponent("MERGE_MSG")
        try data.write(to: url, options: .atomic)
        return url.path
    }
}
