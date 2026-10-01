import Foundation
import GitExtensionsCore

package enum RevisionComparisonError: LocalizedError {
    case invalidTarget(String), noCurrentBranch, noBase
    package var errorDescription: String? {
        switch self {
        case .invalidTarget(let expression): "The revision '\(expression)' cannot be resolved for comparison."
        case .noCurrentBranch: "No branch is currently selected."
        case .noBase: "Select a revision as BASE before comparing to BASE."
        }
    }
}


package struct RevisionComparisonReadRequest: Sendable {
    package let context: RevisionReadContext
    package let reader: RevisionReader
    package let identity: RepositoryIdentityState
    package let references: RepositoryReferenceState
    package let branches: [Branch]
    package var remoteBranchNames: [String] { branches.filter(\.isRemote).map(Self.branchName) }
    package static func branchName(_ branch: Branch) -> String {
        branch.isRemote ? [branch.remoteName, branch.name].compactMap { $0 }.joined(separator: "/") : branch.name
    }
}

package protocol RepositoryRevisionComparingDataSource: Sendable {
    func comparisonReadRequest() async throws -> RevisionComparisonReadRequest
    func comparisonRevision(_ id: RevisionID, headID: ObjectID?) async throws -> Commit
    func comparisonTarget(_ expression: String) async throws -> Commit
    func comparisonMergeBase(first: RevisionID, second: RevisionID, headID: ObjectID?) async throws -> ObjectID?
    func comparisonCount(from: RevisionID, to expression: String, headID: ObjectID?) async throws -> String
}


package enum RevisionComparison {
    package static func firstID(in selected: [Commit]) -> RevisionID? {
        guard let latest = selected.first else { return nil }
        return selected.count > 1 ? selected.last?.id : latest.graphParentIDs.first
    }
}

extension GitRepositoryModule: RepositoryRevisionComparingDataSource {
    package func comparisonReadRequest() async throws -> RevisionComparisonReadRequest {
        let state = try await loadRepositoryState()
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        return .init(context: state.revisionReadRequest.context,
                     reader: RevisionReader(git: git, directory: repository.rootURL),
                     identity: state.identity, references: state.references,
                     branches: state.references.branches + state.navigation.remotes.flatMap(\.branches))
    }

    package func comparisonRevision(_ id: RevisionID, headID: ObjectID?) async throws -> Commit {
        if let object = id.objectID { return try await loadReflogRevision(object) }
        guard let revision = RevisionCommitBuilder.artificialRevisions(headID: headID).first(where: { $0.id == id }) else {
            throw RepositoryDataSourceError.unavailable
        }
        return revision
    }

    package func comparisonTarget(_ expression: String) async throws -> Commit {
        guard let id = await resolveRevision(expression) else { throw RevisionComparisonError.invalidTarget(expression) }
        return try await comparisonRevision(.object(id), headID: nil)
    }

    package func comparisonMergeBase(first: RevisionID, second: RevisionID, headID: ObjectID?) async throws -> ObjectID? {
        guard let a = first.objectID ?? headID, let b = second.objectID ?? headID, a != b,
              let repository = resolvedRepository else { return nil }
        let result = try await git.run(FileStatusCommands.mergeBase(a, b), in: repository.rootURL)
        if result.exitStatus == 1 { return nil }
        guard result.succeeded else {
            throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString)
        }
        return try? ObjectID.parse(result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    package func comparisonCount(from: RevisionID, to expression: String, headID: ObjectID?) async throws -> String {
        guard let a = from.objectID ?? headID, !expression.isEmpty, !expression.hasPrefix("-"),
              let repository = resolvedRepository else { return "" }
        let result = try await git.run(FileStatusCommands.rangeCount(from.objectID == nil ? "HEAD" : a.string, expression), in: repository.rootURL)
        let counts = FileStatusCommands.parseRangeCount(result.standardOutputString)
        guard result.succeeded, let a = counts.0, let b = counts.1 else { return "" }
        return a == 0 && b == 0 ? "=" : "(+\(a)-\(b))"
    }
}
