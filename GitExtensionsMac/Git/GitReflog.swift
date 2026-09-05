import GitExtensionsCore
import Foundation

package struct RepositoryReflogSelector: Hashable, Sendable, CustomStringConvertible {
    package let reference: String
    package let index: Int
    package let rawValue: String

    package init(reference: String, index: Int) {
        self.reference = reference
        self.index = index
        rawValue = "\(reference)@{\(index)}"
    }

    package init?(rawValue: String) {
        guard rawValue.hasSuffix("}"),
              let marker = rawValue.range(of: "@{", options: .backwards),
              marker.lowerBound != rawValue.startIndex,
              let index = Int(rawValue[marker.upperBound..<rawValue.index(before: rawValue.endIndex)]),
              index >= 0 else { return nil }
        reference = String(rawValue[..<marker.lowerBound])
        self.index = index
        self.rawValue = rawValue
    }

    package var description: String { rawValue }
}

package struct RepositoryReflogEntry: Hashable, Sendable, Identifiable {
    package let objectID: ObjectID
    package let selector: RepositoryReflogSelector
    package let action: String

    package init(objectID: ObjectID, selector: RepositoryReflogSelector, action: String) {
        self.objectID = objectID
        self.selector = selector
        self.action = action
    }

    package var id: String { "\(selector.rawValue)\u{0}\(objectID.string)" }
}

package struct RepositoryReflogContext: Equatable, Sendable {
    package let references: [String]
    package let currentBranch: String?
    package let isDirty: Bool
    package let isBare: Bool

    package init(references: [String], currentBranch: String?, isDirty: Bool, isBare: Bool) {
        self.references = references
        self.currentBranch = currentBranch
        self.isDirty = isDirty
        self.isBare = isBare
    }
}

package enum RepositoryReflogError: LocalizedError, Equatable, Sendable {
    case unavailable
    case invalidReference(String)

    package var errorDescription: String? {
        switch self {
        case .unavailable:
            "Reflog is unavailable until the repository has been opened."
        case .invalidReference(let reference):
            "‘\(reference)’ is not an available reflog reference."
        }
    }
}

package protocol RepositoryReflogDataSource: RepositoryBrowsingDataSource {
    func loadReflogContext() async throws -> RepositoryReflogContext
    func loadReflog(reference: String) async throws -> [RepositoryReflogEntry]
    func loadReflogRevision(_ objectID: ObjectID) async throws -> Commit
}

package enum GitReflogCommands {
    package static let currentBranch = GitCommand(
        arguments: ["branch", "--show-current"],
        accessesRemote: false,
        changesRepositoryState: false
    )

    package static let references = GitCommand(
        arguments: [
            "for-each-ref", "--format=%(refname)%00%(symref)%00", "refs/heads", "refs/remotes"
        ],
        accessesRemote: false,
        changesRepositoryState: false
    )

    package static let status = GitCommand(
        arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=normal"],
        accessesRemote: false,
        changesRepositoryState: false
    )

    package static func entries(reference: String) -> GitCommand {
        GitCommand(
            arguments: ["reflog", "--no-abbrev", reference],
            accessesRemote: false,
            changesRepositoryState: false
        )
    }

    package static func revision(_ objectID: ObjectID) -> GitCommand {
        GitCommand(
            arguments: [
                "log", "-z", "-1",
                "--format=%H%x00%P%x00%at%x00%ct%x00%aN%x00%aE%x00%cN%x00%cE%x00%B",
                objectID.string
            ],
            accessesRemote: false,
            changesRepositoryState: false
        )
    }
}

package enum GitReflogParser {
    package static func parse(_ output: String) -> [RepositoryReflogEntry] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { rawLine in
            let line = String(rawLine)
            guard let space = line.firstIndex(of: " ") else { return nil }
            let objectText = String(line[..<space])
            let remainder = line[line.index(after: space)...]
            guard let separator = remainder.range(of: ": "),
                  let objectID = try? ObjectID.parse(objectText),
                  let selector = RepositoryReflogSelector(rawValue: String(remainder[..<separator.lowerBound]))
            else { return nil }
            return RepositoryReflogEntry(
                objectID: objectID,
                selector: selector,
                action: String(remainder[separator.upperBound...])
            )
        }
    }
}

extension GitRepositoryModule: RepositoryReflogDataSource {
    package func loadReflogContext() async throws -> RepositoryReflogContext {
        guard let repository = resolvedRepository else { throw RepositoryReflogError.unavailable }

        async let branchResult = git.run(GitReflogCommands.currentBranch, in: repository.rootURL)
        async let refsResult = git.run(GitReflogCommands.references, in: repository.rootURL)
        async let statusResult: GitCommandResult? = repository.isBare
            ? nil
            : git.run(GitReflogCommands.status, in: repository.rootURL)

        let branch = try await branchResult
        let refs = try await refsResult
        let status = try await statusResult
        guard branch.succeeded else { throw commandError(from: branch) }
        guard refs.succeeded else { throw commandError(from: refs) }
        if let status, !status.succeeded { throw commandError(from: status) }

        let current = branch.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        var local: [String] = []
        var remote: [String] = []
        for record in refs.standardOutput.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            let fields = record.split(separator: 0, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            guard fields.count >= 2 else { continue }
            let fullName = fields[0]
            let symbolicTarget = fields[1]
            guard symbolicTarget.isEmpty else { continue }
            if fullName.hasPrefix("refs/heads/") {
                local.append(String(fullName.dropFirst("refs/heads/".count)))
            } else if fullName.hasPrefix("refs/remotes/") {
                remote.append(String(fullName.dropFirst("refs/remotes/".count)))
            }
        }

        return RepositoryReflogContext(
            references: ["HEAD"] + local.sorted() + remote.sorted(),
            currentBranch: current.isEmpty ? nil : current,
            isDirty: !(status?.standardOutput.isEmpty ?? true),
            isBare: repository.isBare
        )
    }

    package func loadReflog(reference: String) async throws -> [RepositoryReflogEntry] {
        guard let repository = resolvedRepository else { throw RepositoryReflogError.unavailable }
        let context = try await loadReflogContext()
        guard context.references.contains(reference) else {
            throw RepositoryReflogError.invalidReference(reference)
        }
        let result = try await git.run(GitReflogCommands.entries(reference: reference), in: repository.rootURL)
        guard result.succeeded else { throw commandError(from: result) }
        return GitReflogParser.parse(result.standardOutputString)
    }

    package func loadReflogRevision(_ objectID: ObjectID) async throws -> Commit {
        guard let repository = resolvedRepository else { throw RepositoryReflogError.unavailable }
        let result = try await git.run(GitReflogCommands.revision(objectID), in: repository.rootURL)
        guard result.succeeded else { throw commandError(from: result) }
        guard let record = try GitOutputParser.parseLog(result.standardOutput).first,
              record.objectID == objectID else {
            throw RepositoryReflogError.invalidReference(objectID.string)
        }
        return RevisionCommitBuilder.revision(record, references: [])
    }
}
