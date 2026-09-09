import GitExtensionsCore
import Foundation

package struct RepositoryWorktreeContext: Sendable {
    package let worktrees: [Worktree]
    package let branches: [String]
    package let currentBranch: String?
    package let repositoryURL: URL
    package var availableBranches: [String] { branches.filter { $0 != currentBranch } }
    package var basePath: String { worktrees.first?.path ?? repositoryURL.path }
}

package struct RepositoryCreateWorktreeRequest: Sendable {
    package let path: String
    package let branch: String
    package let createBranch: Bool
    package init(path: String, branch: String, createBranch: Bool) {
        self.path = path; self.branch = branch; self.createBranch = createBranch
    }
}

package struct RepositoryWorktreeResult: Sendable {
    package let changed: Bool
    package let succeeded: Bool
    package let output: String
}

package enum RepositoryWorktreeError: LocalizedError {
    case invalidPath
    case invalidBranch
    case protectedWorktree
    package var errorDescription: String? {
        switch self {
        case .invalidPath: "Choose a new or empty worktree directory."
        case .invalidBranch: "Choose an existing branch or a valid, unused new branch name."
        case .protectedWorktree: "The main, current, or missing worktree cannot be deleted."
        }
    }
}

package protocol RepositoryWorktreeManagingDataSource: Sendable {
    func loadWorktreeContext() async throws -> RepositoryWorktreeContext
    func createWorktree(_ request: RepositoryCreateWorktreeRequest, output: @escaping GitOutputHandler) async throws -> RepositoryWorktreeResult
    func deleteWorktree(path: String) async throws -> RepositoryWorktreeResult
    func pruneWorktrees() async throws -> RepositoryWorktreeResult
}

package extension RepositoryWorktreeManagingDataSource {
    func createWorktree(_ request: RepositoryCreateWorktreeRequest) async throws -> RepositoryWorktreeResult {
        try await createWorktree(request, output: { _ in })
    }
}

package enum GitWorktreeCommands {
    package static let list = GitCommand(arguments: ["worktree", "list", "--porcelain", "-z"], accessesRemote: false, changesRepositoryState: false)
    package static let prune = GitCommand(arguments: ["worktree", "prune"], accessesRemote: false, changesRepositoryState: true)
    package static func create(relativePath: String, branch: String, newBranch: Bool, defaultRelativePaths: Bool) -> GitCommand {
        GitCommand(
            arguments: (defaultRelativePaths ? ["-c", "worktree.useRelativePaths=true"] : [])
                + ["worktree", "add", relativePath] + (newBranch ? ["-b", branch] : [branch]),
            accessesRemote: false, changesRepositoryState: true
        )
    }
}

package enum RepositoryWorktreePaths {
    package static func destination(basePath: String, branch: String) -> String {
        basePath + "_" + branch.split(whereSeparator: { $0 == "/" || $0 == "\0" }).joined(separator: "_").trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    package static func isEmptyDestination(_ path: String) -> Bool {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !path.contains("\0") else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return true }
        return isDirectory.boolValue && (try? FileManager.default.contentsOfDirectory(atPath: path).isEmpty) == true
    }

    static func relativePath(to destination: URL, from base: URL) -> String {
        let target = destination.standardizedFileURL.pathComponents
        let source = base.standardizedFileURL.pathComponents
        let common = zip(target, source).prefix(while: { $0 == $1 }).count
        let path = (Array(repeating: "..", count: source.count - common) + target.dropFirst(common)).joined(separator: "/")
        return path.isEmpty ? "." : path
    }
}

extension GitRepositoryModule: RepositoryWorktreeManagingDataSource {
    package func loadWorktreeContext() async throws -> RepositoryWorktreeContext {
        guard let repository = resolvedRepository else { throw RepositoryWorktreeError.invalidPath }
        let worktrees = try await git.run(GitWorktreeCommands.list, in: repository.rootURL)
        guard worktrees.succeeded else { throw commandError(from: worktrees) }
        let refs = try await git.run(GitCommand(arguments: ["for-each-ref", "--format=%(refname)", "refs/heads"], accessesRemote: false, changesRepositoryState: false), in: repository.rootURL)
        guard refs.succeeded else { throw commandError(from: refs) }
        let current = try await git.run(GitCommand(arguments: ["branch", "--show-current"], accessesRemote: false, changesRepositoryState: false), in: repository.rootURL)
        guard current.succeeded else { throw commandError(from: current) }
        let branch = current.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        return RepositoryWorktreeContext(
            worktrees: try makeWorktrees(output: worktrees.standardOutput, repository: repository),
            branches: refs.standardOutputString.split(separator: "\n").map { String($0.dropFirst("refs/heads/".count)) },
            currentBranch: branch.isEmpty ? nil : branch, repositoryURL: repository.rootURL
        )
    }

    package func createWorktree(_ request: RepositoryCreateWorktreeRequest, output: @escaping GitOutputHandler) async throws -> RepositoryWorktreeResult {
        let before = try await loadWorktreeContext()
        let destination = URL(fileURLWithPath: (request.path as NSString).expandingTildeInPath, relativeTo: before.repositoryURL).standardizedFileURL
        guard RepositoryWorktreePaths.isEmptyDestination(destination.path) else { throw RepositoryWorktreeError.invalidPath }
        if request.createBranch {
            guard !before.branches.contains(request.branch), try await isValidBranchName(request.branch) else { throw RepositoryWorktreeError.invalidBranch }
        } else {
            guard before.availableBranches.contains(request.branch) else { throw RepositoryWorktreeError.invalidBranch }
        }
        let setting = try await git.run(GitCommand(arguments: ["config", "--get", "worktree.useRelativePaths"], accessesRemote: false, changesRepositoryState: false), in: before.repositoryURL)
        guard setting.succeeded || setting.exitStatus == 1 else { throw commandError(from: setting) }
        let command = GitWorktreeCommands.create(
            relativePath: RepositoryWorktreePaths.relativePath(to: destination, from: before.repositoryURL),
            branch: request.branch, newBranch: request.createBranch,
            defaultRelativePaths: setting.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        do {
            let result = try await git.runStreaming(command, in: before.repositoryURL, output: output)
            let after = try await loadWorktreeContext()
            return RepositoryWorktreeResult(changed: before.worktrees != after.worktrees || before.branches != after.branches,
                                           succeeded: result.succeeded, output: result.standardOutputString + result.standardErrorString)
        } catch {
            let after = try await Task { try await self.loadWorktreeContext() }.value
            let changed = before.worktrees != after.worktrees || before.branches != after.branches
            guard changed else { throw error }
            return RepositoryWorktreeResult(changed: true, succeeded: false, output: error.localizedDescription)
        }
    }

    package func pruneWorktrees() async throws -> RepositoryWorktreeResult {
        let before = try await loadWorktreeContext()
        let result = try await git.run(GitWorktreeCommands.prune, in: before.repositoryURL)
        let after = try await loadWorktreeContext()
        return RepositoryWorktreeResult(changed: before.worktrees != after.worktrees, succeeded: result.succeeded, output: result.standardOutputString + result.standardErrorString)
    }

    package func deleteWorktree(path: String) async throws -> RepositoryWorktreeResult {
        let context = try await loadWorktreeContext()
        guard let worktree = context.worktrees.first(where: { $0.path == path }), worktree.canDelete else {
            throw RepositoryWorktreeError.protectedWorktree
        }
        let target = URL(fileURLWithPath: worktree.path).resolvingSymlinksInPath().standardizedFileURL
        let protected = context.worktrees.filter { $0.isMain || $0.isCurrent }.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }
        guard target.path != "/", target.path != FileManager.default.homeDirectoryForCurrentUser.path,
              !protected.contains(where: { $0 == target.path || $0.hasPrefix(target.path + "/") }),
              (try URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw RepositoryWorktreeError.protectedWorktree }
        let beforePaths = Set(try FileManager.default.subpathsOfDirectory(atPath: target.path))
        do { try FileManager.default.removeItem(at: target) }
        catch {
            let afterPaths = (try? Set(FileManager.default.subpathsOfDirectory(atPath: target.path))) ?? []
            let changed = !FileManager.default.fileExists(atPath: target.path) || beforePaths != afterPaths
            return RepositoryWorktreeResult(changed: changed, succeeded: false, output: error.localizedDescription)
        }
        do {
            let result = try await pruneWorktrees()
            return RepositoryWorktreeResult(changed: true, succeeded: result.succeeded, output: result.output)
        } catch {
            return RepositoryWorktreeResult(changed: true, succeeded: false, output: error.localizedDescription)
        }
    }
}
