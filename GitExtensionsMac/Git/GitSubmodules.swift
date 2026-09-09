import GitExtensionsCore
import Foundation

package struct RepositorySubmoduleContext: Sendable {
    package let repositoryURL: URL
    package let submodules: [Submodule]
    package let branches: [String: String]
}

package struct RepositoryAddSubmoduleRequest: Sendable {
    package let source: String
    package let path: String
    package let branch: String
    package let force: Bool
    package init(source: String, path: String, branch: String = "", force: Bool = false) {
        self.source = source; self.path = path; self.branch = branch; self.force = force
    }
}

package enum RepositorySubmoduleAction: Sendable {
    case update(path: String?)
    case synchronize(path: String?)
    case remove(path: String)
    case stageCurrent(path: String)
}

package struct RepositorySubmoduleConflictContext: Sendable {
    package let conflict: RepositoryConflict
    package let repositoryURL: URL
    package let currentID: ObjectID?
    fileprivate let changeState: [Data]
}

package struct RepositorySubmoduleCheckoutContext: Sendable {
    package let source: any RepositoryBrowsingDataSource
    package let branches: RepositoryBranchContext
}

package struct RepositorySubmoduleResult: Sendable {
    package let succeeded: Bool
    package let changed: Bool
    package let output: String
    package init(succeeded: Bool, changed: Bool, output: String) {
        self.succeeded = succeeded; self.changed = changed; self.output = output
    }
}

package enum RepositorySubmoduleError: LocalizedError {
    case requiredPaths, missingSubmodule, invalidPath
    package var errorDescription: String? {
        switch self {
        case .requiredPaths: "A remote path and local path are required."
        case .missingSubmodule: "The selected submodule no longer exists. Refresh the submodule list."
        case .invalidPath: "Choose a submodule path inside this repository."
        }
    }
}

package protocol RepositorySubmoduleManagingDataSource: Sendable {
    func loadSubmoduleContext() async throws -> RepositorySubmoduleContext
    func submoduleBranches(source: String) async throws -> [String]
    func addSubmodule(_ request: RepositoryAddSubmoduleRequest, output: @escaping GitOutputHandler) async throws -> RepositorySubmoduleResult
    func performSubmoduleAction(_ action: RepositorySubmoduleAction, output: @escaping GitOutputHandler) async throws -> RepositorySubmoduleResult
    func submoduleRepository(path: String) async throws -> any RepositoryBrowsingDataSource
    func loadSubmoduleConflict(path: String) async throws -> RepositorySubmoduleConflictContext
    func loadSubmoduleConflictCheckout(path: String) async throws -> RepositorySubmoduleCheckoutContext
    func submoduleConflictChanged(since context: RepositorySubmoduleConflictContext) async throws -> Bool
    func submoduleTreeRepository(_ item: SubmoduleTreeItem) async throws -> any RepositoryBrowsingDataSource
    func submoduleTreeLocation(_ item: SubmoduleTreeItem) async throws -> URL
    func updateSubmoduleTreeItem(_ item: SubmoduleTreeItem, output: @escaping GitOutputHandler) async throws -> RepositorySubmoduleResult
}

package enum GitSubmoduleCommands {
    package static func directoryName(from source: String) -> String {
        var value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.last == "/" { value.removeLast() }
        value = String(value.split(whereSeparator: { $0 == "/" || $0 == ":" }).last ?? "")
        if value.lowercased().hasSuffix(".git") { value.removeLast(4) }
        return value
    }
    package static func add(_ request: RepositoryAddSubmoduleRequest) -> GitCommand {
        GitCommand(arguments: ["submodule", "add"] + (request.force ? ["-f"] : [])
            + (request.branch.isEmpty ? [] : ["-b", request.branch.trimmingCharacters(in: .whitespacesAndNewlines)])
            + [request.source, request.path], accessesRemote: true, changesRepositoryState: true)
    }
    package static func update(path: String?) -> GitCommand {
        GitCommand(arguments: ["submodule", "update", "--init", "--recursive"] + argument(path),
                   accessesRemote: true, changesRepositoryState: true)
    }
    package static func synchronize(path: String?) -> GitCommand {
        GitCommand(arguments: ["submodule", "sync"] + argument(path), accessesRemote: false, changesRepositoryState: true)
    }
    private static func argument(_ path: String?) -> [String] {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [path.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
    package static func branches(from output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: "refs/heads/") else { return nil }
            return String(line[range.upperBound...])
        }
    }
}

extension GitRepositoryModule: RepositorySubmoduleManagingDataSource {
    func loadSubmoduleTree(repository: ResolvedGitRepository, descendants: [Submodule]? = nil) async throws -> [SubmoduleTreeItem] {
        var top = repository
        var visited: Set<String> = [top.rootURL.resolvingSymlinksInPath().path]
        while !top.isBare {
            let result = try await git.run(GitCommand(arguments: ["rev-parse", "--show-superproject-working-tree"], accessesRemote: false, changesRepositoryState: false), in: top.rootURL)
            let path = result.standardOutputString.trimmingCharacters(in: .newlines)
            guard result.succeeded, !path.isEmpty else { break }
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard visited.insert(url.path).inserted else { break }
            top = try await resolveRepository(at: url)
        }
        let modules: [Submodule]
        if top.isBare { modules = [] }
        else if top.rootURL == repository.rootURL, let descendants { modules = descendants }
        else { modules = try await loadSubmodules(repository: top, recursive: true) }
        var items = [try await submoduleTreeItem(url: top.rootURL, parent: top.rootURL, path: "", localPath: "", module: nil, current: repository.rootURL, bare: top.isBare)]
        for module in modules {
            let url = top.rootURL.appendingPathComponent(module.path).standardizedFileURL
            let parent = top.rootURL.appendingPathComponent(module.parentPath).standardizedFileURL
            items.append(try await submoduleTreeItem(url: url, parent: parent, path: module.path, localPath: module.localPath, module: module, current: repository.rootURL))
        }
        return items
    }

    private func submoduleTreeItem(url: URL, parent: URL, path: String, localPath: String, module: Submodule?, current: URL, bare: Bool = false) async throws -> SubmoduleTreeItem {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let initialized = module == nil || FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
        var head: ObjectID?
        var branch: String?
        var dirty = module?.isDirty ?? false
        var description = ""
        var state: SubmoduleTreeItem.CommitState = exists ? .uninitialized : .missing
        var added: Int?, removed: Int?
        if initialized && exists {
            let headResult = try await git.run(GitCommand(arguments: ["rev-parse", "--verify", "HEAD"], accessesRemote: false, changesRepositoryState: false), in: url)
            if headResult.succeeded { head = try? ObjectID.parse(headResult.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let branchResult = try await git.run(GitCommand(arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"], accessesRemote: false, changesRepositoryState: false), in: url)
            branch = bare ? nil : (branchResult.succeeded ? branchResult.standardOutputString.trimmingCharacters(in: .newlines) : "no branch")
            if module == nil && !bare {
                let status = try await git.run(GitCommand(arguments: ["status", "--porcelain=v1", "-z"], accessesRemote: false, changesRepositoryState: false), in: url)
                dirty = status.succeeded && !status.standardOutput.isEmpty
            }
            state = module != nil && head == nil ? .modified : .same
            if let recorded = module?.expectedCommitID, let head, recorded != head {
                state = .modified
                let counts = try await git.run(GitCommand(arguments: ["rev-list", "\(head.string)...\(recorded.string)", "--count", "--left-right"], accessesRemote: false, changesRepositoryState: false), in: url)
                let values = counts.standardOutputString.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
                if counts.succeeded, values.count == 2 {
                    added = values[0]; removed = values[1]
                    if values[0] > 0 && values[1] == 0 { state = .ahead }
                    else if values[0] == 0 && values[1] > 0 { state = .behind }
                }
            }
            var timestamps: [ObjectID: Int64] = [:]
            for id in [module?.expectedCommitID, head].compactMap({ $0 }) {
                guard timestamps[id] == nil else { continue }
                let detail = try await git.run(GitCommand(arguments: ["show", "-s", "--format=%ct%x00%ci%x00%B", id.string], accessesRemote: false, changesRepositoryState: false), in: url)
                let fields = detail.standardOutputString.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false)
                if detail.succeeded, fields.count == 3 {
                    timestamps[id] = Int64(fields[0])
                    description += "\(id == head ? "To" : "From"): \(id.string)\n\(fields[1])\n\(fields[2].trimmingCharacters(in: .newlines))\n"
                }
            }
            if state == .modified, added != nil, removed != nil,
               let head, let recorded = module?.expectedCommitID, let date = timestamps[head], let oldDate = timestamps[recorded] {
                if date > oldDate { state = .newer }
                else if date < oldDate { state = .older }
            }
            if module?.state == .conflicted { state = .conflicted }
            if dirty {
                let status = try await git.run(GitCommand(arguments: ["status", "--short", "--untracked-files=no"], accessesRemote: false, changesRepositoryState: false), in: url)
                if status.succeeded && !status.standardOutput.isEmpty {
                    let lines = status.standardOutputString.split(separator: "\n")
                    description += "Status:\n" + lines.prefix(5).joined(separator: "\n") + (lines.count > 5 ? "\n…" : "")
                }
            }
        }
        return SubmoduleTreeItem(repositoryURL: url, parentURL: parent, path: path, localPath: localPath,
            isCurrent: url.resolvingSymlinksInPath() == current.resolvingSymlinksInPath(), isTop: module == nil,
            isInitialized: initialized && exists, branch: branch, commitID: head, recordedID: module?.expectedCommitID,
            commitState: state, addedCommits: added, removedCommits: removed, isDirty: dirty, commitDescription: description)
    }

    private func validatedSubmoduleTreeItem(_ item: SubmoduleTreeItem) async throws -> SubmoduleTreeItem {
        guard let current = resolvedRepository else { throw RepositorySubmoduleError.missingSubmodule }
        guard let actual = try await loadSubmoduleTree(repository: current).first(where: { $0.repositoryURL.resolvingSymlinksInPath() == item.repositoryURL.resolvingSymlinksInPath() }) else { throw RepositorySubmoduleError.missingSubmodule }
        return actual
    }

    package func submoduleTreeRepository(_ item: SubmoduleTreeItem) async throws -> any RepositoryBrowsingDataSource {
        let actual = try await validatedSubmoduleTreeItem(item)
        guard actual.isInitialized else { throw GitError.invalidRepository(actual.repositoryURL.path) }
        if actual.isCurrent { return self }
        let child = GitRepositoryModule(repositoryURL: actual.repositoryURL, git: git)
        _ = try await child.loadRepositoryState()
        return child
    }

    package func submoduleTreeLocation(_ item: SubmoduleTreeItem) async throws -> URL {
        let actual = try await validatedSubmoduleTreeItem(item)
        guard actual.isInitialized else { throw GitError.invalidRepository(actual.repositoryURL.path) }
        return actual.repositoryURL
    }

    package func updateSubmoduleTreeItem(_ item: SubmoduleTreeItem, output: @escaping GitOutputHandler) async throws -> RepositorySubmoduleResult {
        let actual = try await validatedSubmoduleTreeItem(item)
        let parent = try await resolveRepository(at: actual.parentURL)
        guard !parent.isBare else { throw GitError.invalidRepository(parent.rootURL.path) }
        return try await executeSubmoduleCommands([GitSubmoduleCommands.update(path: actual.isTop ? nil : actual.localPath)], repository: parent, output: output)
    }

    package func loadSubmoduleConflictCheckout(path: String) async throws -> RepositorySubmoduleCheckoutContext {
        let conflict = try await loadSubmoduleConflict(path: path)
        guard let local = conflict.conflict.local?.objectID, let remote = conflict.conflict.remote?.objectID else { throw RepositorySubmoduleError.missingSubmodule }
        let child = try await submoduleRepository(path: path)
        let state = try await child.loadRepositoryState()
        var localNames: Set<String>?
        var remoteNames: Set<String>?
        for id in [local, remote] {
            for remoteOnly in [false, true] {
                let result = try await git.run(GitCommand(arguments: ["branch"] + (remoteOnly ? ["-r"] : []) + ["--contains", id.string], accessesRemote: false, changesRepositoryState: false), in: conflict.repositoryURL)
                let names = Set(result.succeeded ? result.standardOutputString.split(separator: "\n").map { String($0.dropFirst(2)) }.filter { !$0.hasPrefix("(") && !$0.contains(" -> ") && !$0.hasSuffix("/HEAD") } : [])
                if remoteOnly { remoteNames = remoteNames.map { $0.intersection(names) } ?? names }
                else { localNames = localNames.map { $0.intersection(names) } ?? names }
            }
        }
        let context = RepositoryBranchContext(repository: state.identity.currentRepository, headID: state.identity.headID,
            branches: state.references.branches.filter { localNames?.contains($0.name) == true },
            remotes: state.navigation.remotes.map { remote in
                Remote(id: remote.id, name: remote.name, fetchURL: remote.fetchURL,
                    branches: remote.branches.filter { remoteNames?.contains(remote.name + "/" + $0.name) == true }, isDisabled: remote.isDisabled)
            }, referencesByCommit: state.references.referencesByCommit, submodules: state.navigation.submodules)
        return RepositorySubmoduleCheckoutContext(source: child, branches: context)
    }
    package func submoduleRepository(path: String) async throws -> any RepositoryBrowsingDataSource {
        let repository = try mutationRepository()
        try validateSubmodulePath(path, root: repository.rootURL)
        let registered = (try? await loadSubmodules(repository: repository, recursive: true).contains(where: { $0.path == path })) ?? false
        let conflicted = try await loadConflicts().contains(where: { $0.path == path && $0.isSubmodule })
        guard registered || conflicted else { throw RepositorySubmoduleError.missingSubmodule }
        let url = repository.rootURL.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else { throw GitError.invalidRepository(url.path) }
        let child = GitRepositoryModule(repositoryURL: url, git: git)
        _ = try await child.loadRepositoryState()
        return child
    }

    package func loadSubmoduleConflict(path: String) async throws -> RepositorySubmoduleConflictContext {
        let repository = try mutationRepository()
        try validateSubmodulePath(path, root: repository.rootURL)
        guard let conflict = try await loadConflicts().first(where: { $0.path == path && $0.isSubmodule }) else { throw RepositorySubmoduleError.missingSubmodule }
        let url = repository.rootURL.appendingPathComponent(path)
        var currentID: ObjectID?
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
            let result = try await git.run(GitCommand(arguments: ["rev-parse", "--verify", "HEAD"], accessesRemote: false, changesRepositoryState: false), in: url)
            if result.succeeded { currentID = try ObjectID.parse(result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return RepositorySubmoduleConflictContext(conflict: conflict, repositoryURL: url, currentID: currentID,
            changeState: try await submoduleMutationState(repository: repository))
    }

    package func submoduleConflictChanged(since context: RepositorySubmoduleConflictContext) async throws -> Bool {
        try await submoduleMutationState(repository: mutationRepository()) != context.changeState
    }
    package func loadSubmoduleContext() async throws -> RepositorySubmoduleContext {
        let repository = try mutationRepository()
        let modules = try await loadSubmodules(repository: repository)
        var branches: [String: String] = [:]
        for module in modules where module.state != .uninitialized {
            let directory = repository.rootURL.appendingPathComponent(module.path)
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) else { continue }
            let result = try await git.run(GitCommand(arguments: ["branch", "--show-current"], accessesRemote: false, changesRepositoryState: false), in: directory)
            if result.succeeded { branches[module.path] = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return RepositorySubmoduleContext(repositoryURL: repository.rootURL, submodules: modules, branches: branches)
    }

    package func submoduleBranches(source: String) async throws -> [String] {
        guard !source.isEmpty, !source.hasPrefix("-"), !source.contains("\0") else { return [] }
        let repository = try mutationRepository()
        let result = try await git.run(GitCommand(arguments: ["ls-remote", "--heads", source], accessesRemote: true, changesRepositoryState: false), in: repository.rootURL)
        return GitSubmoduleCommands.branches(from: result.standardOutputString)
    }

    package func addSubmodule(_ request: RepositoryAddSubmoduleRequest, output: @escaping GitOutputHandler) async throws -> RepositorySubmoduleResult {
        guard !request.source.isEmpty, !request.path.isEmpty else { throw RepositorySubmoduleError.requiredPaths }
        let repository = try mutationRepository()
        try validateSubmodulePath(request.path, root: repository.rootURL)
        guard !request.source.hasPrefix("-"), !request.source.contains("\0") else { throw RepositorySubmoduleError.requiredPaths }
        return try await executeSubmoduleCommands([GitSubmoduleCommands.add(request)], repository: repository, output: output)
    }

    package func performSubmoduleAction(_ action: RepositorySubmoduleAction, output: @escaping GitOutputHandler) async throws -> RepositorySubmoduleResult {
        var repository = try mutationRepository()
        if case .stageCurrent(let path) = action {
            try validateSubmodulePath(path, root: repository.rootURL)
            guard try await loadConflicts().contains(where: { $0.path == path && $0.isSubmodule }) else { throw RepositorySubmoduleError.missingSubmodule }
            return try await executeSubmoduleCommands([GitCommand(arguments: ["add", "--", path], accessesRemote: false, changesRepositoryState: true)], repository: repository, output: output)
        }
        var modules = try await loadSubmodules(repository: repository, recursive: true)
        var path: String?
        switch action {
        case .update(let value), .synchronize(let value): path = value
        case .remove(let value), .stageCurrent(let value): path = value
        }
        if let selectedPath = path {
            try validateSubmodulePath(selectedPath, root: repository.rootURL)
            guard let selected = modules.first(where: { $0.path == selectedPath }) else { throw RepositorySubmoduleError.missingSubmodule }
            if !selected.parentPath.isEmpty {
                repository = try await resolveRepository(at: repository.rootURL.appendingPathComponent(selected.parentPath))
                modules = try await loadSubmodules(repository: repository)
                path = selected.localPath
            }
        }
        modules = try await loadSubmodules(repository: repository)
        let commands: [GitCommand]
        switch action {
        case .update: commands = [GitSubmoduleCommands.update(path: path)]
        case .synchronize: commands = [GitSubmoduleCommands.synchronize(path: path)]
        case .stageCurrent:
            guard let path, try await loadConflicts().contains(where: { $0.path == path && $0.isSubmodule }) else { throw RepositorySubmoduleError.missingSubmodule }
            commands = [GitCommand(arguments: ["add", "--", path], accessesRemote: false, changesRepositoryState: true)]
        case .remove:
            guard let path, let module = modules.first(where: { $0.path == path }) else { throw RepositorySubmoduleError.missingSubmodule }
            let local = try await git.run(GitCommand(arguments: ["config", "--local", "--get-regexp", "^submodule\\."], accessesRemote: false, changesRepositoryState: false), in: repository.rootURL)
            guard local.succeeded || local.exitStatus == 1 else { throw commandError(from: local) }
            let fileConfig = try await git.run(GitCommand(arguments: ["config", "--null", "--file", ".gitmodules", "--list"], accessesRemote: false, changesRepositoryState: false), in: repository.rootURL)
            guard fileConfig.succeeded else { throw commandError(from: fileConfig) }
            let hasOtherSections = fileConfig.standardOutput.split(separator: 0).contains { record in
                let key = String(decoding: record.prefix(while: { $0 != 10 }), as: UTF8.self)
                guard let separator = key.lastIndex(of: ".") else { return false }
                return key[..<separator] != "submodule.\(module.name)"
            }
            var arguments = [["rm", "--cached", path]]
            if hasOtherSections {
                arguments += [["config", "--file", ".gitmodules", "--remove-section", "submodule.\(module.name)"], ["add", "--", ".gitmodules"]]
            } else { arguments += [["rm", "--cached", ".gitmodules"]] }
            if local.standardOutputString.split(separator: "\n").contains(where: { $0.hasPrefix("submodule.\(module.name).") }) {
                arguments += [["config", "--local", "--remove-section", "submodule.\(module.name)"]]
            }
            commands = arguments.map { GitCommand(arguments: $0, accessesRemote: false, changesRepositoryState: true) }
        }
        return try await executeSubmoduleCommands(commands, repository: repository, output: output)
    }

    private func validateSubmodulePath(_ path: String, root: URL) throws {
        let destination = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL.resolvingSymlinksInPath()
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard !path.isEmpty, !path.hasPrefix("-"), !path.contains("\0"), destination.path.hasPrefix(base),
              !destination.pathComponents.contains(".git") else { throw RepositorySubmoduleError.invalidPath }
    }

    private func submoduleMutationState(repository: ResolvedGitRepository) async throws -> [Data] {
        var state: [Data] = []
        for arguments in [["status", "--porcelain=v1", "-z", "--untracked-files=all"],
                          ["ls-files", "--stage", "-z"], ["config", "--local", "--null", "--list"],
                          ["submodule", "status", "--recursive"]] {
            let result = try await git.run(GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: false), in: repository.rootURL)
            state += [result.standardOutput, result.standardError]
        }
        state.append((try? Data(contentsOf: repository.rootURL.appendingPathComponent(".gitmodules"))) ?? Data())
        for module in (try? await loadSubmodules(repository: repository, recursive: true)) ?? [] where module.state != .uninitialized {
            let url = repository.rootURL.appendingPathComponent(module.path)
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else { continue }
            let config = try await git.run(GitCommand(arguments: ["config", "--local", "--null", "--list"], accessesRemote: false, changesRepositoryState: false), in: url)
            state.append(config.standardOutput)
            let refs = try await git.run(GitCommand(arguments: ["show-ref", "--head"], accessesRemote: false, changesRepositoryState: false), in: url)
            state.append(refs.standardOutput)
        }
        return state
    }

    private func executeSubmoduleCommands(_ commands: [GitCommand], repository: ResolvedGitRepository, output: @escaping GitOutputHandler) async throws -> RepositorySubmoduleResult {
        let before = try await submoduleMutationState(repository: repository)
        var succeeded = true
        var transcript = ""
        do {
            for command in commands {
                let result = try await git.runStreaming(command, in: repository.rootURL, output: output)
                transcript += result.standardOutputString + result.standardErrorString
                if !result.succeeded { succeeded = false; break }
            }
        } catch { succeeded = false; transcript += error.localizedDescription }
        let after = try await Task { try await self.submoduleMutationState(repository: repository) }.value
        return RepositorySubmoduleResult(succeeded: succeeded, changed: before != after, output: transcript)
    }
}
