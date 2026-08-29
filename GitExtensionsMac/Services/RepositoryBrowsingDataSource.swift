import GitExtensionsCore
import Foundation

package struct RepositoryLoadState: Sendable {
    package let identity: RepositoryIdentityState
    package let references: RepositoryReferenceState
    package let navigation: RepositoryNavigationState
    package let status: RepositoryStatusSummary
    package let revisionReadRequest: RevisionReadRequest

    package init(
        identity: RepositoryIdentityState,
        references: RepositoryReferenceState,
        navigation: RepositoryNavigationState,
        status: RepositoryStatusSummary,
        revisionReadRequest: RevisionReadRequest
    ) {
        self.identity = identity
        self.references = references
        self.navigation = navigation
        self.status = status
        self.revisionReadRequest = revisionReadRequest
    }
}

package extension RepositoryLoadState {
    var networkContext: RepositoryNetworkContext {
        RepositoryNetworkContext(
            repository: identity.currentRepository,
            headID: identity.headID,
            branches: references.branches,
            remotes: navigation.remotes,
            references: references.references,
            submodules: navigation.submodules
        )
    }

    var branchContext: RepositoryBranchContext {
        RepositoryBranchContext(
            repository: identity.currentRepository,
            headID: identity.headID,
            branches: references.branches,
            remotes: navigation.remotes,
            referencesByCommit: references.referencesByCommit,
            submodules: navigation.submodules
        )
    }

    var mergeContext: RepositoryMergeContext {
        RepositoryMergeContext(
            repository: identity.currentRepository,
            branches: references.branches,
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
    func loadDiff(for commit: Commit, file: ChangedFile) async throws -> FileDiff?
    func loadFileContent(for commit: Commit, file: RepositoryFileEntry) async throws -> RepositoryFileEntry
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
