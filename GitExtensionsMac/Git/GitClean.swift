import GitExtensionsCore
import Foundation

package enum RepositoryCleanMode: String, CaseIterable, Hashable, Sendable {
    case all
    case onlyNonIgnored
    case onlyIgnored

    package var argument: String? {
        switch self {
        case .all: "-x"
        case .onlyNonIgnored: nil
        case .onlyIgnored: "-X"
        }
    }
}

package struct RepositoryCleanRequest: Hashable, Sendable {
    package let mode: RepositoryCleanMode
    package let removeDirectories: Bool
    package let cleanSubmodules: Bool
    package let includePaths: [String]
    package let excludePaths: [String]

    package init(
        mode: RepositoryCleanMode = .all,
        removeDirectories: Bool = true,
        cleanSubmodules: Bool = false,
        includePaths: [String] = [],
        excludePaths: [String] = []
    ) {
        self.mode = mode
        self.removeDirectories = removeDirectories
        self.cleanSubmodules = cleanSubmodules
        self.includePaths = includePaths
        self.excludePaths = excludePaths
    }
}

package struct RepositoryCleanPreview: Equatable, Sendable {
    package let output: String
    package let hasCandidates: Bool
}

package enum RepositoryCleanOutcome: Equatable, Sendable {
    case noChanges
    case cleaned
    case partiallyCleaned(String)
}

package struct RepositoryCleanResult: Equatable, Sendable {
    package let output: String
    package let outcome: RepositoryCleanOutcome

    package var didChange: Bool {
        switch outcome {
        case .noChanges: false
        case .cleaned, .partiallyCleaned: true
        }
    }
}

package protocol RepositoryCleaningDataSource: RepositoryBrowsingDataSource {
    func previewClean(_ request: RepositoryCleanRequest) async throws -> RepositoryCleanPreview
    func clean(_ request: RepositoryCleanRequest) async throws -> RepositoryCleanResult
}

package enum GitCleanCommands {
    package static func clean(_ request: RepositoryCleanRequest, dryRun: Bool) -> GitCommand {
        var arguments = ["clean"]
        if let mode = request.mode.argument { arguments.append(mode) }
        if request.removeDirectories { arguments.append("-d") }
        arguments.append(dryRun ? "--dry-run" : "-f")
        arguments.append(contentsOf: normalizedLines(request.includePaths))
        arguments.append(contentsOf: normalizedLines(request.excludePaths).map {
            "--exclude=\($0.replacingOccurrences(of: " ", with: "?").replacingOccurrences(of: "\\", with: "/"))"
        })
        return GitCommand(
            arguments: arguments,
            accessesRemote: false,
            changesRepositoryState: !dryRun
        )
    }

    package static func cleanSubmodules(_ request: RepositoryCleanRequest, dryRun: Bool) -> GitCommand {
        var arguments = ["submodule", "foreach", "--recursive", "git", "clean"]
        if let mode = request.mode.argument { arguments.append(mode) }
        if request.removeDirectories { arguments.append("-d") }
        arguments.append(dryRun ? "--dry-run" : "-f")
        arguments.append(contentsOf: normalizedLines(request.includePaths))
        return GitCommand(
            arguments: arguments,
            accessesRemote: false,
            changesRepositoryState: !dryRun
        )
    }

    private static func normalizedLines(_ values: [String]) -> [String] {
        values.filter { !$0.isEmpty }
    }
}

extension GitRepositoryModule: RepositoryCleaningDataSource {
    package func previewClean(_ request: RepositoryCleanRequest) async throws -> RepositoryCleanPreview {
        let repository = try mutationRepository()
        let output = try await cleanOutput(request, dryRun: true, in: repository)
        return RepositoryCleanPreview(output: output, hasCandidates: !cleanCandidates(in: output).isEmpty)
    }

    package func clean(_ request: RepositoryCleanRequest) async throws -> RepositoryCleanResult {
        let repository = try mutationRepository()
        let before = try await cleanOutput(request, dryRun: true, in: repository)
        let beforeCandidates = cleanCandidates(in: before)
        guard !beforeCandidates.isEmpty else {
            return RepositoryCleanResult(output: before, outcome: .noChanges)
        }

        do {
            let output = try await cleanOutput(request, dryRun: false, in: repository)
            return RepositoryCleanResult(output: output, outcome: .cleaned)
        } catch {
            let after = (try? await cleanOutput(request, dryRun: true, in: repository)) ?? before
            if cleanCandidates(in: after) != beforeCandidates {
                return RepositoryCleanResult(
                    output: after,
                    outcome: .partiallyCleaned(error.localizedDescription)
                )
            }
            throw error
        }
    }

    private func cleanOutput(
        _ request: RepositoryCleanRequest,
        dryRun: Bool,
        in repository: ResolvedGitRepository
    ) async throws -> String {
        var output = ""
        let main = try await git.run(GitCleanCommands.clean(request, dryRun: dryRun), in: repository.rootURL)
        guard main.succeeded else { throw commandError(from: main) }
        output += main.standardOutputString

        if request.cleanSubmodules {
            let submodules = try await git.run(
                GitCleanCommands.cleanSubmodules(request, dryRun: dryRun),
                in: repository.rootURL
            )
            guard submodules.succeeded else { throw commandError(from: submodules) }
            output += submodules.standardOutputString
        }
        return output
    }

    private func cleanCandidates(in output: String) -> [String] {
        output.components(separatedBy: .newlines).filter { $0.contains("Would remove ") }
    }
}
