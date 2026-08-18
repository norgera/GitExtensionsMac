import Foundation

enum RepositoryPullMode: String, Codable, CaseIterable, Sendable {
    case merge
    case rebase
    case fetch
}

enum RepositoryPullSource: Hashable, Sendable {
    case remote(String)
    case url(String)
    case allRemotes

    var commandValue: String {
        switch self {
        case .remote(let name), .url(let name): name
        case .allRemotes: "--all"
        }
    }
}

enum RepositoryFetchTagMode: String, Codable, CaseIterable, Sendable {
    case followTagOption
    case noTags
    case allTags
}

struct RepositoryPullRequest: Sendable {
    let source: RepositoryPullSource
    let mode: RepositoryPullMode
    let localBranch: String?
    let remoteBranch: String?
    let tagMode: RepositoryFetchTagMode
    let unshallow: Bool
    let prune: Bool
    let pruneTags: Bool
    let autoStash: Bool
    let includeUntrackedInAutoStash: Bool
    let updateSubmodulesAfterPull: Bool
    let environment: [String: String]

    init(
        source: RepositoryPullSource,
        mode: RepositoryPullMode,
        localBranch: String? = nil,
        remoteBranch: String? = nil,
        tagMode: RepositoryFetchTagMode = .followTagOption,
        unshallow: Bool = false,
        prune: Bool = false,
        pruneTags: Bool = false,
        autoStash: Bool = false,
        includeUntrackedInAutoStash: Bool = false,
        updateSubmodulesAfterPull: Bool = false,
        environment: [String: String] = [:]
    ) {
        self.source = source
        self.mode = mode
        self.localBranch = localBranch
        self.remoteBranch = remoteBranch
        self.tagMode = tagMode
        self.unshallow = unshallow
        self.prune = prune
        self.pruneTags = pruneTags
        self.autoStash = autoStash
        self.includeUntrackedInAutoStash = includeUntrackedInAutoStash
        self.updateSubmodulesAfterPull = updateSubmodulesAfterPull
        self.environment = environment
    }
}

struct RepositoryPullState: Equatable, Sendable {
    let currentBranch: String?
    let headID: String?
    let configuredRemote: String?
    let configuredMergeBranch: String?
    let isBare: Bool
    let isShallow: Bool
    let hasTrackedChanges: Bool
    let hasUntrackedFiles: Bool
    let conflictedPaths: [String]
    let mergeInProgress: Bool
    let rebaseInProgress: Bool
    let cherryPickInProgress: Bool

    var isDetached: Bool { currentBranch == nil && headID != nil }
}

enum RepositoryPullConflictKind: String, Equatable, Sendable {
    case merge
    case rebase
}

enum RepositoryPullOutcome: Equatable, Sendable {
    case completed
    case conflicts(kind: RepositoryPullConflictKind, paths: [String])
    case failed
}

struct RepositoryPullResult: Sendable {
    let snapshot: RepositorySnapshot
    let selectedCommitID: String?
    let outcome: RepositoryPullOutcome
    let command: GitCommandResult
    let followUpCommands: [GitCommandResult]
    let automaticStashCreated: Bool
    let suggestsRemotePrune: String?

    var message: String {
        let reportedCommand = followUpCommands.first(where: { !$0.succeeded }) ?? command
        let stderr = reportedCommand.standardErrorString.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = reportedCommand.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        if !stdout.isEmpty { return stdout }
        switch outcome {
        case .completed: return "Operation completed."
        case .conflicts: return "The operation stopped with conflicts."
        case .failed: return "Git exited with status \(reportedCommand.exitStatus)."
        }
    }
}

enum RepositoryPullError: LocalizedError, Equatable, Sendable {
    case unavailable
    case bareRepository
    case missingSource
    case missingRemote(String)
    case allRemotesRequireFetch
    case wildcardBranchRequiresFetch
    case invalidLocalBranch(String)
    case unresolvedConflicts([String])
    case operationInProgress(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Pull is unavailable because no repository is open."
        case .bareRepository:
            "Pull is unavailable in a bare repository. Use Fetch instead."
        case .missingSource:
            "Please select a remote or source URL."
        case .missingRemote(let remote):
            "The remote ‘\(remote)’ does not exist."
        case .allRemotesRequireFetch:
            "[ All ] is available only for Fetch."
        case .wildcardBranchRequiresFetch:
            "The wildcard branch can be used only with Fetch."
        case .invalidLocalBranch(let branch):
            "‘\(branch)’ is not a valid local branch name."
        case .unresolvedConflicts(let paths):
            "Resolve existing conflicts before Pull: \(paths.joined(separator: ", "))."
        case .operationInProgress(let operation):
            "Cannot start Pull while \(operation) is in progress."
        }
    }
}

protocol RepositoryPullingDataSource: RepositoryRemoteManagingDataSource, RepositoryMutatingDataSource {
    func loadPullState() async throws -> RepositoryPullState
    func hasUnpushedMergeCommit(remote: String, branch: String?) async throws -> Bool
    func pruneRemote(named remote: String, output: @escaping GitOutputHandler) async throws -> RepositoryPullResult
    func performPull(
        _ request: RepositoryPullRequest,
        output: @escaping GitOutputHandler
    ) async throws -> RepositoryPullResult
}

enum GitPullCommandBuilder {
    static func arguments(
        for request: RepositoryPullRequest,
        configureFetchParallel: Bool,
        configureSubmoduleFetchJobs: Bool
    ) throws -> [String] {
        try validateShape(request)
        var arguments: [String] = []
        if configureFetchParallel { arguments += ["-c", "fetch.parallel=0"] }
        if configureSubmoduleFetchJobs { arguments += ["-c", "submodule.fetchjobs=0"] }
        if request.mode == .fetch {
            arguments += ["fetch", "--progress", request.source.commandValue]
            if case .allRemotes = request.source {
            } else if let branch = normalizedRemoteBranch(request.remoteBranch) {
                var refspec = "+" + branch
                if let local = normalizedLocalBranch(request.localBranch) {
                    refspec += ":refs/heads/" + local
                }
                arguments.append(refspec)
            }
        } else {
            arguments.append("pull")
            if request.mode == .rebase { arguments.append("--rebase") }
            arguments += ["--progress", request.source.commandValue]
            if let branch = normalizedRemoteBranch(request.remoteBranch) {
                arguments.append("+" + branch)
            }
        }

        switch request.tagMode {
        case .followTagOption: break
        case .noTags: arguments.append("--no-tags")
        case .allTags: arguments.append("--tags")
        }
        if request.unshallow { arguments.append("--unshallow") }
        if request.mode == .fetch, request.prune || request.pruneTags {
            arguments += ["--prune", "--force"]
        }
        if request.mode == .fetch, request.pruneTags {
            arguments.append("--prune-tags")
        }
        return arguments
    }

    private static func validateShape(_ request: RepositoryPullRequest) throws {
        guard !request.source.commandValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryPullError.missingSource
        }
        if case .allRemotes = request.source, request.mode != .fetch {
            throw RepositoryPullError.allRemotesRequireFetch
        }
        if normalizedRemoteBranch(request.remoteBranch) == "*", request.mode != .fetch {
            throw RepositoryPullError.wildcardBranchRequiresFetch
        }
    }

    private static func normalizedRemoteBranch(_ value: String?) -> String? {
        guard var value = normalized(value) else { return nil }
        value.removeAll(where: { $0 == " " })
        if value.first == "+" { value.removeFirst() }
        return value.isEmpty ? nil : value
    }

    static func normalizedLocalBranch(_ value: String?) -> String? {
        guard var value = normalized(value) else { return nil }
        value.removeAll(where: { $0 == " " })
        return value.isEmpty ? nil : value
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

extension GitRepositoryBrowsingDataSource: RepositoryPullingDataSource {
    func loadPullState() async throws -> RepositoryPullState {
        guard let repository = resolvedRepository else { throw RepositoryPullError.unavailable }
        let state: RepositoryMutationState
        if repository.isBare {
            let head = try await git.run(arguments: ["rev-parse", "--verify", "HEAD"], in: repository.rootURL)
            state = RepositoryMutationState(
                currentBranch: nil,
                headID: head.succeeded ? head.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                hasStagedChanges: false,
                hasUnstagedChanges: false,
                hasUntrackedFiles: false,
                conflictedPaths: [],
                cherryPickInProgress: false,
                rebaseInProgress: false
            )
        } else {
            state = try await mutationState(in: repository)
        }

        var configuredRemote: String?
        var configuredMerge: String?
        if let branch = state.currentBranch {
            configuredRemote = try await optionalConfig("branch.\(branch).remote", repository: repository)
            configuredMerge = try await optionalConfig("branch.\(branch).merge", repository: repository)
                .map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0 }
        }
        return RepositoryPullState(
            currentBranch: state.currentBranch,
            headID: state.headID,
            configuredRemote: configuredRemote,
            configuredMergeBranch: configuredMerge,
            isBare: repository.isBare,
            isShallow: FileManager.default.fileExists(atPath: repository.gitDirectoryURL.appendingPathComponent("shallow").path),
            hasTrackedChanges: state.hasStagedChanges || state.hasUnstagedChanges,
            hasUntrackedFiles: state.hasUntrackedFiles,
            conflictedPaths: state.conflictedPaths,
            mergeInProgress: FileManager.default.fileExists(atPath: repository.gitDirectoryURL.appendingPathComponent("MERGE_HEAD").path),
            rebaseInProgress: state.rebaseInProgress,
            cherryPickInProgress: state.cherryPickInProgress
        )
    }

    func hasUnpushedMergeCommit(remote: String, branch: String?) async throws -> Bool {
        guard let repository = resolvedRepository else { throw RepositoryPullError.unavailable }
        let state = try await loadPullState()
        guard let currentBranch = state.currentBranch else { return false }
        let requestedBranch = branch?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let configuredBranch = state.configuredMergeBranch?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let remoteBranch = requestedBranch?.isEmpty == false ? requestedBranch : configuredBranch
        guard let remoteBranch, !remoteBranch.isEmpty else { return false }
        let start = "\(remote)/\(remoteBranch)"
        let result = try await git.run(
            arguments: ["rev-list", "--parents", "--no-walk", "--min-parents=2", "\(start)..\(currentBranch)"],
            in: repository.rootURL
        )
        guard result.succeeded else { return false }
        return !result.standardOutputString.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
    }

    func pruneRemote(named remote: String, output: @escaping GitOutputHandler) async throws -> RepositoryPullResult {
        guard let repository = resolvedRepository else { throw RepositoryPullError.unavailable }
        let remotes = try await loadRemoteConfigurations()
        guard remotes.contains(where: { !$0.isDisabled && $0.name == remote }) else {
            throw RepositoryPullError.missingRemote(remote)
        }
        let command = try await git.runStreaming(
            arguments: ["remote", "prune", remote],
            in: repository.rootURL,
            standardInput: nil,
            environment: [:],
            output: output
        )
        let snapshot = try await loadSnapshot()
        return RepositoryPullResult(
            snapshot: snapshot,
            selectedCommitID: snapshot.commits.first(where: \.isHEAD)?.id,
            outcome: command.succeeded ? .completed : .failed,
            command: command,
            followUpCommands: [],
            automaticStashCreated: false,
            suggestsRemotePrune: nil
        )
    }

    func performPull(
        _ request: RepositoryPullRequest,
        output: @escaping GitOutputHandler
    ) async throws -> RepositoryPullResult {
        guard let repository = resolvedRepository else { throw RepositoryPullError.unavailable }
        if repository.isBare, request.mode != .fetch { throw RepositoryPullError.bareRepository }
        let before = try await loadPullState()
        try await validate(request, state: before, repository: repository)

        var automaticStashCreated = false
        if request.mode != .fetch,
           request.autoStash,
           before.hasTrackedChanges {
            let oldStash = try await stashObjectID(repository: repository)
            var stashArguments = ["stash"]
            if request.includeUntrackedInAutoStash { stashArguments.append("-u") }
            let stash = try await git.runStreaming(
                arguments: stashArguments,
                in: repository.rootURL,
                standardInput: nil,
                environment: request.environment,
                output: output
            )
            guard stash.succeeded else { throw commandError(stash) }
            let newStash = try await stashObjectID(repository: repository)
            automaticStashCreated = newStash != nil && newStash != oldStash
        }

        let fetchParallel = try await optionalConfig("fetch.parallel", repository: repository) == nil
        let submoduleJobs = try await optionalConfig("submodule.fetchjobs", repository: repository) == nil
        let arguments = try GitPullCommandBuilder.arguments(
            for: request,
            configureFetchParallel: fetchParallel,
            configureSubmoduleFetchJobs: submoduleJobs
        )
        let command = try await git.runStreaming(
            arguments: arguments,
            in: repository.rootURL,
            standardInput: nil,
            environment: request.environment,
            output: output
        )

        var followUpCommands: [GitCommandResult] = []
        if command.succeeded,
           request.mode != .fetch,
           request.updateSubmodulesAfterPull,
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

        let after = repository.isBare ? nil : try await loadPullState()
        let outcome: RepositoryPullOutcome
        if let after, !after.conflictedPaths.isEmpty {
            outcome = .conflicts(
                kind: after.rebaseInProgress ? .rebase : .merge,
                paths: after.conflictedPaths
            )
        } else {
            outcome = command.succeeded && followUpCommands.allSatisfy(\.succeeded) ? .completed : .failed
        }
        let snapshot = try await loadSnapshot()
        let selected = snapshot.commits.first(where: \.isHEAD)?.id
            ?? snapshot.commits.first(where: { !$0.isArtificial })?.id
        return RepositoryPullResult(
            snapshot: snapshot,
            selectedCommitID: selected,
            outcome: outcome,
            command: command,
            followUpCommands: followUpCommands,
            automaticStashCreated: automaticStashCreated,
            suggestsRemotePrune: staleConfiguredRemote(from: command, request: request)
        )
    }

    private func validate(
        _ request: RepositoryPullRequest,
        state: RepositoryPullState,
        repository: ResolvedGitRepository
    ) async throws {
        _ = try GitPullCommandBuilder.arguments(
            for: request,
            configureFetchParallel: false,
            configureSubmoduleFetchJobs: false
        )
        if !state.conflictedPaths.isEmpty { throw RepositoryPullError.unresolvedConflicts(state.conflictedPaths) }
        if state.rebaseInProgress { throw RepositoryPullError.operationInProgress("a rebase") }
        if state.cherryPickInProgress { throw RepositoryPullError.operationInProgress("a cherry-pick") }
        if state.mergeInProgress { throw RepositoryPullError.operationInProgress("a merge") }
        if case .remote(let name) = request.source {
            let remotes = try await loadRemoteConfigurations()
            guard remotes.contains(where: { !$0.isDisabled && $0.name == name }) else {
                throw RepositoryPullError.missingRemote(name)
            }
        }
        if request.mode == .fetch,
           let local = GitPullCommandBuilder.normalizedLocalBranch(request.localBranch) {
            let check = try await git.run(arguments: ["check-ref-format", "--branch", local], in: repository.rootURL)
            guard check.succeeded else { throw RepositoryPullError.invalidLocalBranch(local) }
        }
    }

    private func optionalConfig(_ key: String, repository: ResolvedGitRepository) async throws -> String? {
        let result = try await git.run(arguments: ["config", "--get", key], in: repository.rootURL)
        guard result.exitStatus == 0 else {
            if result.exitStatus == 1 { return nil }
            throw commandError(result)
        }
        let value = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func stashObjectID(repository: ResolvedGitRepository) async throws -> String? {
        let result = try await git.run(
            arguments: ["rev-parse", "--verify", "--quiet", "refs/stash"],
            in: repository.rootURL
        )
        guard result.succeeded else { return nil }
        let value = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func commandError(_ result: GitCommandResult) -> GitError {
        GitError.commandFailed(
            arguments: result.arguments,
            status: result.exitStatus,
            stderr: result.standardErrorString.isEmpty ? result.standardOutputString : result.standardErrorString
        )
    }

    private func staleConfiguredRemote(from result: GitCommandResult, request: RepositoryPullRequest) -> String? {
        guard !result.succeeded, case .remote(let remote) = request.source else { return nil }
        let message = result.standardErrorString + "\n" + result.standardOutputString
        let lower = message.lowercased()
        let configuredRefRemoved = lower.contains("your configuration specifies to")
            && lower.contains("but no such ref was fetched")
        guard configuredRefRemoved else {
            return nil
        }
        return remote
    }
}
