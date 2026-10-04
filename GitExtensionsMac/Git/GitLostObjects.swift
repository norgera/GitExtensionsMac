import Foundation
import GitExtensionsCore


package enum LostObjectType: Sendable, Equatable {
    case commit, blob, tree, tag, other
}


package struct LostObject: Identifiable, Equatable, Sendable {
    package let objectType: LostObjectType
    package let objectID: ObjectID

    package var rawType: String
    package var parent: ObjectID?
    package var author: String?
    package var subject: String?
    package var date: Date?
    package var tagName: String?
    package var id: ObjectID { objectID }

    package init(objectType: LostObjectType, objectID: ObjectID, rawType: String, parent: ObjectID? = nil,
                 author: String? = nil, subject: String? = nil, date: Date? = nil, tagName: String? = nil) {
        self.objectType = objectType
        self.objectID = objectID
        self.rawType = rawType
        self.parent = parent
        self.author = author
        self.subject = subject
        self.date = date
        self.tagName = tagName
    }


    package var isCommitOrTag: Bool { objectType == .commit || objectType == .tag }
}


package struct LostObjectsOptions: Equatable, Sendable {
    package var unreachable = false
    package var fullCheck = false
    package var noReflogs = true
    package init(unreachable: Bool = false, fullCheck: Bool = false, noReflogs: Bool = true) {
        self.unreachable = unreachable
        self.fullCheck = fullCheck
        self.noReflogs = noReflogs
    }
    package var arguments: [String] {
        (unreachable ? ["--unreachable"] : []) + (fullCheck ? ["--full"] : []) + (noReflogs ? ["--no-reflogs"] : [])
    }
}

package protocol RepositoryLostObjectsDataSource: Sendable {

    func checkObjects(_ options: LostObjectsOptions, output: @escaping GitOutputHandler) async throws -> GitCommandResult

    func lostObjects(fromFsckOutput output: String) async throws -> [LostObject]

    func saveLostObjects(_ options: LostObjectsOptions, output: @escaping GitOutputHandler) async throws -> GitCommandResult

    func pruneObjects(output: @escaping GitOutputHandler) async throws -> GitCommandResult

    func showObject(_ id: ObjectID) async throws -> Data

    func lostFoundTagNames() async throws -> [String]

    func saveBlob(_ id: ObjectID, to url: URL) async throws
}

package enum LostObjectsCommands {
    package static let restoredObjectsTagPrefix = "LOST_FOUND_"
    package static func fsck(_ options: LostObjectsOptions, lostFound: Bool = false) -> GitCommand {
        GitCommand(arguments: ["fsck-objects"] + (lostFound ? ["--lost-found"] : []) + options.arguments,
                   accessesRemote: false, changesRepositoryState: lostFound)
    }
    package static let prune = GitCommand(arguments: ["prune"], accessesRemote: false, changesRepositoryState: true)
    package static func show(_ id: ObjectID) -> GitCommand {
        GitCommand(arguments: ["show", id.string], accessesRemote: false, changesRepositoryState: false)
    }

    package static func commitsMetadata(_ ids: [ObjectID]) -> GitCommand {
        GitCommand(arguments: ["show", "--quiet", "--pretty=format:%H\u{1F}%aN\u{1F}%s\u{1F}%ct\u{1F}%P"] + ids.map(\.string),
                   accessesRemote: false, changesRepositoryState: false).logMetadata()
    }
    package static func catFile(_ id: ObjectID) -> GitCommand {
        GitCommand(arguments: ["cat-file", "-p", id.string], accessesRemote: false, changesRepositoryState: false)
    }

    package static let metadataBatchSize = 30_000 / (40 + 1)


    package static func parse(_ line: String) -> LostObject? {
        let kinds = ["dangling", "missing", "unreachable"]
        let types: [String: LostObjectType] = ["commit": .commit, "blob": .blob, "tree": .tree, "tag": .tag]
        let words = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let rawType: String
        let type: LostObjectType
        let hashIndex: Int
        if words.count >= 3, kinds.contains(words[0]), let objectType = types[words[1]] {
            rawType = "\(words[0]) \(words[1])"; type = objectType; hashIndex = 2
        } else if words.count >= 4, words[0] == "warning", words[1] == "in", words[2] == "tree" {
            rawType = "warning in tree"; type = .other; hashIndex = 3
        } else {
            return nil
        }

        let digits = words[hashIndex].prefix { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
        let length = digits.count >= 64 ? 64 : (digits.count >= 40 ? 40 : 0)
        guard length > 0, let id = try? ObjectID.parse(String(digits.prefix(length))) else { return nil }
        return LostObject(objectType: type, objectID: id, rawType: rawType)
    }


    package static func fillCommit(_ object: inout LostObject, metadata: String) {
        let fields = metadata.split(separator: "\u{1F}", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5, !fields[1].isEmpty, let seconds = TimeInterval(fields[3]) else { return }
        object.author = fields[1]
        object.subject = fields[2]
        object.date = Date(timeIntervalSince1970: seconds)
        if let first = fields[4].split(separator: " ").first { object.parent = try? ObjectID.parse(String(first)) }
    }


    package static func fillTag(_ object: inout LostObject, catFile: String) {
        let lines = catFile.components(separatedBy: "\n")
        guard lines.count >= 6, lines[0].hasPrefix("object "), lines[1] == "type commit", lines[2].hasPrefix("tag "),
              lines[3].hasPrefix("tagger "), lines[4].isEmpty else { return }
        let tagger = String(lines[3].dropFirst("tagger ".count))
        guard let open = tagger.range(of: " <"), let close = tagger.range(of: "> ", range: open.upperBound..<tagger.endIndex) else { return }

        let rest = String(tagger[close.upperBound...])
        guard let space = rest.lastIndex(of: " "), let seconds = TimeInterval(rest[..<space]) else { return }
        guard let parent = try? ObjectID.parse(String(lines[0].dropFirst("object ".count))) else { return }
        let name = String(lines[2].dropFirst("tag ".count))
        object.parent = parent
        object.author = String(tagger[..<open.lowerBound])
        object.tagName = name
        object.subject = "\(name):\(lines[5])"
        object.date = Date(timeIntervalSince1970: seconds)
    }


    private static let languagesStartOfFile: [(String, String)] = [
        (#"{\rtf"#, "rtf"), ("{", "json"), ("#include", "cpp"), ("import {", "js"), ("import * as", "js"), ("import \"", "js"),
        ("export ", "js"), ("import ", "java"), ("from", "py"), ("package", "go"), ("namespace ", "fs"), ("#!", "sh"),
        ("[", "ini"), ("using ", "cs"), ("# ", "md"), ("##", "md"), ("<!doctype html", "html"), ("<html", "html"),
        ("<?xml", "xml"), ("use ", "rs"), ("%PDF", "pdf"), ("PK", "zip"), ("MZ", "exe"), (#"\document"#, "tex"),
        ("\u{0089}PNG", "png"), ("ÿØÿQ", "jp2"), ("ÿØÿ", "jpg"), ("ÿ\u{0A}", "jxl"), ("RIFF", "webp"), ("<svg", "svg"),
        ("BM", "bmp"), ("7z", "7z"), ("GIF", "gif"), ("ÐÏ\u{11}à¡±\u{1A}á", "doc"), ("qoif", "qoi"), ("Rar!", "rar"),
        ("%!PS", "ps"), ("OggS", "ogg"), ("8BPS", "psf"), ("ID3", "mp3"), ("CD001", "iso"), ("fLaC", "flac"),
        ("FLIF", "flif"), ("␚Eß£", "mkv"), ("<", "xml")
    ]


    package static func guessFileType(_ data: Data) -> String {
        let content = (String(data: data.prefix(64), encoding: .isoLatin1) ?? "").lowercased()
        return languagesStartOfFile.first { content.hasPrefix($0.0.lowercased()) }?.1 ?? "txt"
    }


    package static func guessFileName(_ data: Data, id: ObjectID) -> String { "LOST_FOUND_\(id.string).\(guessFileType(data))" }


    package static let fileTypesEquivalences: [String: [String]] = [
        "js": ["ts", "jsx", "tsx"], "html": ["php", "cshtml"], "cpp": ["c"],
        "xml": ["config", "settings", "csproj", "xlf", "props"],
        "zip": ["docx", "xlsx", "pptx", "odt", "ods", "odp", "epub", "jar", "msix"], "exe": ["dll"],
        "doc": ["xls", "ppt", "msi"], "md": ["sh", "yml"], "txt": ["csv", "css", "md", "yml"]
    ]


    package static let binaryExtensions = [".avi", ".bmp", ".dat", ".bin", ".dll", ".doc", ".docx", ".ppt", ".pps", ".pptx",
                                           ".ppsx", ".dwg", ".exe", ".gif", ".ico", ".jpg", ".jpeg", ".mpg", ".mpeg", ".msi",
                                           ".pdf", ".png", ".pdb", ".sc1", ".tif", ".tiff", ".vsd", ".vsdx", ".xls", ".xlsx", ".odt"]


    package static func convertCrLfToWorktree(_ buffer: Data) -> Data {
        let bytes = [UInt8](buffer)
        var nul = 0, cr = 0, lf = 0, crlf = 0, printable = 0, nonPrintable = 0
        for (index, byte) in bytes.enumerated() {
            if byte == 0x0D {
                cr += 1
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A { crlf += 1 }
                continue
            }
            if byte == 0x0A { lf += 1; continue }
            if byte == 0x7F { nonPrintable += 1 }
            else if byte < 0x20 {
                switch byte {
                case 0x08, 0x09, 0x1B, 0x0C: printable += 1
                case 0: nul += 1; nonPrintable += 1
                default: nonPrintable += 1
                }
            } else { printable += 1 }
        }
        if bytes.last == 0x1A { nonPrintable -= 1 }
        guard lf != 0, lf != crlf, cr == crlf, nul == 0, printable / 128 >= nonPrintable else { return buffer }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + bytes.count / 100)
        for (index, byte) in bytes.enumerated() {
            if byte == 0x0A && (index == 0 || bytes[index - 1] != 0x0D) { output.append(0x0D) }
            output.append(byte)
        }
        return Data(output)
    }


    package static func isBinaryContent(_ data: Data) -> Bool { data.lazy.filter { $0 == 0 }.count > 5 }


    package static func binaryAccordingToAttributes(_ output: String) -> Bool? {
        let diffValues: Set<String> = ["set", "astextplain", "ada", "bibtext", "cpp", "csharp", "css", "dts", "elixir", "fortran",
                                       "html", "java", "kotlin", "markdown", "matlab", "objc", "pascal", "perl", "php", "python",
                                       "ruby", "rust", "scheme", "tex"]
        let parts = output.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\0" || $0 == "\n" }).map(String.init)
        var attributes: [String: String] = [:]
        var index = 0
        while index + 2 < parts.count {
            attributes[parts[index + 1].trimmingCharacters(in: .whitespaces)] = parts[index + 2].trimmingCharacters(in: .whitespaces)
            index += 3
        }
        if let diff = attributes["diff"] {
            if diff == "unset" { return true }
            if diffValues.contains(diff) { return false }
        }
        for key in ["text", "crlf", "eol"] {
            if let value = attributes[key], value != "unset", value != "unspecified" { return false }
        }
        return nil
    }
}

extension GitRepositoryModule: RepositoryLostObjectsDataSource {
    private func lostObjectsRoot() throws -> URL {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        return repository.rootURL
    }

    package func checkObjects(_ options: LostObjectsOptions, output: @escaping GitOutputHandler) async throws -> GitCommandResult {
        try await git.runStreaming(LostObjectsCommands.fsck(options), in: try lostObjectsRoot(), output: output)
    }

    package func saveLostObjects(_ options: LostObjectsOptions, output: @escaping GitOutputHandler) async throws -> GitCommandResult {
        try await git.runStreaming(LostObjectsCommands.fsck(options, lostFound: true), in: try lostObjectsRoot(), output: output)
    }

    package func pruneObjects(output: @escaping GitOutputHandler) async throws -> GitCommandResult {
        try await git.runStreaming(LostObjectsCommands.prune, in: try lostObjectsRoot(), output: output)
    }

    package func lostObjects(fromFsckOutput output: String) async throws -> [LostObject] {
        let root = try lostObjectsRoot()
        var objects = output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { LostObjectsCommands.parse(String($0)) }

        let objectsPath = try await git.run(GitCommand(arguments: ["rev-parse", "--git-path", "objects"], accessesRemote: false,
                                                       changesRepositoryState: false), in: root)
        let objectsURL = objectsPath.succeeded ? RepositoryFileEditorCommands.resolveGitPath(objectsPath.standardOutputString, in: root) : nil
        for index in objects.indices {
            switch objects[index].objectType {
            case .tag:
                let result = try await git.run(LostObjectsCommands.catFile(objects[index].objectID), in: root)
                LostObjectsCommands.fillTag(&objects[index], catFile: String(decoding: result.standardOutput, as: UTF8.self))
            case .blob:
                let hash = objects[index].objectID.string
                if let objectsURL {
                    let file = objectsURL.appendingPathComponent(String(hash.prefix(2))).appendingPathComponent(String(hash.dropFirst(2)))
                    objects[index].date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.creationDate] as? Date
                }
            default:
                break
            }
        }

        let commits = objects.indices.filter { objects[$0].objectType == .commit }
        var metadata: [ObjectID: String] = [:]
        var start = 0
        while start < commits.count {
            let batch = commits[start..<min(start + LostObjectsCommands.metadataBatchSize, commits.count)].map { objects[$0].objectID }
            let result = try await git.run(LostObjectsCommands.commitsMetadata(batch), in: root)
            for line in String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\n") {
                let hash = line.prefix { $0 != "\u{1F}" }
                if let id = try? ObjectID.parse(String(hash)) { metadata[id] = String(line) }
            }
            start += LostObjectsCommands.metadataBatchSize
        }
        for index in commits {
            if let line = metadata[objects[index].objectID] { LostObjectsCommands.fillCommit(&objects[index], metadata: line) }
        }

        return objects.enumerated().sorted { lhs, rhs in
            switch (lhs.element.date, rhs.element.date) {
            case let (l?, r?): return l != r ? l > r : lhs.offset < rhs.offset
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    package func showObject(_ id: ObjectID) async throws -> Data {
        try await git.run(LostObjectsCommands.show(id), in: try lostObjectsRoot()).standardOutput
    }

    package func lostFoundTagNames() async throws -> [String] {
        let command = GitCommand(arguments: ["for-each-ref", "--format=%(refname:strip=2)", "refs/tags/"], accessesRemote: false, changesRepositoryState: false)
        let result = try await git.run(command, in: try lostObjectsRoot())
        guard result.succeeded else {
            throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString)
        }
        return result.standardOutputString.split(separator: "\n").map(String.init).filter { $0.hasPrefix(LostObjectsCommands.restoredObjectsTagPrefix) }
    }

    package func saveBlob(_ id: ObjectID, to url: URL) async throws {
        try await exportBlob(id.string, to: url, in: try lostObjectsRoot())
    }

    package static let lfsPointerPrefix = Data("version https://git-lfs.github.com/spec/v".utf8)

    package func materializedBlob(_ specifier: String, in root: URL) async throws -> Data {
        let blob = try await git.run(GitCommand(arguments: ["cat-file", "blob", specifier], accessesRemote: false, changesRepositoryState: false), in: root)
        guard blob.succeeded else {
            throw GitError.commandFailed(arguments: blob.arguments, status: blob.exitStatus, stderr: blob.standardErrorString)
        }
        let data = blob.standardOutput
        guard data.starts(with: Self.lfsPointerPrefix),
              let smudged = try? await git.run(GitCommand(arguments: ["lfs", "smudge"], accessesRemote: true, changesRepositoryState: false),
                                               in: root, standardInput: data, environment: [:]),
              smudged.succeeded, smudged.standardErrorString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return data }
        return smudged.standardOutput
    }

    package func exportBlob(_ specifier: String, to url: URL, in root: URL) async throws {
        var data = try await materializedBlob(specifier, in: root)
        let autocrlf = try await git.run(GitCommand(arguments: ["config", "--get", "core.autocrlf"], accessesRemote: false, changesRepositoryState: false), in: root)
        if autocrlf.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true" {
            let attributes = try await git.run(GitCommand(arguments: ["check-attr", "-z", "diff", "text", "crlf", "eol", "--", url.path],
                                                          accessesRemote: false, changesRepositoryState: false), in: root)
            let byName = attributes.succeeded ? LostObjectsCommands.binaryAccordingToAttributes(attributes.standardOutputString) : nil
            let binaryName = byName ?? LostObjectsCommands.binaryExtensions.contains { url.lastPathComponent.lowercased().hasSuffix($0) }
            if !binaryName && !LostObjectsCommands.isBinaryContent(data) {
                data = LostObjectsCommands.convertCrLfToWorktree(data)
            }
        }
        try data.write(to: url)
    }
}


package enum FixedPatchLines {
    private static let headerPrefixes = ["diff --git ", "diff --cc ", "index ", "--- ", "+++ ", "new file mode", "deleted file mode",
                                         "old mode", "new mode", "similarity index", "dissimilarity index", "rename from", "rename to",
                                         "copy from", "copy to", "Binary files "]

    package static func lines(_ text: String) -> [DiffLine] {
        var oldLine = 0, newLine = 0, inHunk = false
        var result: [DiffLine] = []
        let rows = text.components(separatedBy: "\n")
        for (index, raw) in (rows.last == "" ? rows.dropLast() : rows[...]).enumerated() {
            let id = String(index)
            if raw.hasPrefix("@@") {
                inHunk = true

                let parts = raw.split(separator: " ")
                if parts.count >= 3 {
                    oldLine = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    newLine = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                result.append(DiffLine(id: id, oldLineNumber: nil, newLineNumber: nil, kind: .hunk, text: raw))
            } else if raw.hasPrefix("diff ") {
                inHunk = false
                result.append(DiffLine(id: id, oldLineNumber: nil, newLineNumber: nil, kind: .header, text: raw))
            } else if inHunk {
                result.append(line(raw, id: id, old: &oldLine, new: &newLine))
            } else if headerPrefixes.contains(where: raw.hasPrefix) {
                result.append(DiffLine(id: id, oldLineNumber: nil, newLineNumber: nil, kind: .header, text: raw))
            } else {
                result.append(DiffLine(id: id, oldLineNumber: nil, newLineNumber: nil, kind: .context, text: raw))
            }
        }
        return result
    }

    private static func line(_ raw: String, id: String, old: inout Int, new: inout Int) -> DiffLine {
        if raw.hasPrefix("+") {
            defer { new += 1 }
            return DiffLine(id: id, oldLineNumber: nil, newLineNumber: new, kind: .addition, text: String(raw.dropFirst()))
        }
        if raw.hasPrefix("-") {
            defer { old += 1 }
            return DiffLine(id: id, oldLineNumber: old, newLineNumber: nil, kind: .deletion, text: String(raw.dropFirst()))
        }
        if raw.hasPrefix("\\") { return DiffLine(id: id, oldLineNumber: nil, newLineNumber: nil, kind: .context, text: raw) }
        defer { old += 1; new += 1 }

        return DiffLine(id: id, oldLineNumber: old, newLineNumber: new, kind: .context, text: raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw)
    }
}
