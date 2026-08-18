import Foundation

struct GitLogRecord: Sendable {
    let objectID: String
    let parentIDs: [String]
    let authorDate: Date
    let commitDate: Date
    let authorName: String
    let authorEmail: String
    let committerName: String
    let committerEmail: String
    let body: String
}

struct GitRefRecord: Sendable {
    let objectID: String
    let fullName: String
    let peeledObjectID: String?
    let upstreamRemote: String?
    let upstreamRef: String?
    let upstreamTrack: String?
}

struct GitStatusRecord: Sendable {
    let path: String
    let oldPath: String?
    let indexStatus: Character
    let worktreeStatus: Character
    let isUntracked: Bool
    let isConflict: Bool
}

struct GitChangedPath: Sendable {
    let path: String
    let oldPath: String?
    let type: FileChangeType
}

struct GitTreeRecord: Sendable {
    let mode: String
    let objectType: String
    let objectID: String
    let byteCount: Int
    let path: String
}

struct GitWorktreeRecord: Sendable {
    let path: String
    let headID: String?
    let branchRef: String?
    let isBare: Bool
    let isDetached: Bool
    let isPrunable: Bool
}

struct GitStashRecord: Sendable {
    let selector: String
    let objectID: String
    let parentIDs: [String]
    let authorDate: Date
    let commitDate: Date
    let authorName: String
    let authorEmail: String
    let committerName: String
    let committerEmail: String
    let subject: String
}

enum GitOutputParser {
    static func parseLog(_ data: Data) throws -> [GitLogRecord] {
        let fields = nulFields(data)
        guard fields.count % 9 == 0 else {
            throw GitError.malformedOutput(command: "log", detail: "expected groups of 9 NUL-delimited fields, got \(fields.count)")
        }

        return try stride(from: 0, to: fields.count, by: 9).map { index in
            let objectID = fields[index]
            guard isObjectID(objectID),
                  let authorSeconds = TimeInterval(fields[index + 2]),
                  let commitSeconds = TimeInterval(fields[index + 3])
            else {
                throw GitError.malformedOutput(command: "log", detail: "invalid object ID or timestamp near record \(index / 9)")
            }
            return GitLogRecord(
                objectID: objectID,
                parentIDs: fields[index + 1].split(separator: " ").map(String.init),
                authorDate: Date(timeIntervalSince1970: authorSeconds),
                commitDate: Date(timeIntervalSince1970: commitSeconds),
                authorName: fields[index + 4],
                authorEmail: fields[index + 5],
                committerName: fields[index + 6],
                committerEmail: fields[index + 7],
                body: fields[index + 8].trimmingCharacters(in: .newlines)
            )
        }
    }

    static func parseRefs(_ data: Data) throws -> [GitRefRecord] {
        var fields = nulFields(data, trimRecordNewlines: true)
        if fields.last?.isEmpty == true { fields.removeLast() }
        guard fields.count % 6 == 0 else {
            throw GitError.malformedOutput(command: "for-each-ref", detail: "expected groups of 6 fields, got \(fields.count)")
        }

        return try stride(from: 0, to: fields.count, by: 6).map { index in
            guard isObjectID(fields[index]) else {
                throw GitError.malformedOutput(command: "for-each-ref", detail: "invalid object ID \(fields[index])")
            }
            return GitRefRecord(
                objectID: fields[index],
                fullName: fields[index + 1],
                peeledObjectID: nilIfEmpty(fields[index + 2]),
                upstreamRemote: nilIfEmpty(fields[index + 3]),
                upstreamRef: nilIfEmpty(fields[index + 4]),
                upstreamTrack: nilIfEmpty(fields[index + 5])
            )
        }
    }

    static func parsePorcelainV2(_ data: Data) throws -> [GitStatusRecord] {
        let records = rawNulFields(data)
        var result: [GitStatusRecord] = []
        var index = 0

        while index < records.count {
            let record = decode(records[index])
            index += 1
            guard !record.isEmpty else { continue }

            if record.hasPrefix("? ") {
                result.append(GitStatusRecord(path: String(record.dropFirst(2)), oldPath: nil, indexStatus: ".", worktreeStatus: "?", isUntracked: true, isConflict: false))
                continue
            }
            if record.hasPrefix("! ") { continue }

            let kind = record.first
            let maximumSplits: Int
            switch kind {
            case "2": maximumSplits = 9
            case "u": maximumSplits = 10
            default: maximumSplits = 8
            }
            let parts = record.split(separator: " ", maxSplits: maximumSplits, omittingEmptySubsequences: false)
            guard parts.count > maximumSplits, parts[1].count == 2 else {
                throw GitError.malformedOutput(command: "status --porcelain=2", detail: "invalid record \(record)")
            }
            let xy = parts[1]
            let path = String(parts[maximumSplits])
            var oldPath: String?
            if kind == "2" {
                guard index < records.count else {
                    throw GitError.malformedOutput(command: "status --porcelain=2", detail: "rename record has no source path")
                }
                oldPath = decode(records[index])
                index += 1
            }
            result.append(GitStatusRecord(
                path: path,
                oldPath: oldPath,
                indexStatus: xy.first ?? ".",
                worktreeStatus: xy.last ?? ".",
                isUntracked: false,
                isConflict: kind == "u"
            ))
        }
        return result
    }

    static func parseNameStatus(_ data: Data) throws -> [GitChangedPath] {
        let fields = nulFields(data)
        var result: [GitChangedPath] = []
        var index = 0
        while index < fields.count {
            let status = fields[index]
            index += 1
            guard let code = status.first else { continue }
            let type = changeType(code)
            if code == "R" || code == "C" {
                guard index + 1 < fields.count else {
                    throw GitError.malformedOutput(command: "diff --name-status", detail: "rename/copy is missing a path")
                }
                let oldPath = fields[index]
                let path = fields[index + 1]
                index += 2
                result.append(GitChangedPath(path: path, oldPath: oldPath, type: type))
            } else {
                guard index < fields.count else {
                    throw GitError.malformedOutput(command: "diff --name-status", detail: "status is missing a path")
                }
                result.append(GitChangedPath(path: fields[index], oldPath: nil, type: type))
                index += 1
            }
        }
        return result
    }

    static func parseNumstat(_ data: Data) -> [String: (Int, Int)] {
        let fields = nulFields(data)
        var result: [String: (Int, Int)] = [:]
        var index = 0
        while index < fields.count {
            let record = fields[index]
            index += 1
            let columns = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else { continue }
            let additions = Int(columns[0]) ?? 0
            let deletions = Int(columns[1]) ?? 0
            var path = String(columns[2])
            if path.isEmpty, index + 1 < fields.count {
                _ = fields[index]
                path = fields[index + 1]
                index += 2
            }
            result[path] = (additions, deletions)
        }
        return result
    }

    static func parseUnifiedDiff(_ data: Data, files: [ChangedFile]) -> [String: FileDiff] {
        let text = String(decoding: data, as: UTF8.self)
        let sections = splitDiffSections(text)
        var result: [String: FileDiff] = [:]
        for (file, section) in zip(files, sections) {
            result[file.id] = FileDiff(
                id: "diff:\(file.id)",
                fileID: file.id,
                lines: parseDiffLines(section, fileID: file.id)
            )
        }
        return result
    }

    static func parseTree(_ data: Data) throws -> [GitTreeRecord] {
        try nulFields(data).map { record in
            guard let tab = record.firstIndex(of: "\t") else {
                throw GitError.malformedOutput(command: "ls-tree", detail: "missing path separator")
            }
            let header = record[..<tab].split(separator: " ", omittingEmptySubsequences: true)
            guard header.count >= 3 else {
                throw GitError.malformedOutput(command: "ls-tree", detail: "invalid metadata \(record)")
            }
            return GitTreeRecord(
                mode: String(header[0]),
                objectType: String(header[1]),
                objectID: String(header[2]),
                byteCount: header.count > 3 ? Int(header[3]) ?? 0 : 0,
                path: String(record[record.index(after: tab)...])
            )
        }
    }

    static func parseIndexTree(_ data: Data) throws -> [GitTreeRecord] {
        try nulFields(data).compactMap { record in
            guard let tab = record.firstIndex(of: "\t") else {
                throw GitError.malformedOutput(command: "ls-files -s", detail: "missing path separator")
            }
            let header = record[..<tab].split(separator: " ")
            guard header.count == 3 else {
                throw GitError.malformedOutput(command: "ls-files -s", detail: "invalid metadata")
            }
            guard header[2] == "0" else { return nil }
            return GitTreeRecord(
                mode: String(header[0]),
                objectType: "blob",
                objectID: String(header[1]),
                byteCount: 0,
                path: String(record[record.index(after: tab)...])
            )
        }
    }

    static func parseWorktrees(_ data: Data) throws -> [GitWorktreeRecord] {
        let fields = rawNulFields(data).map(decode)
        var result: [GitWorktreeRecord] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []

        func finish() {
            guard let path = values["worktree"] else { return }
            result.append(GitWorktreeRecord(
                path: path,
                headID: values["HEAD"],
                branchRef: values["branch"],
                isBare: flags.contains("bare"),
                isDetached: flags.contains("detached"),
                isPrunable: values["prunable"] != nil || flags.contains("prunable")
            ))
            values.removeAll(keepingCapacity: true)
            flags.removeAll(keepingCapacity: true)
        }

        for field in fields {
            if field.isEmpty {
                finish()
                continue
            }
            if let space = field.firstIndex(of: " ") {
                values[String(field[..<space])] = String(field[field.index(after: space)...])
            } else {
                flags.insert(field)
            }
        }
        finish()
        return result
    }

    static func parseStashes(_ data: Data) throws -> [GitStashRecord] {
        let fields = nulFields(data)
        guard fields.count % 10 == 0 else {
            throw GitError.malformedOutput(command: "stash list", detail: "expected groups of 10 fields, got \(fields.count)")
        }
        return try stride(from: 0, to: fields.count, by: 10).map { index in
            guard isObjectID(fields[index + 1]),
                  let authorSeconds = TimeInterval(fields[index + 3]),
                  let commitSeconds = TimeInterval(fields[index + 4])
            else {
                throw GitError.malformedOutput(command: "stash list", detail: "invalid object ID or timestamp")
            }
            return GitStashRecord(
                selector: fields[index],
                objectID: fields[index + 1],
                parentIDs: fields[index + 2].split(separator: " ").map(String.init),
                authorDate: Date(timeIntervalSince1970: authorSeconds),
                commitDate: Date(timeIntervalSince1970: commitSeconds),
                authorName: fields[index + 5],
                authorEmail: fields[index + 6],
                committerName: fields[index + 7],
                committerEmail: fields[index + 8],
                subject: fields[index + 9]
            )
        }
    }

    static func fileChangeType(for status: Character) -> FileChangeType {
        changeType(status)
    }

    private static func splitDiffSections(_ text: String) -> [String] {
        let marker = "diff --git "
        guard text.hasPrefix(marker) else { return text.isEmpty ? [] : [text] }
        var sections: [String] = []
        var start = text.startIndex
        while let next = text.range(of: "\n\(marker)", range: text.index(after: start)..<text.endIndex) {
            sections.append(String(text[start..<next.lowerBound]))
            start = text.index(after: next.lowerBound)
        }
        sections.append(String(text[start...]))
        return sections
    }

    private static func parseDiffLines(_ section: String, fileID: String) -> [DiffLine] {
        var oldLine: Int?
        var newLine: Int?
        return section.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, rawLine in
            let line = String(rawLine)
            let kind: DiffLine.Kind
            let text: String
            let oldNumber: Int?
            let newNumber: Int?

            if line.hasPrefix("@@") {
                let starts = hunkStarts(line)
                oldLine = starts.old
                newLine = starts.new
                kind = .hunk
                text = line
                oldNumber = nil
                newNumber = nil
            } else if line.hasPrefix("+") && !line.hasPrefix("+++") {
                kind = .addition
                text = String(line.dropFirst())
                oldNumber = nil
                newNumber = newLine
                if let value = newLine { newLine = value + 1 }
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                kind = .deletion
                text = String(line.dropFirst())
                oldNumber = oldLine
                newNumber = nil
                if let value = oldLine { oldLine = value + 1 }
            } else if line.hasPrefix(" "), oldLine != nil || newLine != nil {
                kind = .context
                text = String(line.dropFirst())
                oldNumber = oldLine
                newNumber = newLine
                if let value = oldLine { oldLine = value + 1 }
                if let value = newLine { newLine = value + 1 }
            } else {
                kind = .header
                text = line
                oldNumber = nil
                newNumber = nil
            }

            return DiffLine(id: "\(fileID):\(index)", oldLineNumber: oldNumber, newLineNumber: newNumber, kind: kind, text: text)
        }
    }

    private static func hunkStarts(_ line: String) -> (old: Int?, new: Int?) {
        let components = line.split(separator: " ")
        guard components.count >= 3 else { return (nil, nil) }
        func start(_ field: Substring) -> Int? {
            let value = field.dropFirst().split(separator: ",", maxSplits: 1).first
            return value.flatMap { Int($0) }
        }
        return (start(components[1]), start(components[2]))
    }

    private static func changeType(_ status: Character) -> FileChangeType {
        switch status {
        case "A", "?": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        default: .modified
        }
    }

    private static func rawNulFields(_ data: Data) -> [Data] {
        var result: [Data] = [UInt8](data)
            .split(separator: 0, omittingEmptySubsequences: false)
            .map { Data($0) }
        if result.last?.isEmpty == true { result.removeLast() }
        return result
    }

    private static func nulFields(_ data: Data, trimRecordNewlines: Bool = false) -> [String] {
        rawNulFields(data).map { field in
            let decoded = decode(field)
            return trimRecordNewlines ? decoded.trimmingCharacters(in: .newlines) : decoded
        }
    }

    private static func decode(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    private static func nilIfEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private static func isObjectID(_ value: String) -> Bool {
        (40...64).contains(value.count) && value.allSatisfy(\.isHexDigit)
    }
}
