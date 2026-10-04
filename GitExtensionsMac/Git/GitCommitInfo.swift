import Foundation
import GitExtensionsCore


package protocol RepositoryCommitInfoDataSource: Sendable {

    func loadCommitMessageAndNotes(_ id: ObjectID) async throws -> RepositoryCommitMessage

    func loadBranchesContaining(_ id: ObjectID, local: Bool, remote: Bool) async throws -> [String]

    func loadTagsContaining(_ id: ObjectID) async throws -> [String]

    func loadTagMessage(_ tag: String) async throws -> String?

    func loadDescribe(_ id: ObjectID) async throws -> RepositoryCommitDescription

    func loadTagOrder() async throws -> [String: Int]

    func loadSelectedBranch() async throws -> String

    func resolveCommit(_ expression: String) async throws -> ObjectID?

    func loadNotes(_ id: ObjectID) async throws -> String

    func saveNotes(_ id: ObjectID, text: String) async throws
}

package struct RepositoryCommitMessage: Equatable, Sendable {
    package let body: String
    package let notes: String
    package init(body: String, notes: String) { self.body = body; self.notes = notes }
}

package struct RepositoryCommitDescription: Equatable, Sendable {
    package let precedingTag: String
    package let commitCount: String
    package init(precedingTag: String, commitCount: String) { self.precedingTag = precedingTag; self.commitCount = commitCount }
}

package enum RepositoryCommitInfoError: LocalizedError, Equatable {

    case brokenRefs(String)
    package var errorDescription: String? {
        switch self {
        case .brokenRefs(let warning): "The repository refs seem to be broken:\n\n\(warning)"
        }
    }
}

package enum CommitInfoCommands {
    static let messageSeparator = "\u{1f}\u{1f}notes\u{1f}\u{1f}"

    package static func messageAndNotes(_ id: ObjectID) -> GitCommand {
        GitCommand(arguments: ["log", "-1", "--no-show-signature", "--pretty=format:%B\(messageSeparator)%N", id.string, "--"],
                   accessesRemote: false, changesRepositoryState: false).logMetadata()
    }

    package static func branchesContaining(_ id: ObjectID, local: Bool, remote: Bool) -> GitCommand? {
        guard local || remote else { return nil }
        var arguments = ["branch"]
        if local && remote { arguments.append("-a") } else if remote { arguments.append("-r") }
        arguments += ["--contains", id.string]
        return GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: false)
    }

    package static func tagsContaining(_ id: ObjectID) -> GitCommand {
        GitCommand(arguments: ["tag", "--contains", id.string], accessesRemote: false, changesRepositoryState: false)
    }

    package static func tagMessage(_ tag: String) -> GitCommand {
        GitCommand(arguments: ["cat-file", "-p", tag], accessesRemote: false, changesRepositoryState: false)
    }

    package static func describe(_ id: ObjectID) -> GitCommand {
        GitCommand(arguments: ["describe", "--tags", "--first-parent", "--abbrev=40", id.string],
                   accessesRemote: false, changesRepositoryState: false)
    }

    package static let tagOrder = GitCommand(arguments: ["for-each-ref", "--sort=-taggerdate", "--format=%(refname)", "refs/tags/"],
                                             accessesRemote: false, changesRepositoryState: false)
    package static let symbolicHead = GitCommand(arguments: ["symbolic-ref", "--quiet", "HEAD"], accessesRemote: false, changesRepositoryState: false)

    package static func resolveCommit(_ expression: String) -> GitCommand {
        GitCommand(arguments: ["rev-parse", "--verify", "--quiet", "\(expression)^{commit}"], accessesRemote: false, changesRepositoryState: false)
    }

    package static func showNotes(_ id: ObjectID) -> GitCommand {
        GitCommand(arguments: ["notes", "show", id.string], accessesRemote: false, changesRepositoryState: false)
    }

    package static func addNotes(_ id: ObjectID) -> GitCommand {
        GitCommand(arguments: ["notes", "add", "-f", "-F", "-", id.string], accessesRemote: false, changesRepositoryState: true)
    }

    package static func removeNotes(_ id: ObjectID) -> GitCommand {
        GitCommand(arguments: ["notes", "remove", "--ignore-missing", id.string], accessesRemote: false, changesRepositoryState: true)
    }


    package static func parseMessageAndNotes(_ output: String) -> RepositoryCommitMessage {
        let text = output.replacingOccurrences(of: "\u{0b}", with: "\n")
        guard let range = text.range(of: messageSeparator, options: .backwards) else {
            return RepositoryCommitMessage(body: text.trimmingTrailingWhitespace(), notes: "")
        }

        var notes = String(text[range.upperBound...])
        while notes.hasSuffix("\n") || notes.hasSuffix("\r") { notes.removeLast() }
        return RepositoryCommitMessage(body: String(text[..<range.lowerBound]).trimmingTrailingWhitespace(), notes: notes)
    }


    package static func parseContainingBranches(_ output: String, remote: Bool) -> [String] {
        output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map { line in
            var item = String(line)
            if item.count >= 2, [" ", "*", "+"].contains(item.first!), item[item.index(after: item.startIndex)] == " " {
                item = String(item.dropFirst(2))
            }
            if remote, let arrow = item.range(of: " ->") { item = String(item[..<arrow.lowerBound]) }
            return item
        }
    }


    package static func parseTagMessage(_ output: String) -> String? {
        let lines = output.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard lines.count > 5 else { return nil }
        return lines[5...].joined(separator: "\n").trimmingTrailingWhitespace()
    }


    package static func parseDescribe(_ output: String?, id: ObjectID) -> RepositoryCommitDescription {
        guard var description = output?.trimmingTrailingWhitespace(), !description.isEmpty else {
            return RepositoryCommitDescription(precedingTag: "", commitCount: "")
        }
        guard let hashRange = description.range(of: "-g", options: [.backwards, .caseInsensitive]) else {
            return RepositoryCommitDescription(precedingTag: description, commitCount: "")
        }
        let hash = String(description[hashRange.upperBound...])
        guard !hash.isEmpty, hash == id.string else { return RepositoryCommitDescription(precedingTag: description, commitCount: "") }
        description = String(description[..<hashRange.lowerBound])
        guard let countRange = description.range(of: "-", options: .backwards) else {
            return RepositoryCommitDescription(precedingTag: description, commitCount: "")
        }
        return RepositoryCommitDescription(precedingTag: String(description[..<countRange.lowerBound]),
                                           commitCount: String(description[countRange.upperBound...]))
    }


    package static func parseTagOrder(_ output: String) throws -> [String: Int] {
        if let warning = output.range(of: "warning:") {
            let line = output[warning.lowerBound...].split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            throw RepositoryCommitInfoError.brokenRefs(line)
        }
        var order: [String: Int] = [:]
        var index = 0
        for entry in output.components(separatedBy: "\n") where order[entry] == nil {
            order[entry] = index
            index += 1
        }
        return order
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var value = self
        while let last = value.last, last.isWhitespace { value.removeLast() }
        return value
    }
}

extension GitRepositoryModule: RepositoryCommitInfoDataSource {
    private func commitInfoRoot() throws -> URL {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        return repository.rootURL
    }

    package func loadCommitMessageAndNotes(_ id: ObjectID) async throws -> RepositoryCommitMessage {
        let result = try await git.run(CommitInfoCommands.messageAndNotes(id), in: try commitInfoRoot())
        guard result.succeeded else {
            throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString)
        }
        return CommitInfoCommands.parseMessageAndNotes(result.standardOutputString)
    }

    package func loadBranchesContaining(_ id: ObjectID, local: Bool, remote: Bool) async throws -> [String] {
        guard let command = CommitInfoCommands.branchesContaining(id, local: local, remote: remote) else { return [] }
        let result = try await git.run(command, in: try commitInfoRoot())

        return result.succeeded ? CommitInfoCommands.parseContainingBranches(result.standardOutputString, remote: remote) : []
    }

    package func loadTagsContaining(_ id: ObjectID) async throws -> [String] {
        let result = try await git.run(CommitInfoCommands.tagsContaining(id), in: try commitInfoRoot())
        guard result.succeeded else { return [] }
        return result.standardOutputString.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
    }

    package func loadTagMessage(_ tag: String) async throws -> String? {
        let tag = tag.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty else { return nil }
        let result = try await git.run(CommitInfoCommands.tagMessage(tag), in: try commitInfoRoot())
        return result.succeeded ? CommitInfoCommands.parseTagMessage(result.standardOutputString) : nil
    }

    package func loadDescribe(_ id: ObjectID) async throws -> RepositoryCommitDescription {
        let result = try await git.run(CommitInfoCommands.describe(id), in: try commitInfoRoot())
        return CommitInfoCommands.parseDescribe(result.succeeded ? result.standardOutputString : nil, id: id)
    }

    package func loadTagOrder() async throws -> [String: Int] {
        let result = try await git.run(CommitInfoCommands.tagOrder, in: try commitInfoRoot())
        return try CommitInfoCommands.parseTagOrder(result.standardOutputString + result.standardErrorString)
    }

    package func loadSelectedBranch() async throws -> String {
        let result = try await git.run(CommitInfoCommands.symbolicHead, in: try commitInfoRoot())
        guard result.succeeded else { return RepositoryHistory.detachedBranch }
        let name = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name
    }

    package func resolveCommit(_ expression: String) async throws -> ObjectID? {
        if let id = try? ObjectID.parse(expression) { return id }
        let result = try await git.run(CommitInfoCommands.resolveCommit(expression), in: try commitInfoRoot())
        return try? ObjectID.parse(result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    package func loadNotes(_ id: ObjectID) async throws -> String {
        let result = try await git.run(CommitInfoCommands.showNotes(id), in: try commitInfoRoot())
        guard result.succeeded else { return "" }
        var notes = result.standardOutputString
        if notes.hasSuffix("\n") { notes.removeLast() }
        return notes
    }

    package func saveNotes(_ id: ObjectID, text: String) async throws {
        let root = try commitInfoRoot()
        let empty = text.split(separator: "\n").allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        let result = empty
            ? try await git.run(CommitInfoCommands.removeNotes(id), in: root)
            : try await git.run(CommitInfoCommands.addNotes(id), in: root, standardInput: Data(text.utf8))
        guard result.succeeded else {
            throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString)
        }
    }
}
