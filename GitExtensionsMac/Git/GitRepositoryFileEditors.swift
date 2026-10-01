import Foundation
import GitExtensionsCore



package enum RepositoryEditableFile: Sendable, Equatable {
    case gitIgnore, localExclude, gitAttributes, mailMap, gitConfig
}



package struct EditableFileText: Equatable, Sendable {
    package var text: String
    package var encoding: RepositoryTextEncoding
    package var preamble: [UInt8]
    package var exists: Bool

    package init(text: String, encoding: RepositoryTextEncoding, preamble: [UInt8], exists: Bool) {
        self.text = text
        self.encoding = encoding
        self.preamble = preamble
        self.exists = exists
    }
}


package protocol RepositoryFileEditingDataSource: Sendable {

    func editableFileURL(_ file: RepositoryEditableFile) async throws -> URL

    func loadEditableFile(at url: URL) async throws -> EditableFileText

    func ignoredFiles(matching patterns: [String]) async throws -> [String]
}

package enum RepositoryFileEditorCommands {

    package static func gitPath(_ relativePath: String) -> GitCommand {
        GitCommand(arguments: ["rev-parse", "--git-path", relativePath], accessesRemote: false, changesRepositoryState: false)
    }


    package static func ignoredFiles(_ patterns: [String]) -> GitCommand? {
        let patterns = patterns.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !patterns.isEmpty else { return nil }
        return GitCommand(arguments: ["ls-files", "-z", "-o", "-m", "-c", "-i"] + patterns.flatMap { ["-x", $0] },
                          accessesRemote: false, changesRepositoryState: false)
    }


    package static func parseIgnoredFiles(_ output: String) -> [String] {
        var seen = Set<String>()
        return output.split(whereSeparator: { $0 == "\0" || $0 == "\n" }).map(String.init).filter { seen.insert($0).inserted }
    }


    package static func resolveGitPath(_ output: String, in directory: URL) -> URL {
        let path = output.trimmingCharacters(in: .newlines)
        return (path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)).standardizedFileURL
    }
}

package enum EditableFileError: LocalizedError, Equatable {
    case missing(String)
    package var errorDescription: String? {
        switch self {
        case .missing(let path): "Could not find file '\(path)'."
        }
    }
}


package enum EditableFileIO {

    private static let byteOrderMarks: [([UInt8], RepositoryTextEncoding)] = [
        ([0xFF, 0xFE, 0x00, 0x00], RepositoryTextEncoding(ianaName: "utf-32le")!),
        ([0x00, 0x00, 0xFE, 0xFF], RepositoryTextEncoding(ianaName: "utf-32be")!),
        ([0xEF, 0xBB, 0xBF], .utf8),
        ([0xFF, 0xFE], .utf16LittleEndian),
        ([0xFE, 0xFF], .utf16BigEndian)
    ]

    package static func load(_ url: URL, configuredEncoding: RepositoryTextEncoding?) throws -> EditableFileText {
        let encoding = configuredEncoding.flatMap { $0 == .automatic ? nil : $0 } ?? .utf8
        guard FileManager.default.fileExists(atPath: url.path) else {
            return EditableFileText(text: "", encoding: encoding, preamble: [], exists: false)
        }
        let data = try Data(contentsOf: url)
        let bytes = [UInt8](data.prefix(4))
        let mark = byteOrderMarks.first { bytes.starts(with: $0.0) }
        let body = data.dropFirst(mark?.0.count ?? 0)
        let resolved = mark?.1 ?? encoding

        let text = String(data: body, encoding: resolved.foundationEncoding) ?? String(decoding: body, as: UTF8.self)
        return EditableFileText(text: text, encoding: resolved, preamble: mark?.0 ?? [], exists: true)
    }




    package static func saveWithTrailingNewline(_ text: String, to url: URL, createDirectory: Bool) throws {
        var content = text
        if !content.hasSuffix("\n") { content += "\n" }
        try makeTemporarilyWritable(url) {
            if createDirectory {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try Data(content.utf8).write(to: url)
        }
    }



    package static func appendPatterns(_ patterns: [String], to url: URL) throws {
        try makeTemporarilyWritable(url) {
            var addition = ""
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = try Data(contentsOf: url)
                if existing.last != UInt8(ascii: "\n") { addition += "\n" }
            }
            for pattern in patterns { addition += pattern + "\n" }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(addition.utf8))
        }
    }



    package static func saveInPlace(_ text: String, to url: URL, encoding: RepositoryTextEncoding, preamble: [UInt8]) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw EditableFileError.missing(url.path) }

        let body = text.data(using: encoding.foundationEncoding, allowLossyConversion: true) ?? Data(text.utf8)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(preamble) + body)
        try handle.truncate(atOffset: UInt64(preamble.count + body.count))
    }



    package static func makeTemporarilyWritable(_ url: URL, _ action: () throws -> Void) throws {
        let manager = FileManager.default
        guard let permissions = (try? manager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber else {
            try action()
            return
        }
        try manager.setAttributes([.posixPermissions: NSNumber(value: permissions.int16Value | 0o200)], ofItemAtPath: url.path)
        defer {
            if manager.fileExists(atPath: url.path) {
                try? manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            }
        }
        try action()
    }
}

extension GitRepositoryModule: RepositoryFileEditingDataSource {
    package func editableFileURL(_ file: RepositoryEditableFile) async throws -> URL {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        let internalPath: String
        switch file {
        case .gitIgnore: return repository.rootURL.appendingPathComponent(".gitignore")
        case .gitAttributes: return repository.rootURL.appendingPathComponent(".gitattributes")
        case .mailMap: return repository.rootURL.appendingPathComponent(".mailmap")
        case .localExclude: internalPath = "info"
        case .gitConfig: internalPath = "config"
        }
        let command = RepositoryFileEditorCommands.gitPath(internalPath)
        let result = try await git.run(command, in: repository.rootURL)
        guard result.succeeded else {
            throw GitError.commandFailed(arguments: command.arguments, status: result.exitStatus, stderr: result.standardErrorString)
        }
        let url = RepositoryFileEditorCommands.resolveGitPath(result.standardOutputString, in: repository.rootURL)
        return file == .localExclude ? url.appendingPathComponent("exclude") : url
    }

    package func loadEditableFile(at url: URL) async throws -> EditableFileText {
        let configured = try? await configuredFileEncoding()
        return try EditableFileIO.load(url, configuredEncoding: configured ?? nil)
    }

    package func ignoredFiles(matching patterns: [String]) async throws -> [String] {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        guard let command = RepositoryFileEditorCommands.ignoredFiles(patterns) else { return [] }
        let result = try await git.run(command, in: repository.rootURL)

        return RepositoryFileEditorCommands.parseIgnoredFiles(result.standardOutputString)
    }
}
