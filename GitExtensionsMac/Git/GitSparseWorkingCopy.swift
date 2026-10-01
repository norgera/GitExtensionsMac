import Foundation
import GitExtensionsCore



package protocol RepositorySparseWorkingCopyDataSource: Sendable {

    func isSparseCheckoutEnabled() async throws -> Bool

    func sparseCheckoutFileURL() async throws -> URL

    func setSparseCheckoutEnabled(_ enabled: Bool) async throws

    func refreshSparseWorkingCopy(output: @escaping GitOutputHandler) async throws -> GitCommandResult
}

package enum SparseWorkingCopyCommands {
    package static let settingName = "core.sparsecheckout"

    package static let refreshCommandLine = "read-tree -m -u HEAD"
    package static let refresh = GitCommand(arguments: ["read-tree", "-m", "-u", "HEAD"], accessesRemote: false, changesRepositoryState: true)
    package static let readSetting = GitCommand(arguments: ["config", "--get", settingName], accessesRemote: false, changesRepositoryState: false)
    package static let filePath = GitCommand(arguments: ["rev-parse", "--git-path", "info/sparse-checkout"], accessesRemote: false, changesRepositoryState: false)
    package static func writeSetting(_ enabled: Bool) -> GitCommand {
        GitCommand(arguments: ["config", "--local", settingName, enabled ? "true" : "false"], accessesRemote: false, changesRepositoryState: true)
    }


    package static func isEnabled(_ value: String) -> Bool {
        value.trimmingCharacters(in: .newlines).caseInsensitiveCompare("true") == .orderedSame
    }
}


package enum SparseWorkingCopyRules {

    package static func activeRules(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }



    package static func adjustmentNeeded(_ text: String) -> Adjustment? {
        let rules = activeRules(text)
        if rules.allSatisfy({ $0 == "/*" }) { return nil }
        return Adjustment(isCurrentRuleSetEmpty: rules.isEmpty)
    }


    package struct Adjustment: Equatable {
        package let isCurrentRuleSetEmpty: Bool
    }



    package static func adjustedForDisabling(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).map { line -> String in
            line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || line.hasPrefix("#") ? line : "#" + line
        }
        return (["/*"] + lines).joined(separator: "\n")
    }
}

extension GitRepositoryModule: RepositorySparseWorkingCopyDataSource {
    package func isSparseCheckoutEnabled() async throws -> Bool {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        let result = try await git.run(SparseWorkingCopyCommands.readSetting, in: repository.rootURL)

        guard result.succeeded || result.exitStatus == 1 else {
            throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString)
        }
        return SparseWorkingCopyCommands.isEnabled(result.standardOutputString)
    }

    package func sparseCheckoutFileURL() async throws -> URL {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        let result = try await git.run(SparseWorkingCopyCommands.filePath, in: repository.rootURL)
        guard result.succeeded else {
            throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString)
        }
        return RepositoryFileEditorCommands.resolveGitPath(result.standardOutputString, in: repository.rootURL)
    }

    package func setSparseCheckoutEnabled(_ enabled: Bool) async throws {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        let result = try await git.run(SparseWorkingCopyCommands.writeSetting(enabled), in: repository.rootURL)
        guard result.succeeded else {
            throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString)
        }
    }

    package func refreshSparseWorkingCopy(output: @escaping GitOutputHandler) async throws -> GitCommandResult {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        return try await git.runStreaming(SparseWorkingCopyCommands.refresh, in: repository.rootURL, output: output)
    }
}
