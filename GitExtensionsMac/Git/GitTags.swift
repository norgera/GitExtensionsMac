import GitExtensionsCore
import Foundation

package enum RepositoryTagOperation: Int, CaseIterable, Sendable {
    case lightweight
    case annotated
    case signWithDefaultKey
    case signWithSpecificKey

    package var providesMessage: Bool { self != .lightweight }
}

package struct RepositoryCreateTagRequest: Sendable, Equatable {
    package let name: String
    package let target: ObjectID
    package let operation: RepositoryTagOperation
    package let message: String
    package let signingKey: String
    package let force: Bool

    package init(
        name: String,
        target: ObjectID,
        operation: RepositoryTagOperation = .lightweight,
        message: String = "",
        signingKey: String = "",
        force: Bool = false
    ) {
        self.name = name
        self.target = target
        self.operation = operation
        self.message = message
        self.signingKey = signingKey
        self.force = force
    }
}

package struct RepositoryTagMutationResult: Sendable, Equatable {
    package let selectedCommitID: RevisionID?
    package let message: String

    package init(selectedCommitID: RevisionID?, message: String) {
        self.selectedCommitID = selectedCommitID
        self.message = message
    }
}

package enum RepositoryTagError: LocalizedError, Sendable, Equatable {
    case unavailable
    case missingName
    case invalidName(String)
    case missingTarget
    case missingSigningKey
    case missingMessageFile

    package var errorDescription: String? {
        switch self {
        case .unavailable:
            "Tag management is unavailable because no repository is open."
        case .missingName:
            "Tag name is required."
        case .invalidName(let name):
            "‘\(name)’ is not a valid Git tag name."
        case .missingTarget:
            "Select one revision to create the tag on."
        case .missingSigningKey:
            "A specific GPG key ID is required for this signing option."
        case .missingMessageFile:
            "A tag message file is required for annotated and signed tags."
        }
    }
}

package protocol RepositoryTagManagingDataSource: RepositoryBrowsingDataSource {
    func resolveTagTarget(_ revision: String) async throws -> ObjectID
    func createTag(_ request: RepositoryCreateTagRequest) async throws -> RepositoryTagMutationResult
    func deleteTag(named name: String) async throws -> RepositoryTagMutationResult
}

package enum GitTagCommandBuilder {
    package static func create(
        _ request: RepositoryCreateTagRequest,
        messageFile: String? = nil
    ) throws -> GitCommand {
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RepositoryTagError.missingName }
        if request.operation == .signWithSpecificKey,
           request.signingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RepositoryTagError.missingSigningKey
        }
        if request.operation.providesMessage, messageFile == nil {
            throw RepositoryTagError.missingMessageFile
        }

        var arguments = ["tag"]
        if request.force { arguments.append("-f") }
        switch request.operation {
        case .lightweight:
            break
        case .annotated:
            arguments.append("-a")
        case .signWithDefaultKey:
            arguments.append("-s")
        case .signWithSpecificKey:
            arguments += ["-u", request.signingKey]
        }
        if let messageFile { arguments += ["-F", messageFile] }
        arguments += [name, "--", request.target.string]
        return GitCommand(
            arguments: arguments,
            accessesRemote: false,
            changesRepositoryState: true
        )
    }

    package static func delete(name: String) throws -> GitCommand {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RepositoryTagError.missingName }
        return GitCommand(
            arguments: ["tag", "-d", name],
            accessesRemote: false,
            changesRepositoryState: true
        )
    }
}

extension GitRepositoryModule: RepositoryTagManagingDataSource {
    package func resolveTagTarget(_ revision: String) async throws -> ObjectID {
        guard let repository = resolvedRepository else { throw RepositoryTagError.unavailable }
        let revision = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revision.isEmpty else { throw RepositoryTagError.missingTarget }
        let command = GitCommand(
            arguments: ["rev-parse", "--verify", "\(revision)^{commit}"],
            accessesRemote: false,
            changesRepositoryState: false
        )
        let result = try await git.run(command, in: repository.rootURL)
        guard result.succeeded else { throw tagCommandError(result) }
        return try ObjectID.parse(result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    package func createTag(_ request: RepositoryCreateTagRequest) async throws -> RepositoryTagMutationResult {
        guard let repository = resolvedRepository else { throw RepositoryTagError.unavailable }
        try await validateTagName(request.name, repository: repository)

        var messageURL: URL?
        if request.operation.providesMessage {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("GitExtensionsMac-tag-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("TAGMESSAGE")
            try Data(request.message.utf8).write(to: url, options: .atomic)
            messageURL = url
        }
        defer {
            if let messageURL {
                try? FileManager.default.removeItem(at: messageURL.deletingLastPathComponent())
            }
        }

        let command = try GitTagCommandBuilder.create(request, messageFile: messageURL?.path)
        let result = try await git.run(command, in: repository.rootURL)
        guard result.succeeded else { throw tagCommandError(result) }
        return RepositoryTagMutationResult(
            selectedCommitID: .object(request.target),
            message: "Tag ‘\(request.name.trimmingCharacters(in: .whitespacesAndNewlines))’ created."
        )
    }

    package func deleteTag(named name: String) async throws -> RepositoryTagMutationResult {
        guard let repository = resolvedRepository else { throw RepositoryTagError.unavailable }
        let command = try GitTagCommandBuilder.delete(name: name)
        let result = try await git.run(command, in: repository.rootURL)
        guard result.succeeded else { throw tagCommandError(result) }
        return RepositoryTagMutationResult(
            selectedCommitID: nil,
            message: "Tag ‘\(name.trimmingCharacters(in: .whitespacesAndNewlines))’ deleted."
        )
    }

    private func validateTagName(_ name: String, repository: ResolvedGitRepository) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RepositoryTagError.missingName }
        let command = GitCommand(
            arguments: ["check-ref-format", "refs/tags/\(name)"],
            accessesRemote: false,
            changesRepositoryState: false
        )
        let result = try await git.run(command, in: repository.rootURL)
        guard result.succeeded else { throw RepositoryTagError.invalidName(name) }
    }

    private func tagCommandError(_ result: GitCommandResult) -> GitError {
        let output = result.standardErrorString.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        return GitError.commandFailed(
            arguments: result.arguments,
            status: result.exitStatus,
            stderr: output.isEmpty ? fallback : output
        )
    }
}
