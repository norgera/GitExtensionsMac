import Foundation
import GitExtensionsCore

package enum ArchiveFormat: String, CaseIterable, Sendable { case zip, tar }

package enum ArchiveFilter: Sendable {
    case all
    case paths([String])
    case changedSince(ObjectID)
}

package struct ArchiveRequest: Sendable {
    package let revision: ObjectID
    package let format: ArchiveFormat
    package let destination: URL
    package let filter: ArchiveFilter
    package init(revision: ObjectID, format: ArchiveFormat, destination: URL, filter: ArchiveFilter = .all) {
        self.revision = revision; self.format = format; self.destination = destination; self.filter = filter
    }
}

package protocol RepositoryArchivingDataSource: Sendable {
    func archive(_ request: ArchiveRequest, output: @escaping GitOutputHandler) async throws -> GitCommandResult
}

package enum GitArchiveCommands {
    package static func archive(_ request: ArchiveRequest, paths: [String]) -> GitCommand {
        GitCommand(arguments: ["archive", "--format=\(request.format.rawValue)", request.revision.string,
                               "--output", request.destination.path] + paths.filter { !$0.isEmpty },
                   accessesRemote: false, changesRepositoryState: false)
    }

    package static func suggestedFilename(repositoryName: String, revision: ObjectID, paths: [String]?) -> String {
        var name = "\(repositoryName)_\(revision.string)"
        if let paths, paths.count == 1, let path = paths.first?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
            name += "_" + path.replacingOccurrences(of: ".", with: "_")
        }
        return name
    }

    static func changedPaths(_ data: Data) throws -> [String] {
        let fields = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var paths: [String] = []; var index = 0
        while index < fields.count {
            let header = fields[index]; index += 1
            guard header.hasPrefix(":"), let status = header.split(separator: " ").last?.first,
                  index < fields.count else { throw GitError.malformedOutput(command: "archive diff", detail: "Invalid raw diff record.") }
            var path = fields[index]; index += 1
            if status == "R" || status == "C" {
                guard index < fields.count else { throw GitError.malformedOutput(command: "archive diff", detail: "Missing destination path.") }
                path = fields[index]; index += 1
            }
            if status != "D" { paths.append(path) }
        }
        return paths
    }
}

extension GitRepositoryModule: RepositoryArchivingDataSource {
    package func archive(_ request: ArchiveRequest, output: @escaping GitOutputHandler) async throws -> GitCommandResult {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        let paths: [String]
        switch request.filter {
        case .all: paths = []
        case .paths(let selected): paths = selected
        case .changedSince(let comparison):
            let command = GitCommand(arguments: ["diff", "--no-ext-diff", "--find-renames", "--find-copies", "--raw", "-z",
                                                  comparison.string, request.revision.string],
                                     accessesRemote: false, changesRepositoryState: false)
            let result = try await git.run(command, in: repository.rootURL)
            guard result.succeeded else { throw commandError(from: result) }
            paths = try GitArchiveCommands.changedPaths(result.standardOutput)
        }
        return try await git.runStreaming(GitArchiveCommands.archive(request, paths: paths), in: repository.rootURL, output: output)
    }
}
