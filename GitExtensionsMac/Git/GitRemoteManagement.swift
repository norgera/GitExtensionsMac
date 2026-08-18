import Foundation

struct RepositoryRemoteConfiguration: Identifiable, Hashable, Sendable {
    var id: String { "\(isDisabled ? "disabled" : "active"):\(name)" }
    let name: String
    let fetchURL: String
    let pushURL: String?
    let puttyKeyFile: String?
    let color: String?
    let prefix: String?
    let pushRefSpecs: [String]
    let isDisabled: Bool
}

struct RepositoryRemoteSaveRequest: Hashable, Sendable {
    let originalName: String?
    let name: String
    let fetchURL: String
    let pushURL: String?
    let puttyKeyFile: String?
    let color: String?
    let prefix: String?
}

struct RepositoryBranchTrackingConfiguration: Identifiable, Hashable, Sendable {
    var id: String { branchName }
    let branchName: String
    let remoteName: String?
    let mergeBranch: String?
}

enum RepositoryRemoteManagementError: LocalizedError, Sendable {
    case invalidName
    case duplicateName(String)
    case disabledRemoteIsReadOnly
    case missingRemote(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "Please enter a remote name."
        case .duplicateName(let name):
            "A remote named ‘\(name)’ already exists."
        case .disabledRemoteIsReadOnly:
            "Activate this remote before editing its details."
        case .missingRemote(let name):
            "The remote ‘\(name)’ no longer exists."
        }
    }
}

protocol RepositoryRemoteManagingDataSource: RepositoryBrowsingDataSource {
    func loadRemoteConfigurations() async throws -> [RepositoryRemoteConfiguration]
    func loadRemoteBranchNames(named remoteName: String) async throws -> [String]
    func saveRemote(_ request: RepositoryRemoteSaveRequest) async throws -> RepositorySnapshot
    func deleteRemote(named name: String, disabled: Bool) async throws -> RepositorySnapshot
    func setRemote(named name: String, disabled: Bool) async throws -> RepositorySnapshot
    func loadBranchTrackingConfigurations() async throws -> [RepositoryBranchTrackingConfiguration]
    func setBranchTracking(_ configuration: RepositoryBranchTrackingConfiguration) async throws -> RepositorySnapshot
}

extension GitRepositoryBrowsingDataSource: RepositoryRemoteManagingDataSource {
    func loadRemoteConfigurations() async throws -> [RepositoryRemoteConfiguration] {
        let repository = try remoteRepository()
        let entries = try await localConfigEntries(in: repository)
        var values: [RemoteIdentity: [String: [String]]] = [:]
        for (key, value) in entries {
            guard let parsed = parseRemoteKey(key) else { continue }
            values[parsed.identity, default: [:]][parsed.setting, default: []].append(value)
        }
        return values.map { identity, settings in
            RepositoryRemoteConfiguration(
                name: identity.name,
                fetchURL: settings["url"]?.last ?? "",
                pushURL: settings["pushurl"]?.last,
                puttyKeyFile: settings["puttykeyfile"]?.last,
                color: settings["color"]?.last,
                prefix: settings["prefix"]?.last,
                pushRefSpecs: settings["push"] ?? [],
                isDisabled: identity.disabled
            )
        }.sorted {
            if $0.isDisabled != $1.isDisabled { return !$0.isDisabled }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func loadRemoteBranchNames(named remoteName: String) async throws -> [String] {
        let repository = try remoteRepository()
        let configured = try await loadRemoteConfigurations()
        guard configured.contains(where: { $0.name == remoteName && !$0.isDisabled }) else {
            throw RepositoryRemoteManagementError.missingRemote(remoteName)
        }
        let result = try await checkedRemoteMutation(
            ["ls-remote", "--heads", "--refs", remoteName],
            in: repository
        )
        let names = result.standardOutputString.split(separator: "\n").compactMap { line -> String? in
            guard let separator = line.firstIndex(of: "\t") else { return nil }
            let ref = line[line.index(after: separator)...]
            let prefix = "refs/heads/"
            guard ref.hasPrefix(prefix) else { return nil }
            let name = String(ref.dropFirst(prefix.count))
            return name.isEmpty ? nil : name
        }
        return Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func saveRemote(_ request: RepositoryRemoteSaveRequest) async throws -> RepositorySnapshot {
        let repository = try remoteRepository()
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RepositoryRemoteManagementError.invalidName }
        let remotes = try await loadRemoteConfigurations()

        if let original = request.originalName {
            guard let existing = remotes.first(where: { $0.name == original && !$0.isDisabled }) else {
                if remotes.contains(where: { $0.name == original && $0.isDisabled }) {
                    throw RepositoryRemoteManagementError.disabledRemoteIsReadOnly
                }
                throw RepositoryRemoteManagementError.missingRemote(original)
            }
            if original != name, remotes.contains(where: { $0.name == name }) {
                throw RepositoryRemoteManagementError.duplicateName(name)
            }
            if existing.name != name {
                _ = try await checkedRemoteMutation(["remote", "rename", existing.name, name], in: repository)
            }
        } else {
            guard !remotes.contains(where: { $0.name == name }) else {
                throw RepositoryRemoteManagementError.duplicateName(name)
            }
            _ = try await checkedRemoteMutation(["remote", "add", name, request.fetchURL], in: repository)
        }

        try await setConfig("remote.\(name).url", value: request.fetchURL, in: repository)
        try await setOptionalConfig("remote.\(name).pushurl", value: normalizedPushURL(request.pushURL, fetchURL: request.fetchURL), in: repository)
        try await setOptionalConfig("remote.\(name).puttykeyfile", value: request.puttyKeyFile, in: repository)
        try await setOptionalConfig("remote.\(name).color", value: request.color, in: repository)
        try await setOptionalConfig("remote.\(name).prefix", value: request.prefix, in: repository)
        return try await loadSnapshot()
    }

    func deleteRemote(named name: String, disabled: Bool) async throws -> RepositorySnapshot {
        let repository = try remoteRepository()
        if disabled {
            _ = try await rawRemoteMutation(["config", "--local", "--remove-section", "--", "-remote.\(name)"], in: repository, acceptedStatuses: [0, 5])
        } else {
            _ = try await checkedRemoteMutation(["remote", "remove", name], in: repository)
        }
        return try await loadSnapshot()
    }

    func setRemote(named name: String, disabled: Bool) async throws -> RepositorySnapshot {
        let repository = try remoteRepository()
        let remotes = try await loadRemoteConfigurations()
        let existingDisabled = !disabled
        guard remotes.contains(where: { $0.name == name && $0.isDisabled == existingDisabled }) else {
            throw RepositoryRemoteManagementError.missingRemote(name)
        }

        let entries = try await localConfigEntries(in: repository)
        let oldSection = existingDisabled ? "-remote" : "remote"
        let newSection = disabled ? "-remote" : "remote"
        let oldPrefix = "\(oldSection).\(name)."
        let newPrefix = "\(newSection).\(name)."
        let retained = entries.compactMap { key, value -> (String, String)? in
            guard key.hasPrefix(oldPrefix) else { return nil }
            return (String(key.dropFirst(oldPrefix.count)), value)
        }
        let destinationAlreadyExists = entries.contains { key, _ in key.hasPrefix(newPrefix) }
        guard !retained.isEmpty else { throw RepositoryRemoteManagementError.missingRemote(name) }

        if existingDisabled {
            _ = try await rawRemoteMutation(["config", "--local", "--remove-section", "--", oldSection + "." + name], in: repository, acceptedStatuses: [0, 5])
        } else {
            _ = try await checkedRemoteMutation(["remote", "remove", name], in: repository)
        }
        if destinationAlreadyExists {
            _ = try await checkedRemoteMutation(["config", "--local", "--remove-section", "--", newSection + "." + name], in: repository)
        }
        for (setting, value) in retained {
            _ = try await checkedRemoteMutation(["config", "--local", "--add", "--", "\(newSection).\(name).\(setting)", value], in: repository)
        }
        return try await loadSnapshot()
    }

    func loadBranchTrackingConfigurations() async throws -> [RepositoryBranchTrackingConfiguration] {
        let snapshot = try await loadSnapshot()
        return snapshot.branches.filter { !$0.isRemote }.map { branch in
            let reference = snapshot.commits.lazy.flatMap(\.references).first {
                ($0.kind == .currentBranch || $0.kind == .localBranch) && $0.name == branch.name
            }
            return RepositoryBranchTrackingConfiguration(
                branchName: branch.name,
                remoteName: reference?.trackingRemote,
                mergeBranch: reference?.mergeWith
            )
        }.sorted { $0.branchName.localizedCaseInsensitiveCompare($1.branchName) == .orderedAscending }
    }

    func setBranchTracking(_ configuration: RepositoryBranchTrackingConfiguration) async throws -> RepositorySnapshot {
        let repository = try remoteRepository()
        let prefix = "branch.\(configuration.branchName)."
        try await setOptionalConfig(prefix + "remote", value: configuration.remoteName, in: repository)
        let mergeValue = configuration.mergeBranch.flatMap { $0.isEmpty ? nil : "refs/heads/\($0)" }
        try await setOptionalConfig(prefix + "merge", value: mergeValue, in: repository)
        return try await loadSnapshot()
    }

    private struct RemoteIdentity: Hashable {
        let name: String
        let disabled: Bool
    }

    private func remoteRepository() throws -> ResolvedGitRepository {
        guard let resolvedRepository else { throw RepositoryMutationError.unavailable }
        return resolvedRepository
    }

    private func localConfigEntries(in repository: ResolvedGitRepository) async throws -> [(String, String)] {
        let result = try await checkedRemoteMutation(["config", "--local", "--null", "--list"], in: repository)
        return result.standardOutput.split(separator: 0, omittingEmptySubsequences: true).compactMap { record in
            guard let newline = record.firstIndex(of: 10) else { return nil }
            return (String(decoding: record[..<newline], as: UTF8.self), String(decoding: record[record.index(after: newline)...], as: UTF8.self))
        }
    }

    private func parseRemoteKey(_ key: String) -> (identity: RemoteIdentity, setting: String)? {
        let disabled: Bool
        let remainder: Substring
        if key.hasPrefix("-remote.") {
            disabled = true
            remainder = key.dropFirst(8)
        } else if key.hasPrefix("remote.") {
            disabled = false
            remainder = key.dropFirst(7)
        } else {
            return nil
        }
        for setting in ["puttykeyfile", "pushurl", "prefix", "color", "url", "fetch", "push"] {
            let suffix = "." + setting
            if remainder.hasSuffix(suffix) {
                return (RemoteIdentity(name: String(remainder.dropLast(suffix.count)), disabled: disabled), setting)
            }
        }
        return nil
    }

    private func normalizedPushURL(_ pushURL: String?, fetchURL: String) -> String? {
        guard let value = pushURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.caseInsensitiveCompare(fetchURL) != .orderedSame
        else { return nil }
        return value
    }

    private func setConfig(_ key: String, value: String, in repository: ResolvedGitRepository) async throws {
        _ = try await checkedRemoteMutation(["config", "--local", key, value], in: repository)
    }

    private func setOptionalConfig(_ key: String, value: String?, in repository: ResolvedGitRepository) async throws {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty {
            try await setConfig(key, value: value, in: repository)
        } else {
            _ = try await rawRemoteMutation(["config", "--local", "--unset-all", key], in: repository, acceptedStatuses: [0, 5])
        }
    }

    private func checkedRemoteMutation(_ arguments: [String], in repository: ResolvedGitRepository) async throws -> GitCommandResult {
        try await rawRemoteMutation(arguments, in: repository, acceptedStatuses: [0])
    }

    private func rawRemoteMutation(_ arguments: [String], in repository: ResolvedGitRepository, acceptedStatuses: Set<Int32>) async throws -> GitCommandResult {
        let result = try await git.run(arguments: arguments, in: repository.rootURL)
        guard acceptedStatuses.contains(result.exitStatus) else {
            throw GitError.commandFailed(
                arguments: result.arguments,
                status: result.exitStatus,
                stderr: result.standardErrorString.isEmpty ? result.standardOutputString : result.standardErrorString
            )
        }
        return result
    }
}
