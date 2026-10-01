import Foundation
import GitExtensionsCore

package final class BlameCommit: Sendable, Equatable {
    package let objectID: ObjectID
    package let author: String
    package let authorMail: String
    package let authorTime: Date
    package let authorTimeZone: String
    package let committer: String
    package let committerMail: String
    package let committerTime: Date
    package let committerTimeZone: String
    package let summary: String
    package let fileName: String

    package init(objectID: ObjectID, author: String, authorMail: String, authorTime: Date, authorTimeZone: String,
                 committer: String, committerMail: String, committerTime: Date, committerTimeZone: String,
                 summary: String, fileName: String) {
        self.objectID = objectID
        self.author = author
        self.authorMail = authorMail
        self.authorTime = authorTime
        self.authorTimeZone = authorTimeZone
        self.committer = committer
        self.committerMail = committerMail
        self.committerTime = committerTime
        self.committerTimeZone = committerTimeZone
        self.summary = summary
        self.fileName = fileName
    }

    package func with(fileName: String) -> BlameCommit {
        BlameCommit(objectID: objectID, author: author, authorMail: authorMail, authorTime: authorTime, authorTimeZone: authorTimeZone,
                    committer: committer, committerMail: committerMail, committerTime: committerTime,
                    committerTimeZone: committerTimeZone, summary: summary, fileName: fileName)
    }

    package static func == (lhs: BlameCommit, rhs: BlameCommit) -> Bool { lhs === rhs }

    package func description(summary: String? = nil, dateFormatter: DateFormatter) -> String {
        var text = "Author: \(author)\nAuthor date: \(dateFormatter.string(from: authorTime))\n"
        if author != committer || authorTime != committerTime {
            text += "Committer: \(committer)\nCommit date: \(dateFormatter.string(from: committerTime))\n"
        }
        text += "Commit hash: \(objectID.shortString)\nSummary: \(summary ?? self.summary)\n\nFileName: \(fileName)"
        return text
    }
}

package struct BlameLine: Sendable {
    package let commit: BlameCommit
    package let finalLineNumber: Int
    package let originLineNumber: Int
    package let text: String
    package init(commit: BlameCommit, finalLineNumber: Int, originLineNumber: Int, text: String) {
        self.commit = commit
        self.finalLineNumber = finalLineNumber
        self.originLineNumber = originLineNumber
        self.text = text
    }
}


package struct BlameResult: Sendable {
    package let lines: [BlameLine]
    package init(lines: [BlameLine]) { self.lines = lines }
}


package struct BlameOptions: Equatable, Sendable {
    package var ignoreWhitespace = true
    package var detectCopyInFile = false
    package var detectCopyInAll = false

    package var histogramDiffAlgorithm = false
    package init(ignoreWhitespace: Bool = true, detectCopyInFile: Bool = false, detectCopyInAll: Bool = false, histogramDiffAlgorithm: Bool = false) {
        self.ignoreWhitespace = ignoreWhitespace
        self.detectCopyInFile = detectCopyInFile
        self.detectCopyInAll = detectCopyInAll
        self.histogramDiffAlgorithm = histogramDiffAlgorithm
    }
}

package protocol RepositoryBlameDataSource: Sendable {
    func loadBlameRevision(_ revision: ObjectID?) async throws -> Commit

    func blame(file: String, revision: ObjectID, encoding: RepositoryTextEncoding, options: BlameOptions) async throws -> BlameResult

    func originalLineInPreviousCommit(commit: ObjectID, parent: ObjectID?, file: String, line: Int, options: BlameOptions) async -> Int

    func actualParents(of commit: ObjectID) async -> [ObjectID]
    func actualParentsMap(_ commits: [ObjectID]) async -> [ObjectID: [ObjectID]]
}

package enum BlameCommands {
    package static func blame(file: String, revision: ObjectID, options: BlameOptions) -> GitCommand {
        var arguments = ["blame", "--porcelain"]
        if options.detectCopyInFile { arguments.append("-M") }
        if options.detectCopyInAll { arguments.append("-C") }
        if options.ignoreWhitespace { arguments.append("-w") }
        arguments += ["-l", revision.string, "--", file]
        return GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: false)
    }


    package static func previousRevisionDiff(parent: ObjectID, commit: ObjectID, file: String, options: BlameOptions) -> GitCommand {
        var arguments = ["diff", "--no-ext-diff", "-U0", "--diff-algorithm=\(options.histogramDiffAlgorithm ? "histogram" : "default")"]
        if options.detectCopyInFile { arguments.append("--find-renames") }
        if options.detectCopyInAll { arguments.append("--find-copies") }
        if options.ignoreWhitespace { arguments.append("--ignore-all-space") }
        arguments += [parent.string, commit.string, "--", file]
        return GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: false)
    }


    package static func parse(_ output: Data, encoding: RepositoryTextEncoding) -> BlameResult {
        var commits: [ObjectID: BlameCommit] = [:]
        var lines: [BlameLine] = []
        var hasHeader = false
        var objectID: ObjectID?
        var finalLine = -1, originLine = -1
        var author: String?, authorMail: String?, authorTime = Date.distantPast, authorTimeZone: String?
        var committer: String?, committerMail: String?, committerTime = Date.distantPast, committerTimeZone: String?
        var summary: String?, fileName: String?
        func reset() {
            hasHeader = false; objectID = nil; finalLine = -1; originLine = -1
            author = nil; authorMail = nil; authorTime = .distantPast; authorTimeZone = nil
            committer = nil; committerMail = nil; committerTime = .distantPast; committerTimeZone = nil
            summary = nil; fileName = nil
        }
        func text(_ bytes: Data.SubSequence) -> String { String(decoding: bytes, as: UTF8.self) }
        func time(_ value: String) -> Date { TimeInterval(value).map { Date(timeIntervalSince1970: $0) } ?? .distantPast }
        let contentEncoding = encoding == .automatic ? String.Encoding.utf8 : encoding.foundationEncoding

        for rawLine in output.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            var line = rawLine
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            if line.first == UInt8(ascii: "\t") {
                guard let id = objectID else { return BlameResult(lines: []) }
                let content = line.dropFirst()
                let lineText = String(data: Data(content), encoding: contentEncoding) ?? String(decoding: content, as: UTF8.self)
                let commit: BlameCommit
                if hasHeader {
                    if let known = commits[id] {
                        commit = fileName == known.fileName ? known : known.with(fileName: fileName ?? "")
                    } else {
                        commit = BlameCommit(objectID: id, author: author ?? "", authorMail: authorMail ?? "", authorTime: authorTime,
                                             authorTimeZone: authorTimeZone ?? "", committer: committer ?? "", committerMail: committerMail ?? "",
                                             committerTime: committerTime, committerTimeZone: committerTimeZone ?? "",
                                             summary: summary ?? "", fileName: fileName ?? "")
                        commits[id] = commit
                    }
                } else {
                    guard let known = commits[id] else { return BlameResult(lines: []) }
                    commit = known
                }
                lines.append(BlameLine(commit: commit, finalLineNumber: finalLine, originLineNumber: originLine, text: lineText))
                reset()
                continue
            }
            let string = text(line)

            let parts = string.split(separator: " ")
            if parts.count >= 3, let id = try? ObjectID.parse(String(parts[0])), let origin = Int(parts[1]), let final = Int(parts[2]) {
                objectID = id; originLine = origin; finalLine = final
                continue
            }
            func value(_ key: String) -> String? { string.hasPrefix(key + " ") ? String(string.dropFirst(key.count + 1)) : nil }
            if let v = value("author") { author = v; hasHeader = true }
            else if let v = value("author-mail") { authorMail = v; hasHeader = true }
            else if let v = value("author-time") { authorTime = time(v); hasHeader = true }
            else if let v = value("author-tz") { authorTimeZone = v; hasHeader = true }
            else if let v = value("committer") { committer = v; hasHeader = true }
            else if let v = value("committer-mail") { committerMail = v; hasHeader = true }
            else if let v = value("committer-time") { committerTime = time(v); hasHeader = true }
            else if let v = value("committer-tz") { committerTimeZone = v; hasHeader = true }
            else if let v = value("summary") { summary = v; hasHeader = true }
            else if let v = value("filename") { fileName = PatchPreviewParser.unquote(v); hasHeader = true }
        }
        return BlameResult(lines: lines)
    }


    package static func originalLine(inDiff diff: String, selectedLine: Int) -> Int {
        for chunk in diff.components(separatedBy: "\n@@").dropFirst().reversed() {
            let header = "@@" + (chunk.components(separatedBy: "\n").first ?? "")

            let parts = header.split(separator: " ")
            guard parts.count >= 4, parts[0] == "@@", parts[1].hasPrefix("-"), parts[2].hasPrefix("+"), parts[3].hasPrefix("@@") else { continue }
            func range(_ part: Substring) -> (start: Int, count: Int)? {
                let numbers = part.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
                guard let start = Int(numbers[0]) else { return nil }
                if numbers.count > 1 { return Int(numbers[1]).map { (start, $0) } }
                return (start, 1)
            }
            guard let previous = range(parts[1]), let current = range(parts[2]) else { continue }
            if current.start <= selectedLine {
                return max(previous.start, selectedLine - current.start + previous.start - current.count + previous.count)
            }
        }
        return selectedLine
    }
}

package enum BlameError: LocalizedError, Equatable {
    case failed(String)
    package var errorDescription: String? {
        switch self { case .failed(let message): message }
    }
}

extension GitRepositoryModule: RepositoryBlameDataSource {
    package func actualParentsMap(_ commits: [ObjectID]) async -> [ObjectID: [ObjectID]] {
        guard !commits.isEmpty, !Task.isCancelled, let repository = resolvedRepository else { return [:] }
        let command = GitCommand(arguments: ["rev-list", "--no-walk", "--parents", "--stdin"],
                                 accessesRemote: false, changesRepositoryState: false)
        guard let result = try? await git.run(command, in: repository.rootURL,
                                             standardInput: Data(commits.map(\.string).joined(separator: "\n").appending("\n").utf8)),
              result.succeeded, !Task.isCancelled else { return [:] }
        var parents: [ObjectID: [ObjectID]] = [:]
        for line in result.standardOutputString.split(separator: "\n") {
            let ids = line.split(separator: " ").compactMap { try? ObjectID.parse(String($0)) }
            if let id = ids.first { parents[id] = Array(ids.dropFirst()) }
        }
        return parents
    }
    package func loadBlameRevision(_ revision: ObjectID?) async throws -> Commit {
        let target: ObjectID
        if let revision { target = revision }
        else if let head = await resolveRevision("HEAD") { target = head }
        else { throw BlameError.failed("No committed revision is available to blame.") }


        return try await loadReflogRevision(target)
    }
    package func blame(file: String, revision: ObjectID, encoding: RepositoryTextEncoding, options: BlameOptions) async throws -> BlameResult {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        let command = BlameCommands.blame(file: file, revision: revision, options: options)
        let result = try await git.run(command, in: repository.rootURL)

        guard result.succeeded else {
            let message = result.standardErrorString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BlameError.failed(message.isEmpty ? "git \(command.arguments.joined(separator: " ")) failed (\(result.exitStatus))" : message)
        }
        let configured = encoding == .automatic ? (try? await configuredFileEncoding()) ?? nil : encoding
        return BlameCommands.parse(result.standardOutput, encoding: configured ?? .utf8)
    }

    package func originalLineInPreviousCommit(commit: ObjectID, parent: ObjectID?, file: String, line: Int, options: BlameOptions) async -> Int {
        guard let parent, let repository = resolvedRepository,
              let result = try? await git.run(BlameCommands.previousRevisionDiff(parent: parent, commit: commit, file: file, options: options), in: repository.rootURL)
        else { return line }
        return BlameCommands.originalLine(inDiff: result.standardOutputString, selectedLine: line)
    }

    package func actualParents(of commit: ObjectID) async -> [ObjectID] {
        guard let repository = resolvedRepository,
              let result = try? await git.run(GitCommand(arguments: ["rev-list", "--parents", "-n", "1", commit.string], accessesRemote: false,
                                                         changesRepositoryState: false), in: repository.rootURL),
              result.succeeded else { return [] }
        return result.standardOutputString.split(whereSeparator: \.isWhitespace).dropFirst().compactMap { try? ObjectID.parse(String($0)) }
    }
}
