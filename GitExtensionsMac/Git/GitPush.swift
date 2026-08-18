import Foundation

enum RepositoryPushDestination: Hashable, Sendable {
    case remote(String)
    case url(String)

    var commandValue: String {
        switch self {
        case .remote(let value), .url(let value): value
        }
    }
}

enum RepositoryForcePushMode: String, Codable, CaseIterable, Sendable {
    case doNotForce
    case force
    case forceWithLease
}

enum RepositoryPushSubmoduleMode: Int, Codable, CaseIterable, Sendable {
    case none = 0
    case check = 1
    case onDemand = 2

    var title: String {
        switch self {
        case .none: "None"
        case .check: "Check"
        case .onDemand: "On-demand"
        }
    }
}

enum RepositoryPushActionMode: String, Hashable, Sendable {
    case push
    case force
    case delete
}

struct RepositoryPushAction: Hashable, Sendable {
    let localBranch: String?
    let remoteBranch: String
    let mode: RepositoryPushActionMode

    init(localBranch: String?, remoteBranch: String, mode: RepositoryPushActionMode) {
        self.localBranch = localBranch
        self.remoteBranch = remoteBranch
        self.mode = mode
    }
}

enum RepositoryPushOperation: Hashable, Sendable {
    case branch(source: String, destination: String?)
    case allBranches
    case tag(String)
    case allTags
    case multiple([RepositoryPushAction])
}

struct RepositoryPushRequest: Hashable, Sendable {
    let destination: RepositoryPushDestination
    let operation: RepositoryPushOperation
    let force: RepositoryForcePushMode
    let setUpstream: Bool
    let recursiveSubmodules: RepositoryPushSubmoduleMode
    let environment: [String: String]

    init(
        destination: RepositoryPushDestination,
        operation: RepositoryPushOperation,
        force: RepositoryForcePushMode = .doNotForce,
        setUpstream: Bool = false,
        recursiveSubmodules: RepositoryPushSubmoduleMode = .check,
        environment: [String: String] = [:]
    ) {
        self.destination = destination
        self.operation = operation
        self.force = force
        self.setUpstream = setUpstream
        self.recursiveSubmodules = recursiveSubmodules
        self.environment = environment
    }
}

struct RepositoryPushBranchState: Hashable, Sendable {
    let name: String
    let objectID: String
    let trackingRemote: String?
    let mergeWith: String?
    let ahead: Int
    let behind: Int
}

struct RepositoryPushRemoteBranchState: Hashable, Sendable {
    let remote: String
    let name: String
    let objectID: String
}

struct RepositoryPushState: Sendable {
    let currentBranch: String?
    let headID: String?
    let isBare: Bool
    let localBranches: [RepositoryPushBranchState]
    let remoteBranches: [RepositoryPushRemoteBranchState]
    let tags: [String]
    let remotes: [RepositoryRemoteConfiguration]
    let autoSetupMerge: Bool

    var isDetached: Bool { currentBranch == nil && headID != nil }

    var preferredRemoteName: String? {
        if let currentBranch,
           let tracking = localBranches.first(where: { $0.name == currentBranch })?.trackingRemote,
           let remote = remotes.first(where: { !$0.isDisabled && $0.name.caseInsensitiveCompare(tracking) == .orderedSame }) {
            return remote.name
        }
        if let origin = remotes.first(where: { !$0.isDisabled && $0.name.caseInsensitiveCompare("origin") == .orderedSame }) {
            return origin.name
        }
        return remotes.first(where: { !$0.isDisabled })?.name
    }

    func commandSource(for value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != "HEAD",
              !value.hasPrefix("refs/"),
              localBranches.contains(where: { $0.name == value })
        else { return value }
        return "refs/heads/" + value
    }

    func defaultRemoteBranch(localBranch: String, remoteName: String) -> String {
        guard let remote = remotes.first(where: { !$0.isDisabled && $0.name == remoteName }) else {
            return localBranch
        }
        if let mapped = Self.mappedPushBranch(localBranch: localBranch, refspecs: remote.pushRefSpecs) {
            return mapped
        }
        if let local = localBranches.first(where: { $0.name == localBranch }),
           local.trackingRemote?.caseInsensitiveCompare(remoteName) == .orderedSame,
           let mergeWith = local.mergeWith,
           !mergeWith.isEmpty {
            return mergeWith
        }
        return (remote.prefix ?? "") + localBranch
    }

    func isBranchKnown(remote: String, branch: String) -> Bool {
        if remoteBranches.contains(where: { $0.remote == remote && $0.name == branch }) {
            return true
        }
        return localBranches.contains {
            $0.name == branch && $0.trackingRemote?.caseInsensitiveCompare(remote) == .orderedSame
        }
    }

    func shouldOfferTrackingReference(for localBranch: String) -> Bool {
        guard autoSetupMerge,
              let local = localBranches.first(where: { $0.name == localBranch }),
              local.trackingRemote?.isEmpty != false
        else { return false }
        return !remotes.contains {
            !$0.isDisabled && localBranch.lowercased().hasPrefix($0.name.lowercased())
        }
    }

    private static func mappedPushBranch(localBranch: String, refspecs: [String]) -> String? {
        for refspec in refspecs {
            let components = refspec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard components.count == 2,
                  let source = headName(components[0]),
                  let destination = headName(components[1])
            else { continue }
            if source.caseInsensitiveCompare(localBranch) == .orderedSame { return destination }
        }
        for refspec in refspecs {
            let components = refspec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard components.count == 2,
                  headName(components[0]) == "*",
                  let destination = headName(components[1])
            else { continue }
            return destination.replacingOccurrences(of: "*", with: localBranch)
        }
        return nil
    }

    private static func headName(_ value: String) -> String? {
        let value = value.first == "+" ? String(value.dropFirst()) : value
        guard value.hasPrefix("refs/heads/") else { return nil }
        return String(value.dropFirst("refs/heads/".count))
    }
}

enum RepositoryPushOutcome: Equatable, Sendable {
    case completed
    case rejected
    case failed
}

struct RepositoryPushResult: Sendable {
    let snapshot: RepositorySnapshot
    let selectedCommitID: String?
    let outcome: RepositoryPushOutcome
    let command: GitCommandResult

    var message: String {
        let stderr = command.standardErrorString.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = command.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        if !stdout.isEmpty { return stdout }
        switch outcome {
        case .completed: return "Push completed."
        case .rejected: return "The push was rejected."
        case .failed: return "Git exited with status \(command.exitStatus)."
        }
    }

    var rejectionText: String? {
        guard outcome == .rejected else { return nil }
        let value = command.standardErrorString + command.standardOutputString
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RepositoryPushError: LocalizedError, Equatable, Sendable {
    case unavailable
    case missingDestination
    case missingRemote(String)
    case missingBranch
    case missingRemoteBranch
    case missingTag
    case invalidRemoteBranch(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Push is unavailable because no repository is open."
        case .missingDestination:
            "Please select a remote or destination URL."
        case .missingRemote(let remote):
            "The remote ‘\(remote)’ does not exist."
        case .missingBranch:
            "No branch is selected, cannot push."
        case .missingRemoteBranch:
            "Please enter the destination branch."
        case .missingTag:
            "You need to select a tag to push or select ‘Push all tags’."
        case .invalidRemoteBranch(let branch):
            "‘\(branch)’ is not a valid remote branch name."
        }
    }
}

protocol RepositoryPushingDataSource: RepositoryPullingDataSource {
    func loadPushState() async throws -> RepositoryPushState
    func loadPushRemoteBranches(named remoteName: String) async throws -> [RepositoryPushRemoteBranchState]
    func loadMergedRemoteBranches() async throws -> Set<String>
    func performPush(
        _ request: RepositoryPushRequest,
        output: @escaping GitOutputHandler
    ) async throws -> RepositoryPushResult
    func deleteLocalTrackingBranches(_ branches: [String], force: Bool) async throws -> RepositorySnapshot
}

enum GitPushCommandBuilder {
    static func arguments(for request: RepositoryPushRequest) throws -> [String] {
        let destination = request.destination.commandValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { throw RepositoryPushError.missingDestination }

        switch request.operation {
        case .multiple(let actions):
            var arguments = ["push", "--progress", destination]
            arguments += try actions.map(actionRefspec)
            return arguments
        case .tag(let rawTag):
            let tag = rawTag.replacingOccurrences(of: " ", with: "")
            guard !tag.isEmpty else { throw RepositoryPushError.missingTag }
            return ["push"] + forceArguments(tagForce(request.force)) + ["--progress", destination, "tag", tag]
        case .allTags:
            return ["push"] + forceArguments(tagForce(request.force)) + ["--progress", destination, "--tags"]
        case .allBranches:
            return ["push"]
                + forceArguments(request.force)
                + upstreamArguments(request.setUpstream)
                + submoduleArguments(request.recursiveSubmodules)
                + ["--progress", "--all", destination]
        case .branch(let rawSource, let rawDestination):
            let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty, source != "(no branch)" else { throw RepositoryPushError.missingBranch }
            var arguments = ["push"]
                + forceArguments(request.force)
                + upstreamArguments(request.setUpstream)
                + submoduleArguments(request.recursiveSubmodules)
                + ["--progress", destination]
            if let rawDestination {
                let branch = rawDestination.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !branch.isEmpty else { throw RepositoryPushError.missingRemoteBranch }
                arguments.append("\(source):\(fullBranchName(branch))")
            } else {
                arguments.append(source)
            }
            return arguments
        }
    }

    private static func forceArguments(_ mode: RepositoryForcePushMode) -> [String] {
        switch mode {
        case .doNotForce: []
        case .force: ["-f"]
        case .forceWithLease: ["--force-with-lease"]
        }
    }

    private static func tagForce(_ mode: RepositoryForcePushMode) -> RepositoryForcePushMode {
        mode == .forceWithLease ? .force : mode
    }

    private static func upstreamArguments(_ value: Bool) -> [String] { value ? ["-u"] : [] }

    private static func submoduleArguments(_ mode: RepositoryPushSubmoduleMode) -> [String] {
        switch mode {
        case .none: []
        case .check: ["--recurse-submodules=check"]
        case .onDemand: ["--recurse-submodules=on-demand"]
        }
    }

    private static func actionRefspec(_ action: RepositoryPushAction) throws -> String {
        let destination = action.remoteBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { throw RepositoryPushError.missingRemoteBranch }
        if action.mode == .delete { return ":\(fullBranchName(destination))" }
        guard let rawSource = action.localBranch?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawSource.isEmpty
        else { throw RepositoryPushError.missingBranch }
        return (action.mode == .force ? "+" : "") + fullBranchName(rawSource) + ":" + fullBranchName(destination)
    }

    private static func fullBranchName(_ value: String) -> String {
        value.hasPrefix("refs/heads/") ? value : "refs/heads/" + value
    }
}

enum RepositoryPullRequestURLBuilder {
    static func url(remoteURL: String, branch: String) -> URL? {
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return nil }
        if let azure = azureURL(remoteURL: remoteURL, branch: branch) { return azure }
        return gitHubURL(remoteURL: remoteURL, branch: branch)
    }

    private static func azureURL(remoteURL: String, branch: String) -> URL? {
        let base: String?
        if remoteURL.contains("dev.azure.com/") || remoteURL.contains("visualstudio.com/") {
            base = remoteURL.hasSuffix(".git") ? String(remoteURL.dropLast(4)) : remoteURL
        } else if remoteURL.hasPrefix("git@ssh.dev.azure.com:v3/") {
            let path = String(remoteURL.dropFirst("git@ssh.dev.azure.com:v3/".count))
            let parts = path.split(separator: "/").map(String.init)
            base = parts.count >= 3 ? "https://dev.azure.com/\(parts[0])/\(parts[1])/_git/\(parts[2])" : nil
        } else {
            base = nil
        }
        guard let base, var components = URLComponents(string: base + "/pullrequestcreate") else { return nil }
        components.queryItems = [URLQueryItem(name: "sourceRef", value: branch)]
        return components.url
    }

    private static func gitHubURL(remoteURL: String, branch: String) -> URL? {
        let path: String?
        if let components = URLComponents(string: remoteURL),
           let host = components.host,
           host.caseInsensitiveCompare("github.com") == .orderedSame {
            path = components.path
        } else if remoteURL.hasPrefix("git@github.com:") {
            path = "/" + String(remoteURL.dropFirst("git@github.com:".count))
        } else {
            path = nil
        }
        guard let path else { return nil }
        var pieces = path.split(separator: "/").map(String.init)
        guard pieces.count == 2 else { return nil }
        if pieces[1].hasSuffix(".git") { pieces[1].removeLast(4) }
        guard !pieces[0].isEmpty, !pieces[1].isEmpty else { return nil }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        guard let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://github.com/\(pieces[0])/\(pieces[1])/compare/\(encodedBranch)?expand=1")
    }
}

extension GitRepositoryBrowsingDataSource: RepositoryPushingDataSource {
    func loadPushState() async throws -> RepositoryPushState {
        guard let repository = resolvedRepository else { throw RepositoryPushError.unavailable }
        let snapshot = try await loadSnapshot()
        let remotes = try await loadRemoteConfigurations()
        let references = snapshot.commits.lazy.flatMap(\.references)
        let localBranches = snapshot.branches.filter { !$0.isRemote }.map { branch in
            let reference = references.first {
                ($0.kind == .currentBranch || $0.kind == .localBranch) && $0.name == branch.name
            }
            return RepositoryPushBranchState(
                name: branch.name,
                objectID: branch.commitID,
                trackingRemote: reference?.trackingRemote,
                mergeWith: reference?.mergeWith,
                ahead: branch.ahead,
                behind: branch.behind
            )
        }
        let remoteBranches = snapshot.branches.compactMap { branch -> RepositoryPushRemoteBranchState? in
            guard branch.isRemote, let remote = branch.remoteName else { return nil }
            return RepositoryPushRemoteBranchState(remote: remote, name: branch.name, objectID: branch.commitID)
        }
        let autoSetupMerge = try await optionalPushConfig("branch.autosetupmerge", repository: repository)?
            .caseInsensitiveCompare("false") != .orderedSame
        let head = snapshot.commits.first(where: \.isHEAD)
        return RepositoryPushState(
            currentBranch: snapshot.branches.first(where: \.isCurrent)?.name,
            headID: head?.id,
            isBare: repository.isBare,
            localBranches: localBranches,
            remoteBranches: remoteBranches,
            tags: snapshot.tags.map(\.name),
            remotes: remotes,
            autoSetupMerge: autoSetupMerge
        )
    }

    func loadPushRemoteBranches(named remoteName: String) async throws -> [RepositoryPushRemoteBranchState] {
        guard let repository = resolvedRepository else { throw RepositoryPushError.unavailable }
        let remotes = try await loadRemoteConfigurations()
        guard remotes.contains(where: { !$0.isDisabled && $0.name == remoteName }) else {
            throw RepositoryPushError.missingRemote(remoteName)
        }
        let result = try await git.runStreaming(
            arguments: ["ls-remote", "--heads", "--refs", remoteName],
            in: repository.rootURL,
            standardInput: nil,
            environment: [:],
            output: { _ in }
        )
        guard result.succeeded else {
            throw GitError.commandFailed(
                arguments: result.arguments,
                status: result.exitStatus,
                stderr: result.standardErrorString.isEmpty ? result.standardOutputString : result.standardErrorString
            )
        }
        let prefix = "refs/heads/"
        return result.standardOutputString.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2,
                  fields[1].hasPrefix(prefix),
                  fields[0].count >= 40
            else { return nil }
            let name = String(fields[1].dropFirst(prefix.count))
            guard !name.isEmpty else { return nil }
            return RepositoryPushRemoteBranchState(remote: remoteName, name: name, objectID: String(fields[0]))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func performPush(
        _ request: RepositoryPushRequest,
        output: @escaping GitOutputHandler
    ) async throws -> RepositoryPushResult {
        guard let repository = resolvedRepository else { throw RepositoryPushError.unavailable }
        if case .remote(let name) = request.destination {
            let remotes = try await loadRemoteConfigurations()
            guard remotes.contains(where: { !$0.isDisabled && $0.name == name }) else {
                throw RepositoryPushError.missingRemote(name)
            }
        }
        try await validateRemoteBranches(in: request, repository: repository)
        let arguments = try GitPushCommandBuilder.arguments(for: request)
        let command = try await git.runStreaming(
            arguments: arguments,
            in: repository.rootURL,
            standardInput: nil,
            environment: request.environment,
            output: output
        )
        let snapshot = try await loadSnapshot()
        let outcome: RepositoryPushOutcome
        if command.succeeded {
            outcome = .completed
        } else if isRejected(command) {
            outcome = .rejected
        } else {
            outcome = .failed
        }
        return RepositoryPushResult(
            snapshot: snapshot,
            selectedCommitID: snapshot.commits.first(where: \.isHEAD)?.id
                ?? snapshot.commits.first(where: { !$0.isArtificial })?.id,
            outcome: outcome,
            command: command
        )
    }

    func loadMergedRemoteBranches() async throws -> Set<String> {
        guard let repository = resolvedRepository else { throw RepositoryPushError.unavailable }
        let result = try await git.run(
            arguments: ["for-each-ref", "--merged=HEAD", "--format=%(refname:short)", "refs/remotes"],
            in: repository.rootURL
        )
        guard result.succeeded else {
            throw GitError.commandFailed(
                arguments: result.arguments,
                status: result.exitStatus,
                stderr: result.standardErrorString.isEmpty ? result.standardOutputString : result.standardErrorString
            )
        }
        return Set(result.standardOutputString
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.hasSuffix("/HEAD") })
    }

    func deleteLocalTrackingBranches(_ branches: [String], force: Bool) async throws -> RepositorySnapshot {
        guard let repository = resolvedRepository else { throw RepositoryPushError.unavailable }
        let names = branches
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return try await loadSnapshot() }
        for name in names {
            let check = try await git.run(arguments: ["check-ref-format", "--branch", name], in: repository.rootURL)
            guard check.succeeded else { throw RepositoryPushError.invalidRemoteBranch(name) }
        }
        let result = try await git.run(arguments: ["branch", force ? "-D" : "-d", "--"] + names, in: repository.rootURL)
        guard result.succeeded else {
            throw GitError.commandFailed(
                arguments: result.arguments,
                status: result.exitStatus,
                stderr: result.standardErrorString.isEmpty ? result.standardOutputString : result.standardErrorString
            )
        }
        return try await loadSnapshot()
    }

    private func validateRemoteBranches(
        in request: RepositoryPushRequest,
        repository: ResolvedGitRepository
    ) async throws {
        let branches: [String] = switch request.operation {
        case .branch(_, let destination): destination.map { [$0] } ?? []
        case .multiple(let actions): actions.map(\.remoteBranch)
        case .allBranches, .tag, .allTags: []
        }
        for branch in branches {
            let value = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw RepositoryPushError.missingRemoteBranch }
            let check = try await git.run(arguments: ["check-ref-format", "--branch", value], in: repository.rootURL)
            guard check.succeeded else { throw RepositoryPushError.invalidRemoteBranch(value) }
        }
    }

    private func optionalPushConfig(_ key: String, repository: ResolvedGitRepository) async throws -> String? {
        let result = try await git.run(arguments: ["config", "--get", key], in: repository.rootURL)
        if result.exitStatus == 1 { return nil }
        guard result.succeeded else {
            throw GitError.commandFailed(
                arguments: result.arguments,
                status: result.exitStatus,
                stderr: result.standardErrorString.isEmpty ? result.standardOutputString : result.standardErrorString
            )
        }
        let value = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func isRejected(_ command: GitCommandResult) -> Bool {
        let output = command.standardOutputString + "\n" + command.standardErrorString
        return output.range(of: #"!\s+\[rejected\]"#, options: .regularExpression) != nil
    }
}
