import Foundation

protocol RepositoryBrowsingDataSource: Sendable {
    func loadSnapshot() async throws -> RepositorySnapshot
    func loadRevisionDetails(for commit: Commit) async throws -> RepositoryRevisionDetails
    func loadRepositoryFiles(for commit: Commit) async throws -> [RepositoryFileEntry]
    func loadDiff(for commit: Commit, file: ChangedFile) async throws -> FileDiff?
    func loadFileContent(for commit: Commit, file: RepositoryFileEntry) async throws -> RepositoryFileEntry
}

protocol RepositoryOpeningDataSource: RepositoryBrowsingDataSource {
    func openRepository(at url: URL) async throws -> RepositorySnapshot
}

enum RepositoryDataSourceError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Repository data is currently unavailable."
    }
}
