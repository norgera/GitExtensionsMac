import Foundation

package enum RepositoryCloneBranch: Sendable, Equatable {
    case remoteHEAD
    case noCheckout
    case named(String)
}

package struct RepositoryCloneRequest: Sendable, Equatable {
    package let source: String
    package let destinationParent: URL
    package let subdirectory: String
    package let isBare: Bool
    package let initializesSubmodules: Bool
    package let downloadsFullHistory: Bool
    package let branch: RepositoryCloneBranch

    package init(
        source: String,
        destinationParent: URL,
        subdirectory: String,
        isBare: Bool = false,
        initializesSubmodules: Bool = true,
        downloadsFullHistory: Bool = true,
        branch: RepositoryCloneBranch = .remoteHEAD
    ) {
        self.source = source
        self.destinationParent = destinationParent
        self.subdirectory = subdirectory
        self.isBare = isBare
        self.initializesSubmodules = initializesSubmodules
        self.downloadsFullHistory = downloadsFullHistory
        self.branch = branch
    }

    package var destinationURL: URL {
        destinationParent.appendingPathComponent(subdirectory, isDirectory: true).standardizedFileURL
    }
}

package struct RepositoryInitRequest: Sendable, Equatable {
    package let directory: URL
    package let isBare: Bool

    package init(directory: URL, isBare: Bool = false) {
        self.directory = directory
        self.isBare = isBare
    }
}

package struct RepositoryCreationResult: Sendable {
    package let repositoryURL: URL
    package let command: GitCommandResult
    package let isBare: Bool
}

package enum RepositoryCreationError: LocalizedError, Sendable, Equatable {
    case emptySource
    case invalidDestination(String)
    case invalidSubdirectory(String)
    case destinationIsFile(String)

    package var errorDescription: String? {
        switch self {
        case .emptySource:
            "Enter a repository URL or path to clone."
        case .invalidDestination(let path):
            "The destination must be an absolute directory path: \(path)"
        case .invalidSubdirectory(let value):
            "Enter a valid subdirectory name: \(value)"
        case .destinationIsFile(let path):
            "The destination is an existing file: \(path)"
        }
    }
}

package protocol RepositoryCreating: Sendable {
    func suggestedCloneSubdirectory(for source: String) -> String
    func remoteBranches(at source: String) async throws -> [String]
    func clone(
        _ request: RepositoryCloneRequest,
        output: @escaping GitOutputHandler
    ) async throws -> RepositoryCreationResult
    func initialize(
        _ request: RepositoryInitRequest,
        output: @escaping GitOutputHandler
    ) async throws -> RepositoryCreationResult
}

package enum GitRepositoryCreationCommands {
    package static func clone(
        source: String,
        destination: URL,
        isBare: Bool,
        initializesSubmodules: Bool,
        downloadsFullHistory: Bool,
        branch: RepositoryCloneBranch
    ) -> GitCommand {
        var arguments = ["clone", "-v"]
        if isBare { arguments.append("--bare") }
        if initializesSubmodules { arguments.append("--recurse-submodules") }
        if !downloadsFullHistory {
            arguments.append(contentsOf: ["--depth", "1", "--no-single-branch"])
        }
        arguments.append("--progress")
        switch branch {
        case .remoteHEAD:
            break
        case .noCheckout:
            arguments.append("--no-checkout")
        case .named(let branch):
            let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            if !branch.isEmpty { arguments.append(contentsOf: ["--branch", branch]) }
        }
        arguments.append(contentsOf: [source, destination.path])
        return GitCommand(
            arguments: arguments,
            accessesRemote: sourceAccessesRemote(source),
            changesRepositoryState: true
        )
    }

    package static func initialize(isBare: Bool) -> GitCommand {
        GitCommand(
            arguments: isBare ? ["init", "--bare", "--shared=all"] : ["init"],
            accessesRemote: false,
            changesRepositoryState: true
        )
    }

    private static func sourceAccessesRemote(_ source: String) -> Bool {
        let lowercased = source.lowercased()
        if lowercased.hasPrefix("file://") || source.hasPrefix("/") || source.hasPrefix("~") {
            return false
        }
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("ssh://") || lowercased.hasPrefix("git://") {
            return true
        }
        if let colon = source.firstIndex(of: ":"), !source[..<colon].contains("/") {
            return true
        }
        return false
    }
}

package final class GitRepositoryCreator: RepositoryCreating, @unchecked Sendable {
    private let git: any GitCommandRunning
    private let executionDirectory: URL
    private let environment: [String: String]

    package init(
        git: any GitCommandRunning,
        executionDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        environment: [String: String] = [:]
    ) {
        self.git = git
        self.executionDirectory = executionDirectory
        self.environment = environment
    }

    package func suggestedCloneSubdirectory(for source: String) -> String {
        var value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        while value.last == "/" || value.last == "\\" { value.removeLast() }
        guard !value.isEmpty else { return "" }
        if let colon = value.lastIndex(of: ":"),
           !value[value.index(after: colon)...].contains("/"),
           !value[value.index(after: colon)...].contains("\\") {
            value = String(value[value.index(after: colon)...])
        } else {
            value = URL(fileURLWithPath: value).lastPathComponent
        }
        if value.lowercased().hasSuffix(".git") { value.removeLast(4) }
        return value
    }

    package func remoteBranches(at source: String) async throws -> [String] {
        let source = normalizedSource(source)
        guard !source.isEmpty else { throw RepositoryCreationError.emptySource }
        let command = GitCommand(
            arguments: ["ls-remote", "--heads", source],
            accessesRemote: true,
            changesRepositoryState: false
        )
        let result = try await git.run(command, in: executionDirectory, environment: environment)
        try requireSuccess(result)
        return result.standardOutputString
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard fields.count == 2 else { return nil }
                let ref = String(fields[1])
                guard ref.hasPrefix("refs/heads/") else { return nil }
                return String(ref.dropFirst("refs/heads/".count))
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    package func clone(
        _ request: RepositoryCloneRequest,
        output: @escaping GitOutputHandler
    ) async throws -> RepositoryCreationResult {
        let source = normalizedSource(request.source)
        guard !source.isEmpty else { throw RepositoryCreationError.emptySource }
        let parent = request.destinationParent.standardizedFileURL
        guard parent.path.hasPrefix("/") else {
            throw RepositoryCreationError.invalidDestination(parent.path)
        }
        let subdirectory = request.subdirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subdirectory.isEmpty,
              subdirectory != ".",
              subdirectory != "..",
              !subdirectory.contains("/"),
              !subdirectory.contains("\\") else {
            throw RepositoryCreationError.invalidSubdirectory(request.subdirectory)
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw RepositoryCreationError.destinationIsFile(parent.path) }
        } else {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let destination = parent.appendingPathComponent(subdirectory, isDirectory: true).standardizedFileURL
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw RepositoryCreationError.destinationIsFile(destination.path)
        }

        let command = GitRepositoryCreationCommands.clone(
            source: source,
            destination: destination,
            isBare: request.isBare,
            initializesSubmodules: request.initializesSubmodules,
            downloadsFullHistory: request.downloadsFullHistory,
            branch: request.branch
        )
        let result = try await git.runStreaming(command, in: parent, environment: environment, output: output)
        try requireSuccess(result)
        return RepositoryCreationResult(repositoryURL: destination, command: result, isBare: request.isBare)
    }

    package func initialize(
        _ request: RepositoryInitRequest,
        output: @escaping GitOutputHandler
    ) async throws -> RepositoryCreationResult {
        let directory = request.directory.standardizedFileURL
        guard directory.path.hasPrefix("/") else {
            throw RepositoryCreationError.invalidDestination(directory.path)
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw RepositoryCreationError.destinationIsFile(directory.path) }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let command = GitRepositoryCreationCommands.initialize(isBare: request.isBare)
        let result = try await git.runStreaming(command, in: directory, environment: environment, output: output)
        try requireSuccess(result)
        return RepositoryCreationResult(repositoryURL: directory, command: result, isBare: request.isBare)
    }

    private func normalizedSource(_ source: String) -> String {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.hasPrefix("~") else { return source }
        return NSString(string: source).expandingTildeInPath
    }

    private func requireSuccess(_ result: GitCommandResult) throws {
        guard !result.succeeded else { return }
        throw GitError.commandFailed(
            arguments: result.arguments,
            status: result.exitStatus,
            stderr: result.standardErrorString
        )
    }
}
