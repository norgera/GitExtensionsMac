import Foundation

package protocol RepositoryPluginDataSource: Sendable {
    func executePluginCommand(_ command: GitCommand, standardInput: Data?) async throws -> GitCommandResult
}

extension GitRepositoryModule: RepositoryPluginDataSource {
    package func executePluginCommand(_ command: GitCommand, standardInput: Data?) async throws -> GitCommandResult {
        guard let repository = resolvedRepository else {
            throw NSError(domain: "GitExtensionsMac.Plugins", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The repository has not finished opening."])
        }
        return try await git.run(command, in: repository.rootURL, standardInput: standardInput)
    }
}
