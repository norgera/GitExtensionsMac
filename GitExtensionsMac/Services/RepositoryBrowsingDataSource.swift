import GitExtensionsCore
import Foundation

package struct RepositoryLoadState: Sendable {
    package let identity: RepositoryIdentityState
    package let references: RepositoryReferenceState
    package let navigation: RepositoryNavigationState
    package let status: RepositoryStatusSummary
    package let revisionReadRequest: RevisionReadRequest
    package let aheadBehind: [String: AheadBehindData]
    package let monitoringURLs: [URL]

    package init(
        identity: RepositoryIdentityState,
        references: RepositoryReferenceState,
        navigation: RepositoryNavigationState,
        status: RepositoryStatusSummary,
        revisionReadRequest: RevisionReadRequest,
        aheadBehind: [String: AheadBehindData] = [:], monitoringURLs: [URL] = []
    ) {
        self.identity = identity
        self.references = references
        self.navigation = navigation
        self.status = status
        self.revisionReadRequest = revisionReadRequest
        self.aheadBehind = aheadBehind
        self.monitoringURLs = monitoringURLs
    }
}

package extension RepositoryLoadState {
    var networkContext: RepositoryNetworkContext {
        RepositoryNetworkContext(
            repository: identity.currentRepository,
            headID: identity.headID,
            branches: references.branches,
            remotes: navigation.remotes.filter { !$0.isDisabled },
            references: references.references,
            submodules: navigation.submodules
        )
    }

    var branchContext: RepositoryBranchContext {
        RepositoryBranchContext(
            repository: identity.currentRepository,
            headID: identity.headID,
            branches: references.branches,
            remotes: navigation.remotes.filter { !$0.isDisabled },
            referencesByCommit: references.referencesByCommit,
            submodules: navigation.submodules
        )
    }

    var mergeContext: RepositoryMergeContext {
        RepositoryMergeContext(
            repository: identity.currentRepository,
            branches: references.branches + navigation.remotes.flatMap(\.branches),
            tags: references.tags,
            referencesByCommit: references.referencesByCommit,
            submodules: navigation.submodules
        )
    }

    var commitContext: RepositoryCommitContext {
        RepositoryCommitContext(
            repository: identity.currentRepository,
            headID: identity.headID,
            branches: references.branches,
            submodules: navigation.submodules
        )
    }

    var stashContext: RepositoryStashContext {
        RepositoryStashContext(headID: identity.headID, stashes: navigation.stashes)
    }

    var rebaseContext: RepositoryRebaseContext {
        RepositoryRebaseContext(branches: references.branches, tags: references.tags)
    }
}

package protocol RepositoryBrowsingDataSource: Sendable {
    func loadRepositoryState() async throws -> RepositoryLoadState
    func revisionReadRequest() async throws -> RevisionReadRequest
    func loadRevisionDetails(for commit: Commit) async throws -> RepositoryRevisionDetails
    func loadRepositoryFiles(for commit: Commit) async throws -> [RepositoryFileEntry]
    func loadDiff(for commit: Commit, file: ChangedFile, options: FileDiffOptions) async throws -> FileDiff?
    func prepareDiff(for commit: Commit, file: ChangedFile, options: FileDiffOptions) async throws -> FilePreview<FileDiff?>
    func loadFileContent(for commit: Commit, file: RepositoryFileEntry) async throws -> RepositoryFileEntry
    func loadFilePresentation(
        for commit: Commit,
        file: RepositoryFileEntry,
        encoding: RepositoryTextEncoding
    ) async throws -> RepositoryFileContent
    func prepareFilePresentation(for commit: Commit, file: RepositoryFileEntry, encoding: RepositoryTextEncoding) async throws -> FilePreview<RepositoryFileContent>
    func openWithDifftool(for commit: Commit, file: ChangedFile, customToolPath: String?) async throws
    func isDifftasticEnabled() async -> Bool
}

package extension RepositoryBrowsingDataSource {
    func isDifftasticEnabled() async -> Bool { false }

    func prepareFilePresentation(for commit: Commit, file: RepositoryFileEntry, encoding: RepositoryTextEncoding) async throws -> FilePreview<RepositoryFileContent> {
        .ready(try await loadFilePresentation(for: commit, file: file, encoding: encoding))
    }

    func prepareDiff(for commit: Commit, file: ChangedFile, options: FileDiffOptions) async throws -> FilePreview<FileDiff?> {
        .ready(try await loadDiff(for: commit, file: file, options: options))
    }

    func loadDiff(for commit: Commit, file: ChangedFile) async throws -> FileDiff? {
        try await loadDiff(for: commit, file: file, options: FileDiffOptions())
    }

    func openWithDifftool(for commit: Commit, file: ChangedFile) async throws {
        try await openWithDifftool(for: commit, file: file, customToolPath: nil)
    }
}

package protocol RepositoryOpeningDataSource: RepositoryBrowsingDataSource {
    func openRepository(at url: URL) async throws -> RepositoryLoadState
}

package enum RepositoryDataSourceError: LocalizedError {
    case unavailable

    package var errorDescription: String? {
        "Repository data is currently unavailable."
    }
}
