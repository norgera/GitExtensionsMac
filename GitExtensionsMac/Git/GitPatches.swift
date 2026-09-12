import Foundation
import GitExtensionsCore

package struct PatchRevision: Sendable, Equatable {
    package let id: ObjectID
    package let firstParent: ObjectID?
    package init(id: ObjectID, firstParent: ObjectID?) {
        self.id = id
        self.firstParent = firstParent
    }
}

package enum PatchInput: Sendable {
    case file(URL)
    case directory(URL)
}

package enum PatchContinuation: String, Sendable {
    case resolved, skip, abort
}

package struct RepositoryPatchState: Sendable {
    package let isApplying: Bool
    package let hasConflicts: Bool
    package let next: Int?
    package let last: Int?
    package let currentPatch: String
    package let series: [RepositoryPatchEntry]
}

package struct RepositoryPatchEntry: Sendable {
    package let file: URL
    package let number: Int
    package let subject: String
    package let author: String
    package let date: String
    package let status: RepositoryRebasePatchStatus
}

package struct RepositoryPatchResult: Sendable {
    package let succeeded: Bool
    package let changed: Bool
    package let output: String
    package let state: RepositoryPatchState
}

package struct PatchPreview: Sendable {
    package let files: [ChangedFile]
    package let diffs: [String: FileDiff]
    package let metadata: [String: PatchPreviewMetadata]
}

package struct PatchPreviewMetadata: Sendable {
    package enum Change: String, Sendable { case newFile = "NewFile", deleteFile = "DeleteFile", changeFile = "ChangeFile", changeMode = "ChangeFileMode" }
    package enum FileType: String, Sendable { case binary = "Binary", text = "Text" }
    package let change: Change
    package let fileType: FileType
}

package enum PatchPreviewParser {
    package static func load(_ url: URL) async throws -> PatchPreview {
        try await Task.detached { try parse(Data(contentsOf: url)) }.value
    }
    package static func parse(_ data: Data) throws -> PatchPreview {
        let decoded = FileContentDecoder.decode(data, path: "patch.txt", requestedEncoding: .automatic).text
        let expression = try NSRegularExpression(pattern: #"^diff --(git|cc|combined)\s+(.+)$"#)
        var sections: [[String]] = []
        var current: [String] = []
        for rawLine in decoded.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: #"\u001b\[[0-9;]*m"#, with: "", options: .regularExpression)
            if expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                if !current.isEmpty { sections.append(current) }
                current = [line]
            } else if line == "-- " || line.hasPrefix("From ") {
                if !current.isEmpty { sections.append(current); current = [] }
            } else if !current.isEmpty { current.append(line) }
        }
        if !current.isEmpty { sections.append(current) }
        var files: [ChangedFile] = []
        var diffs: [String: FileDiff] = [:]
        var metadata: [String: PatchPreviewMetadata] = [:]
        for section in sections {
            let header = section[0]
            let combined = !header.hasPrefix("diff --git ")
            let names = String(header.dropFirst(combined ? (header.hasPrefix("diff --cc ") ? 10 : 16) : 11))
            var oldPath: String
            var path: String
            if combined {
                path = unquote(names); oldPath = path
            } else {
                let pair = try NSRegularExpression(pattern: #"^("?[^/\s]+/.*?) ("?[^/\s]+/.*?)$"#)
                guard let match = pair.firstMatch(in: names, range: NSRange(names.startIndex..., in: names)),
                      let a = Range(match.range(at: 1), in: names), let b = Range(match.range(at: 2), in: names)
                else { throw GitError.malformedOutput(command: "patch preview", detail: "Invalid patch header: \(header)") }
                oldPath = stripPrefix(unquote(String(names[a])))
                path = stripPrefix(unquote(String(names[b])))
            }
            var change: PatchPreviewMetadata.Change = .changeFile
            var fileType: PatchPreviewMetadata.FileType = .text
            var type: FileChangeType = .modified
            var body = section
            for (index, line) in section.enumerated().dropFirst() {
                if line.hasPrefix("@@") { break }
                if line.hasPrefix("new file mode ") { change = .newFile; type = .added }
                if line.hasPrefix("deleted file mode ") { change = .deleteFile; type = .deleted }
                if line.hasPrefix("old mode ") { change = .changeMode }
                if line.hasPrefix("rename from ") { type = .renamed }
                if line.hasPrefix("copy from ") { type = .copied }
                if line.hasPrefix("--- "), line != "--- /dev/null" { oldPath = stripPrefix(unquote(String(line.dropFirst(4)))) }
                if line.hasPrefix("+++ "), line != "+++ /dev/null" { path = stripPrefix(unquote(String(line.dropFirst(4)))) }
                if line == "GIT binary patch" || line.hasPrefix("Binary files ") {
                    fileType = .binary
                    body = Array(section.prefix(index + 1))
                    break
                }
            }
            let id = "patch:\(files.count)"
            let additions = body.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
            let deletions = body.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
            let file = ChangedFile(id: id, path: type == .deleted ? oldPath : path,
                                   oldPath: oldPath == path ? nil : oldPath, changeType: type, additions: additions, deletions: deletions)
            files.append(file)
            diffs.merge(GitOutputParser.parseUnifiedDiff(Data(body.joined(separator: "\n").utf8), files: [file])) { _, new in new }
            metadata[id] = PatchPreviewMetadata(change: change, fileType: fileType)
        }
        return PatchPreview(files: files, diffs: diffs, metadata: metadata)
    }

    private static func stripPrefix(_ path: String) -> String {
        guard let slash = path.firstIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    private static func unquote(_ input: String) -> String {
        let trimmed = String(input.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)[0])
            .trimmingCharacters(in: .newlines)
        guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return trimmed }
        let bytes = Array(trimmed.dropFirst().dropLast().utf8)
        var result: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            guard byte == 92, index < bytes.count else { result.append(byte); continue }
            let escaped = bytes[index]; index += 1
            if (48...55).contains(escaped) {
                var value = Int(escaped - 48)
                for _ in 0..<2 where index < bytes.count && (48...55).contains(bytes[index]) {
                    value = value * 8 + Int(bytes[index] - 48); index += 1
                }
                result.append(UInt8(truncatingIfNeeded: value))
            } else { result.append([UInt8(110): 10, 116: 9, 114: 13, 98: 8, 102: 12, 118: 11, 97: 7][escaped] ?? escaped) }
        }
        return String(decoding: result, as: UTF8.self)
    }
}

package protocol RepositoryPatchingDataSource: RepositoryConflictResolutionDataSource {
    func addPatchFiles(_ paths: [String], force: Bool, preview: Bool) async throws -> RepositoryPatchResult
    func loadPatchPreview(_ url: URL) async throws -> PatchPreview
    func formatPatches(_ revisions: [PatchRevision], outputDirectory: URL) async throws -> String
    func loadPatchState() async throws -> RepositoryPatchState
    func applyPatches(_ input: PatchInput, signOff: Bool, ignoreWhitespace: Bool,
                      output: @escaping GitOutputHandler) async throws -> RepositoryPatchResult
    func continuePatches(_ action: PatchContinuation, output: @escaping GitOutputHandler) async throws -> RepositoryPatchResult
}

package enum GitPatchCommands {
    package static func format(_ revisions: [PatchRevision], outputDirectory: URL) -> [GitCommand] {
        func command(_ first: PatchRevision, _ last: PatchRevision, start: Int? = nil) -> GitCommand {
            var args = ["format-patch", "--find-renames", "--find-copies", "--break-rewrites"]
            if let start { args += ["--start-number", String(start)] }
            if let parent = first.firstParent { args.append("\(parent.string)..\(last.id.string)") }
            else { args += ["--root", last.id.string] }
            args += ["-o", outputDirectory.path]
            return GitCommand(arguments: args, accessesRemote: false, changesRepositoryState: false)
        }
        guard let first = revisions.first, let last = revisions.last else { return [] }
        if revisions.count <= 2 { return [command(first, last)] }
        return revisions.enumerated().map { command($0.element, $0.element, start: $0.offset + 1) }
    }

    package static func apply(isDiff: Bool, file: URL?, signOff: Bool, ignoreWhitespace: Bool) -> GitCommand {
        var args = isDiff ? ["apply"] : ["am", "--3way"]
        if !isDiff && signOff { args.append("--signoff") }
        if ignoreWhitespace { args.append("--ignore-whitespace") }
        if let file { args.append(file.path) }
        return GitCommand(arguments: args, accessesRemote: false, changesRepositoryState: true)
    }

    package static func continuation(_ action: PatchContinuation) -> GitCommand {
        GitCommand(arguments: ["am", "--3way", "--\(action.rawValue)"], accessesRemote: false, changesRepositoryState: true)
    }

    package static func isDiff(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        let line = text.trimmingPrefix("\u{feff}").prefix { $0 != "\n" && $0 != "\r" }
        return line.hasPrefix("diff ") || line.hasPrefix("Index: ")
    }
}

extension GitRepositoryModule: RepositoryPatchingDataSource {
    package func addPatchFiles(_ paths: [String], force: Bool, preview: Bool) async throws -> RepositoryPatchResult {
        let repository = try mutationRepository()
        var args = ["add"]
        if preview { args.append("--dry-run") }
        if force { args.append("-f") }
        args += paths
        return try await executePatch(GitCommand(arguments: args, accessesRemote: false, changesRepositoryState: !preview),
                                      repository: repository, output: { _ in })
    }
    package func loadPatchPreview(_ url: URL) async throws -> PatchPreview {
        try PatchPreviewParser.parse(Data(contentsOf: url))
    }
    package func formatPatches(_ revisions: [PatchRevision], outputDirectory: URL) async throws -> String {
        guard !revisions.isEmpty else {
            throw GitError.malformedOutput(command: "format-patch", detail: "You need to select at least one revision.")
        }
        let repository = try mutationRepository()
        var output = ""
        for command in GitPatchCommands.format(revisions, outputDirectory: outputDirectory) {
            let result = try await git.run(command, in: repository.rootURL)
            guard result.succeeded else { throw commandError(from: result) }
            output += result.standardOutputString
        }
        return output
    }

    package func loadPatchState() async throws -> RepositoryPatchState {
        try await patchState(in: mutationRepository())
    }

    package func applyPatches(_ input: PatchInput, signOff: Bool, ignoreWhitespace: Bool,
                              output: @escaping GitOutputHandler) async throws -> RepositoryPatchResult {
        let repository = try mutationRepository()
        let command: GitCommand
        var standardInput: Data?
        var inspectedPaths: [String] = []
        switch input {
        case .file(let url):
            let data = try Data(contentsOf: url)
            if GitPatchCommands.isDiff(data), let preview = try? PatchPreviewParser.parse(data) {
                inspectedPaths = preview.files.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) }
            }
            command = GitPatchCommands.apply(isDiff: GitPatchCommands.isDiff(data), file: url,
                                             signOff: signOff, ignoreWhitespace: ignoreWhitespace)
        case .directory(let url):
            let entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
            var bytes = Data()
            for entry in entries where try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true {
                bytes.append(try Data(contentsOf: entry))
            }
            standardInput = bytes
            command = GitPatchCommands.apply(isDiff: false, file: nil, signOff: signOff, ignoreWhitespace: ignoreWhitespace)
        }
        return try await executePatch(command, standardInput: standardInput, inspectedPaths: inspectedPaths,
                                      repository: repository, output: output)
    }

    package func continuePatches(_ action: PatchContinuation, output: @escaping GitOutputHandler) async throws -> RepositoryPatchResult {
        let repository = try mutationRepository()
        return try await executePatch(GitPatchCommands.continuation(action), repository: repository, output: output)
    }

    private func patchState(in repository: ResolvedGitRepository) async throws -> RepositoryPatchState {
        let directory = repository.gitDirectoryURL.appendingPathComponent("rebase-apply")
        func text(_ name: String) -> String {
            (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        let state = try await mutationState(in: repository)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .compactMap { name in Int(name).map { (name, $0) } }.sorted { $0.1 < $1.1 }
        let series = zip(names, parseApplyRebasePatches(directory: directory)).map { name, patch in
            RepositoryPatchEntry(file: directory.appendingPathComponent(name.0), number: name.1,
                                 subject: patch.subject, author: patch.author, date: patch.date, status: patch.status)
        }
        return RepositoryPatchState(
            isApplying: FileManager.default.fileExists(atPath: directory.appendingPathComponent("applying").path),
            hasConflicts: !state.conflictedPaths.isEmpty,
            next: Int(text("next").trimmingCharacters(in: .whitespacesAndNewlines)),
            last: Int(text("last").trimmingCharacters(in: .whitespacesAndNewlines)),
            currentPatch: text("patch"), series: series)
    }

    private func patchFingerprint(in repository: ResolvedGitRepository, inspectedPaths: [String] = []) async throws -> [Data] {
        var result: [Data] = []
        let root = repository.rootURL.resolvingSymlinksInPath().standardizedFileURL
        for path in Set(inspectedPaths).sorted() {
            let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else { continue }
            result.append(Data([FileManager.default.fileExists(atPath: url.path) ? 1 : 0]))
            result.append((try? Data(contentsOf: url)) ?? Data())
        }
        for args in [["rev-parse", "--verify", "HEAD"], ["ls-files", "--stage", "-z"],
                     ["diff", "--binary", "--no-ext-diff"], ["status", "--porcelain=v1", "-z", "--untracked-files=all"]] {
            result.append(try await git.run(GitCommand(arguments: args, accessesRemote: false,
                                                       changesRepositoryState: false), in: repository.rootURL).standardOutput)
        }
        let untracked = try await git.run(GitCommand(arguments: ["ls-files", "--others", "--exclude-standard", "-z"],
                                                      accessesRemote: false, changesRepositoryState: false), in: repository.rootURL)
        for bytes in untracked.standardOutput.split(separator: 0) {
            let path = String(decoding: bytes, as: UTF8.self)
            result.append((try? Data(contentsOf: repository.rootURL.appendingPathComponent(path))) ?? Data())
        }
        let directory = repository.gitDirectoryURL.appendingPathComponent("rebase-apply")
        for name in ["applying", "next", "last", "patch", "orig-head"] {
            let url = directory.appendingPathComponent(name)
            result.append(Data([FileManager.default.fileExists(atPath: url.path) ? 1 : 0]))
            result.append((try? Data(contentsOf: url)) ?? Data())
        }
        return result
    }

    private func executePatch(_ command: GitCommand, standardInput: Data? = nil, inspectedPaths: [String] = [],
                              repository: ResolvedGitRepository, output: @escaping GitOutputHandler) async throws -> RepositoryPatchResult {
        let before = try await patchFingerprint(in: repository, inspectedPaths: inspectedPaths)
        var succeeded = false
        var transcript = ""
        do {
            let execution = try await git.runStreaming(command, in: repository.rootURL, standardInput: standardInput, output: output)
            succeeded = execution.succeeded
            transcript = execution.standardOutputString + execution.standardErrorString
        } catch { transcript = error.localizedDescription }
        let after = try await Task { try await self.patchFingerprint(in: repository, inspectedPaths: inspectedPaths) }.value
        let state = try await Task { try await self.patchState(in: repository) }.value
        return RepositoryPatchResult(succeeded: succeeded, changed: before != after, output: transcript, state: state)
    }
}
