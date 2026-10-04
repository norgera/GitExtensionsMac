import Foundation
import GitExtensionsCore

package protocol RepositorySignatureDataSource: Sendable {
    func loadSignatureInfo(for commit: Commit) async throws -> RevisionGPGInfo?
}

package enum GitSignatureParser {
    package static func commitStatus(_ output: String) -> CommitSignatureStatus {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "G": .goodSignature
        case "B", "U", "X", "Y", "R": .signatureError
        case "E": .missingPublicKey
        default: .noSignature
        }
    }

    package static func tagStatus(rawMessage: String) -> TagSignatureStatus {
        if rawMessage.contains("GOODSIG"), rawMessage.contains("VALIDSIG") { return .oneGood }
        if rawMessage.contains("error: no signature found") { return .tagNotSigned }
        if rawMessage.contains("NO_PUBKEY") { return .missingPublicKey }
        return .oneBad
    }

    package static func verifiableTags(of commit: Commit) -> [String] {
        commit.references.filter { $0.kind == .tag && $0.isAnnotated }.map(\.name)
    }
}

extension GitRepositoryModule: RepositorySignatureDataSource {
    package func loadSignatureInfo(for commit: Commit) async throws -> RevisionGPGInfo? {
        guard !commit.isArtificial, let objectID = commit.objectID else { return nil }
        guard let root = resolvedRepository?.rootURL else { throw RepositoryDataSourceError.unavailable }
        let git = self.git
        let tags = GitSignatureParser.verifiableTags(of: commit)

        @Sendable func output(_ arguments: [String], standardError: Bool = false) async throws -> String {
            try Task.checkCancellation()
            let result = try await git.run(GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: false), in: root)
            return String(decoding: standardError ? result.standardError : result.standardOutput, as: UTF8.self)
        }

        async let commitCode = output(["log", "--pretty=format:%G?", "-1", objectID.string])
        async let tagStatus: TagSignatureStatus = {
            switch tags.count {
            case 0: return .noTag
            case 1: return GitSignatureParser.tagStatus(rawMessage: try await output(["verify-tag", "--raw", tags[0]], standardError: true))
            default: return .many
            }
        }()
        let commitStatus = GitSignatureParser.commitStatus(try await commitCode)
        let resolvedTagStatus = try await tagStatus
        try Task.checkCancellation()
        if commitStatus == .noSignature && resolvedTagStatus == .noTag { return nil }

        let commitMessage = try await output(["log", "--pretty=format:%GG", "-1", objectID.string])
        let tagMessage: String
        switch tags.count {
        case 0:
            tagMessage = ""
        case 1:
            tagMessage = try await output(["verify-tag", tags[0]], standardError: true)
        default:
            var combined = ""
            for tag in tags {
                combined += "\(tag)\n\(try await output(["verify-tag", tag], standardError: true))\n\n"
            }
            tagMessage = combined
        }
        try Task.checkCancellation()
        return RevisionGPGInfo(commitStatus: commitStatus, commitVerificationMessage: commitMessage,
                               tagStatus: resolvedTagStatus, tagVerificationMessage: tagMessage)
    }
}
