import Foundation

enum RepositoryBranchCreationMode: Hashable, Sendable {
    case normal
    case orphan(clearWorkingDirectoryAndIndex: Bool)
}

struct RepositoryCreateBranchRequest: Hashable, Sendable {
    let name: String
    let sourceRevision: String?
    let checkoutAfterCreation: Bool
    let mode: RepositoryBranchCreationMode
    let updateSubmodulesAfterCheckout: Bool

    init(
        name: String,
        sourceRevision: String?,
        checkoutAfterCreation: Bool,
        mode: RepositoryBranchCreationMode,
        updateSubmodulesAfterCheckout: Bool = false
    ) {
        self.name = name
        self.sourceRevision = sourceRevision
        self.checkoutAfterCreation = checkoutAfterCreation
        self.mode = mode
        self.updateSubmodulesAfterCheckout = updateSubmodulesAfterCheckout
    }
}

struct RepositoryDeleteBranchesRequest: Hashable, Sendable {
    let names: [String]
    let allowUnmerged: Bool
    let removeLinkedWorktrees: Bool
}

struct RepositoryRenameBranchRequest: Hashable, Sendable {
    let oldName: String
    let newName: String
}

struct RepositoryBranchDeletionCandidate: Hashable, Sendable {
    let name: String
    let isCurrent: Bool
    let isMergedIntoHEAD: Bool
    let worktreePath: String?
    let isMainWorktree: Bool
}

struct RepositoryRevisionDivergence: Hashable, Sendable {
    let added: Int
    let removed: Int

    var displayText: String {
        added == 0 && removed == 0 ? "=" : "(+\(added)-\(removed))"
    }
}

enum RepositoryBranchNameNormalizer {
    static func normalize(
        _ branchName: String,
        replacementToken: String = "_",
        allowTrailingSlash: Bool = false
    ) -> String {
        let replacement = String(replacementToken.prefix(1))
        var value = branchName

        value = value.replacingOccurrences(of: #"\\+"#, with: replacement, options: .regularExpression)
        if value == "@" { value = replacement }
        value = value.replacingOccurrences(of: "@{", with: replacement)
        value = value.replacingOccurrences(of: #"\.+$"#, with: replacement, options: .regularExpression)
        value = value.replacingOccurrences(of: #"[?*\[]"#, with: replacement, options: .regularExpression)

        var characters = ""
        for scalar in value.unicodeScalars {
            let number = scalar.value
            let isASCIIPathCharacter = number > 0x20
                && number < 0x7E
                && scalar != "^"
                && scalar != ":"
                && !"\"<>|".unicodeScalars.contains(scalar)
            let isUnicodeLetterOrDigit = CharacterSet.alphanumerics.contains(scalar)
            characters += isASCIIPathCharacter || isUnicodeLetterOrDigit ? String(scalar) : replacement
        }
        value = characters
        value = value.replacingOccurrences(of: #"\.{2,}"#, with: replacement, options: .regularExpression)
        value = value.replacingOccurrences(of: #"/{2,}"#, with: "/", options: .regularExpression)
        if value.hasPrefix("/") { value.removeFirst() }
        if !allowTrailingSlash, value.hasSuffix("/") { value.removeLast() }

        var components = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for index in components.indices {
            if components[index].hasPrefix(".") {
                components[index] = components[index].replacingOccurrences(
                    of: #"^\.*"#,
                    with: replacement,
                    options: .regularExpression
                )
            }
            if components[index].lowercased().hasSuffix(".lock") {
                components[index] = String(components[index].dropLast(5)) + replacement + "lock"
            }
        }
        return components.joined(separator: "/")
    }
}

enum RepositoryBranchError: LocalizedError, Sendable {
    case branchNotFound(String)
    case branchCheckedOut(name: String, path: String)
    case branchCheckedOutInMainWorktree(name: String, path: String)
    case unmergedBranches([String])

    var errorDescription: String? {
        switch self {
        case .branchNotFound(let name):
            "The local branch ‘\(name)’ does not exist."
        case .branchCheckedOut(let name, let path):
            "The branch ‘\(name)’ is checked out in the worktree at \(path)."
        case .branchCheckedOutInMainWorktree(let name, let path):
            "The branch ‘\(name)’ is checked out in the main worktree at \(path) and cannot be deleted here."
        case .unmergedBranches(let names):
            "The following branches have not been merged into HEAD: \(names.joined(separator: ", "))."
        }
    }
}

protocol RepositoryCheckoutBranchDataSource: RepositoryMutationStateDataSource {
    func checkout(_ request: RepositoryCheckoutRequest) async throws -> RepositoryMutationResult
    func createBranch(_ request: RepositoryCreateBranchRequest) async throws -> RepositoryMutationResult
    func createBranch(named name: String) async throws -> RepositoryMutationResult
    func branchDeletionCandidates(names: [String]) async throws -> [RepositoryBranchDeletionCandidate]
    func deleteBranches(_ request: RepositoryDeleteBranchesRequest) async throws -> RepositoryMutationResult
    func renameBranch(_ request: RepositoryRenameBranchRequest) async throws -> RepositoryMutationResult
    func isValidBranchName(_ name: String) async throws -> Bool
    func isValidRevision(_ revision: String) async throws -> Bool
    func isAncestor(_ ancestor: String, of descendant: String) async throws -> Bool
    func divergence(from revision: String, to target: String) async throws -> RepositoryRevisionDivergence
    func updateSubmodulesAfterCheckout() async throws -> RepositoryMutationResult
}

extension GitRepositoryBrowsingDataSource {
    func createBranch(_ request: RepositoryCreateBranchRequest) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard try await isValidBranchName(name) else {
            throw RepositoryMutationError.invalidBranchName(name)
        }

        let before = try await mutationState(in: repository)
        let source = request.sourceRevision?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSource: String?
        if let source, !source.isEmpty {
            resolvedSource = try await resolvedCommit(source, repository: repository)
        } else if before.headID != nil {
            resolvedSource = try await resolvedCommit("HEAD", repository: repository)
        } else {
            resolvedSource = nil
        }

        switch request.mode {
        case .normal:
            guard let resolvedSource else {
                throw RepositoryMutationError.invalidRevision(source ?? "HEAD")
            }
            let arguments = request.checkoutAfterCreation
                ? ["checkout", "-b", name, resolvedSource]
                : ["branch", name, resolvedSource]
            _ = try await checkedMutation(arguments, in: repository)

        case .orphan(let clearWorkingDirectoryAndIndex):
            var arguments = ["checkout", "--orphan", name]
            if let resolvedSource { arguments.append(resolvedSource) }
            _ = try await checkedMutation(arguments, in: repository)
            if clearWorkingDirectoryAndIndex {
                _ = try await checkedMutation(["rm", "--force", "-r", "."], in: repository)
            }
        }

        if request.checkoutAfterCreation,
           request.updateSubmodulesAfterCheckout,
           before.headID != (try await mutationState(in: repository)).headID {
            _ = try await checkedMutation(["submodule", "update", "--init", "--recursive"], in: repository)
        }

        let action: Bool
        if case .orphan = request.mode {
            action = true
        } else {
            action = request.checkoutAfterCreation
        }
        return try await refreshedMutationResult(
            message: action ? "Created and checked out \(name)." : "Created branch \(name).",
            selectedCommitID: nil
        )
    }

    func branchDeletionCandidates(names: [String]) async throws -> [RepositoryBranchDeletionCandidate] {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        let localNames = try await localBranchNames(repository: repository)
        let requested = uniqueNames(names)

        for name in requested where !localNames.contains(name) {
            throw RepositoryBranchError.branchNotFound(name)
        }

        let mergedNames: Set<String>
        if state.currentBranch == nil {
            mergedNames = []
        } else {
            let merged = try await rawMutation(
                ["branch", "--merged", "HEAD", "--format=%(refname:short)"],
                in: repository
            )
            guard merged.succeeded else { throw commandError(from: merged) }
            mergedNames = Set(merged.standardOutputString.split(separator: "\n").map(String.init))
        }

        var worktreeState = try await branchWorktrees(repository: repository)
        if !worktreeState.prunableBranches.isDisjoint(with: requested) {
            _ = try await checkedMutation(["worktree", "prune"], in: repository)
            worktreeState = try await branchWorktrees(repository: repository)
        }
        return requested.map { name in
            RepositoryBranchDeletionCandidate(
                name: name,
                isCurrent: name == state.currentBranch,
                isMergedIntoHEAD: mergedNames.contains(name),
                worktreePath: worktreeState.active[name]?.path,
                isMainWorktree: worktreeState.active[name]?.isMain ?? false
            )
        }
    }

    func deleteBranches(_ request: RepositoryDeleteBranchesRequest) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let candidates = try await branchDeletionCandidates(names: request.names)
        if let current = candidates.first(where: \.isCurrent) {
            throw RepositoryMutationError.currentBranch(current.name)
        }

        if let main = candidates.first(where: { $0.worktreePath != nil && $0.isMainWorktree }),
           let path = main.worktreePath {
            throw RepositoryBranchError.branchCheckedOutInMainWorktree(name: main.name, path: path)
        }
        let linked = candidates.filter { $0.worktreePath != nil }
        if !linked.isEmpty, !request.removeLinkedWorktrees,
           let candidate = linked.first, let path = candidate.worktreePath {
            throw RepositoryBranchError.branchCheckedOut(name: candidate.name, path: path)
        }

        let unmerged = candidates.filter { !$0.isMergedIntoHEAD }.map(\.name)
        if !unmerged.isEmpty, !request.allowUnmerged {
            throw RepositoryBranchError.unmergedBranches(unmerged)
        }

        if request.removeLinkedWorktrees {
            for candidate in linked {
                guard let path = candidate.worktreePath else { continue }
                _ = try await checkedMutation(["worktree", "remove", "--force", path], in: repository)
            }
            if !linked.isEmpty {
                _ = try await checkedMutation(["worktree", "prune"], in: repository)
            }
        }

        let names = candidates.map(\.name)
        _ = try await checkedMutation(["branch", "--delete", "--force"] + names, in: repository)
        let noun = names.count == 1 ? "branch" : "branches"
        return try await refreshedMutationResult(
            message: "Deleted \(noun) \(names.joined(separator: ", ")).",
            selectedCommitID: nil
        )
    }

    func renameBranch(_ request: RepositoryRenameBranchRequest) async throws -> RepositoryMutationResult {
        guard let repository = resolvedRepository else { throw RepositoryMutationError.unavailable }
        let oldName = request.oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = request.newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldName.isEmpty else { throw RepositoryBranchError.branchNotFound(oldName) }
        guard try await isValidBranchName(newName) else {
            throw RepositoryMutationError.invalidBranchName(newName)
        }
        guard oldName != newName else {
            return try await refreshedMutationResult(message: "Branch name unchanged.", selectedCommitID: nil)
        }
        _ = try await checkedMutation(["branch", "-m", oldName, newName], in: repository)
        let snapshot = try await loadSnapshot()
        return RepositoryMutationResult(
            snapshot: snapshot,
            selectedCommitID: snapshot.commits.first(where: { !$0.isArtificial })?.id,
            outcome: .completed,
            message: "Renamed \(oldName) to \(newName)."
        )
    }

    func isValidBranchName(_ name: String) async throws -> Bool {
        guard let repository = resolvedRepository else { throw RepositoryMutationError.unavailable }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return try await rawMutation(["check-ref-format", "--branch", normalized], in: repository).succeeded
    }

    func isValidRevision(_ revision: String) async throws -> Bool {
        guard let repository = resolvedRepository else { throw RepositoryMutationError.unavailable }
        let result = try await rawMutation(
            ["rev-parse", "--verify", "--quiet", "\(revision)^{commit}"],
            in: repository
        )
        return result.succeeded
            && !result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func isAncestor(_ ancestor: String, of descendant: String) async throws -> Bool {
        let repository = try mutationRepository()
        let result = try await rawMutation(
            ["merge-base", "--is-ancestor", ancestor, descendant],
            in: repository
        )
        if result.exitStatus == 0 { return true }
        if result.exitStatus == 1 { return false }
        throw commandError(from: result)
    }

    func divergence(from revision: String, to target: String) async throws -> RepositoryRevisionDivergence {
        let repository = try mutationRepository()
        let result = try await rawMutation(
            ["rev-list", "--count", "--left-right", "\(revision)...\(target)"],
            in: repository
        )
        guard result.succeeded else { throw commandError(from: result) }
        let counts = result.standardOutputString
            .split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
            .compactMap { Int($0) }
        guard counts.count == 2 else {
            throw RepositoryMutationError.invalidRevision(target)
        }
        return RepositoryRevisionDivergence(added: counts[0], removed: counts[1])
    }

    func updateSubmodulesAfterCheckout() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        _ = try await checkedMutation(["submodule", "update", "--init", "--recursive"], in: repository)
        return try await refreshedMutationResult(message: "Updated submodules.", selectedCommitID: nil)
    }

    private func resolvedCommit(_ revision: String, repository: ResolvedGitRepository) async throws -> String {
        let result = try await rawMutation(
            ["rev-parse", "--verify", "--quiet", "\(revision)^{commit}"],
            in: repository
        )
        let value = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !value.isEmpty else {
            throw RepositoryMutationError.invalidRevision(revision)
        }
        return value
    }

    private func localBranchNames(repository: ResolvedGitRepository) async throws -> Set<String> {
        let result = try await checkedMutation(
            ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
            in: repository
        )
        return Set(result.standardOutputString.split(separator: "\n").map(String.init))
    }

    private func branchWorktrees(repository: ResolvedGitRepository) async throws -> (
        active: [String: (path: String, isMain: Bool)],
        prunableBranches: Set<String>
    ) {
        let result = try await checkedMutation(["worktree", "list", "--porcelain"], in: repository)
        var worktreePath: String?
        var branchName: String?
        var isPrunable = false
        var isMainWorktree = true
        var mapping: [String: (path: String, isMain: Bool)] = [:]
        var prunableBranches = Set<String>()
        let lines = result.standardOutputString.components(separatedBy: "\n") + [""]
        for line in lines {
            if line.hasPrefix("worktree ") {
                worktreePath = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/") {
                branchName = String(line.dropFirst("branch refs/heads/".count))
            } else if line.hasPrefix("prunable") {
                isPrunable = true
            } else if line.isEmpty {
                if let branchName, let worktreePath {
                    if isPrunable {
                        prunableBranches.insert(branchName)
                    } else {
                        mapping[branchName] = (worktreePath, isMainWorktree)
                    }
                }
                if worktreePath != nil { isMainWorktree = false }
                worktreePath = nil
                branchName = nil
                isPrunable = false
            }
        }
        return (mapping, prunableBranches)
    }

    private func uniqueNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.compactMap { raw in
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }
}
