import Foundation
import GitExtensionsCore


package enum FileStatusGroupKind: Hashable, Sendable {
    case diff, diffA, diffB, combined, range, grep
}


package struct FileStatusGroup: Hashable, Sendable, Identifiable {
    package let id: String

    package let first: RevisionID?
    package let second: RevisionID
    package let summary: String
    package let kind: FileStatusGroupKind
    package var files: [ChangedFile]

    package init(first: RevisionID?, second: RevisionID, summary: String, kind: FileStatusGroupKind = .diff, files: [ChangedFile]) {
        self.id = "\(kind):\(first?.description ?? "-"):\(second.description):\(summary)"
        self.first = first
        self.second = second
        self.summary = summary
        self.kind = kind
        self.files = files
    }

    package var isGrep: Bool { kind == .grep }
}


package struct FileStatusDiffRequest: Sendable {
    package var revisions: [Commit]
    package var headID: ObjectID?
    package var allowMultiDiff: Bool
    package var showDiffForAllParents: Bool
    package var showSkipWorktreeFiles: Bool
    package var showUntrackedFiles: Bool

    package var grepArguments: [String]
    package var grepText: String
    package var fileTreeMode: Bool

    package var includeDiffs = true
    package var grepSettings = GitGrepOptions()

    package init(revisions: [Commit], headID: ObjectID?, allowMultiDiff: Bool = true, showDiffForAllParents: Bool = true,
                 showSkipWorktreeFiles: Bool = false, showUntrackedFiles: Bool = true, grepArguments: [String] = [],
                 grepText: String = "", fileTreeMode: Bool = false) {
        self.revisions = revisions
        self.headID = headID
        self.allowMultiDiff = allowMultiDiff
        self.showDiffForAllParents = showDiffForAllParents
        self.showSkipWorktreeFiles = showSkipWorktreeFiles
        self.showUntrackedFiles = showUntrackedFiles
        self.grepArguments = grepArguments
        self.grepText = grepText
        self.fileTreeMode = fileTreeMode
    }
}


package struct GitGrepOptions: Codable, Equatable, Sendable {
    package var userArguments = ""
    package var ignoreCase = false
    package var matchWholeWord = false
    package init(userArguments: String = "", ignoreCase: Bool = false, matchWholeWord: Bool = false) {
        self.userArguments = userArguments
        self.ignoreCase = ignoreCase
        self.matchWholeWord = matchWholeWord
    }
}


package protocol RepositoryFileStatusDataSource: Sendable {

    func calculateFileStatus(_ request: FileStatusDiffRequest, describe: @escaping @Sendable (ObjectID) -> String) async throws -> [FileStatusGroup]

    func loadFileStatusDiff(group: FileStatusGroup, file: ChangedFile, options: FileDiffOptions, grep: GitGrepOptions) async throws -> FileStatusContent

    func loadFileData(path: String, at revision: RevisionID) async throws -> Data

    func exportFile(path: String, at revision: RevisionID, to url: URL) async throws

    func resetFiles(to revision: RevisionID, items: [ChangedFile], resetAndDelete: Bool) async throws -> String

    func setSkipWorktree(_ paths: [String], _ value: Bool) async throws
    func setAssumeUnchanged(_ paths: [String], _ value: Bool) async throws

    func stopTracking(_ path: String) async throws

    func move(from oldName: String, to newName: String, isFolder: Bool) async throws

    func cherryPickChanges(group: FileStatusGroup, file: ChangedFile) async throws -> FileStatusApplyResult

    func applyLinePatch(_ kind: FileStatusLinePatchKind, file: ChangedFile, diff: FileDiff, lineIDs: Set<String>) async throws -> FileStatusApplyResult

    func workingTreeDiscoveryFiles(ignored: Bool, assumeUnchanged: Bool, skipWorktree: Bool) async throws -> [ChangedFile]

    func isDifftasticEnabled() async -> Bool

    func submoduleCommit(path: String, at revision: RevisionID?) async throws -> ObjectID?

    func fileStatusSubmodule(group: FileStatusGroup, file: ChangedFile) async throws -> FileStatusSubmodule?

    @discardableResult func deleteFiles(_ items: [ChangedFile]) async throws -> Bool

    func openDifftool(first: RevisionID?, second: RevisionID?, path: String, oldPath: String?, isTracked: Bool, customTool: String?, externalCommand: String?) async throws

    func openDifftool(firstBlob: String, secondBlob: String, customTool: String?, externalCommand: String?) async throws

    func blobSpecifier(path: String, at revision: RevisionID) async throws -> String?

    func loadDiffTools() async throws -> [String]
}

package enum FileStatusLinePatchKind: Hashable, Sendable {
    case stage
    case unstage
    case resetWorkTree
    case resetIndex
    case applyToWorkTree
    case revertToWorkTree
}

package struct FileStatusApplyResult: Sendable {
    package let succeeded: Bool
    package let output: String
    package let patch: String
}



package struct FileStatusPartialMutationError: LocalizedError {
    package let message: String
    package var errorDescription: String? { message }
}


package enum FileStatusContent: Sendable {
    case diff(FileDiff?)
    case text(String)
}

package struct FileStatusSubmodule: Hashable, Sendable {
    package let first: ObjectID?
    package let second: ObjectID?
    package var state: SubmoduleTreeItem.CommitState = .modified
    package var added: Int?
    package var removed: Int?
    package let isDirty: Bool

    package var countSuffix: String {
        guard let added, let removed, added != 0 || removed != 0 else { return "" }
        return " (+\(added)-\(removed))"
    }
}

package enum FileStatusCommands {

    package static func submoduleChanges(_ patch: String) -> FileStatusSubmodule? {
        var first: ObjectID?, second: ObjectID?
        var dirty = false
        for line in patch.split(separator: "\n") {
            if line.hasPrefix("-Subproject commit ") { first = try? ObjectID.parse(String(line.dropFirst(19))) }
            if line.hasPrefix("+Subproject commit ") {
                var value = String(line.dropFirst(19))
                dirty = value.hasSuffix("-dirty")
                if dirty { value.removeLast(6) }
                second = try? ObjectID.parse(value)
            }
        }
        guard first != nil || second != nil else { return nil }
        return FileStatusSubmodule(first: first, second: second, isDirty: dirty)
    }


    package static func interactivePatch(path: String, stage: Bool) -> GitCommand {
        GitCommand(arguments: (stage ? ["add", "--patch"] : ["checkout", "-p"]) + ["--", path],
                   accessesRemote: false, changesRepositoryState: true)
    }

    package static func status(showUntracked: Bool, showIgnored: Bool = false) -> GitCommand {
        var arguments = ["--no-optional-locks", "status", "--porcelain=2", "-z"]
        if !showUntracked { arguments.append("--untracked-files=no") }
        if showIgnored { arguments.append("--ignored") }
        return GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: false)
    }

    package static let listFilesVerbose = GitCommand(arguments: ["ls-files", "-v", "-z"], accessesRemote: false, changesRepositoryState: false)


    package static func diff(first: RevisionID?, second: RevisionID?) -> GitCommand {
        GitCommand(arguments: ["diff", "--no-ext-diff", "--find-renames", "--find-copies", "--raw", "-z"] + revisionArguments(first: first, second: second),
                   accessesRemote: false, changesRepositoryState: false)
    }


    package static func revisionArguments(first: RevisionID?, second: RevisionID?) -> [String] {
        func option(_ revision: RevisionID?) -> String? {
            switch revision {
            case .workingDirectory?, nil: return nil
            case .index?: return "--cached"
            case .object(let id)?: return id.string
            }
        }
        var firstOption = option(first)
        var secondOption = option(second)
        var extra: [String] = []
        if firstOption != secondOption, firstOption == nil || (firstOption == "--cached" && secondOption != nil) {
            extra.append("-R")
        }
        if (firstOption == nil && secondOption == "--cached") || (firstOption == "--cached" && secondOption == nil) {
            firstOption = nil
            secondOption = nil
        }
        if secondOption == "--cached" {
            extra.append("--cached")
            secondOption = nil
        }
        return extra + [firstOption, secondOption].compactMap { $0 }
    }

    package static func combinedDiffFiles(_ merge: ObjectID) -> GitCommand {
        GitCommand(arguments: ["diff-tree", "--name-only", "-z", "--cc", "--no-commit-id", merge.string], accessesRemote: false, changesRepositoryState: false)
    }

    package static func combinedDiff(_ merge: ObjectID, path: String, options: FileDiffOptions) -> GitCommand {
        GitCommand(arguments: ["diff-tree"] + options.combinedDiffArguments + ["--no-commit-id"] + options.gitArguments + [merge.string, "--", path],
                   accessesRemote: false, changesRepositoryState: false)
    }

    package static func tree(_ revision: String) -> GitCommand {
        GitCommand(arguments: ["ls-tree", "-r", "-z", "--full-tree", revision], accessesRemote: false, changesRepositoryState: false)
    }

    package static let indexTree = GitCommand(arguments: ["ls-files", "-s", "-z"], accessesRemote: false, changesRepositoryState: false)

    package static func mergeBase(_ a: ObjectID, _ b: ObjectID) -> GitCommand {
        GitCommand(arguments: ["merge-base", a.string, b.string], accessesRemote: false, changesRepositoryState: false)
    }


    package static func rangeCount(_ first: String, _ second: String) -> GitCommand {
        GitCommand(arguments: ["rev-list", "\(first)...\(second)", "--count", "--left-right"], accessesRemote: false, changesRepositoryState: false)
    }

    package static func rangeDiff(_ first: String, _ second: String, path: String?) -> GitCommand {
        GitCommand(arguments: ["range-diff", "--no-color", "\(first)...\(second)"] + (path.map { ["--", $0] } ?? []),
                   accessesRemote: false, changesRepositoryState: false)
    }


    package static func grepFiles(_ arguments: [String], revision: RevisionID, options: GitGrepOptions) throws -> GitCommand {
        var command = ["grep", "--files-with-matches", "-z"]
        command += try userArguments(options)
        command += arguments
        command += revisionArgument(revision)
        command.append("--")
        return GitCommand(arguments: command, accessesRemote: false, changesRepositoryState: false)
    }



    package static func grepFile(_ arguments: [String], revision: RevisionID, path: String, options: GitGrepOptions,
                                 viewer: FileDiffOptions = FileDiffOptions()) throws -> GitCommand {
        var command = ["grep", "--line-number", "--show-function", "--no-color", "-h",
                       "--context=\(viewer.showsEntireFile ? 100_000 : viewer.contextLines)"]
        if viewer.treatsAllFilesAsText { command.append("--text") }
        command += try userArguments(options)
        command += arguments
        command += revisionArgument(revision)
        command += ["--", path]
        return GitCommand(arguments: command, accessesRemote: false, changesRepositoryState: false)
    }

    private static func userArguments(_ options: GitGrepOptions) throws -> [String] {
        var result = try ScriptExecution.arguments(options.userArguments)
        if options.ignoreCase { result.append("--ignore-case") }
        if options.matchWholeWord { result.append("--word-regexp") }
        return result
    }

    private static func revisionArgument(_ revision: RevisionID) -> [String] {
        switch revision {
        case .object(let id): [id.string]
        case .index: ["--cached"]
        case .workingDirectory: []
        }
    }


    package static func grepArguments(for text: String) throws -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let usesExpressionOption = (try? NSRegularExpression(pattern: #"(^|\s)-e(\s|\s+['"])"#))?
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        return usesExpressionOption ? try ScriptExecution.arguments(text) : ["-e", text]
    }


    package static func parseStatus(_ output: String) -> [ChangedFile] {
        var result: [ChangedFile] = []
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < records.count {
            let line = records[index]
            index += 1
            let characters = Array(line)
            guard characters.count > 2, characters[1] == " ", characters[0] != "#" else { continue }
            let type = characters[0]
            if type == "?" || type == "!" {
                var file = changedFile(path: String(line.dropFirst(2)), oldPath: nil, status: "A", staged: .workTree)
                file.isTracked = false
                file.isIgnored = type == "!"
                result.append(file)
                continue
            }
            guard ["1", "2", "u"].contains(type) else { continue }
            let fields = line.split(separator: " ", maxSplits: type == "1" ? 8 : type == "2" ? 9 : 10, omittingEmptySubsequences: false).map(String.init)
            let xy = Array(fields.count > 1 ? fields[1] : "..")
            guard xy.count == 2 else { continue }
            let submodule = fields.count > 2 ? Array(fields[2]) : Array("N...")
            var path: String
            var oldPath: String?
            var score: String?
            switch type {
            case "1":
                guard fields.count == 9 else { continue }
                path = fields[8]
            case "2":
                guard fields.count == 10 else { continue }
                score = String(fields[8].drop { !$0.isNumber })
                path = fields[9]
                if index < records.count { oldPath = records[index]; index += 1 }
            default:
                guard fields.count == 11 else { continue }
                path = fields[10]
            }
            func add(_ status: Character, staged: FileStagedStatus) {
                guard status != "." else { return }
                var file = changedFile(path: path, oldPath: oldPath, status: status, staged: staged)
                file.renameCopyPercentage = score
                if submodule.first == "S" {
                    file.isSubmodule = true
                    if staged == .workTree, submodule.count == 4 {
                        file.submoduleCommitChanged = submodule[1] == "C"
                        file.submoduleIsDirty = submodule[2] == "M" || submodule[3] == "U"
                    }
                }
                result.append(file)
            }

            if type != "u" || xy[0] != "U" || xy[1] != "U" { add(xy[0], staged: .index) }
            add(xy[1], staged: .workTree)
        }
        return result
    }


    package static func parseRawDiff(_ output: String, staged: FileStagedStatus) -> [ChangedFile] {
        var result: [ChangedFile] = []
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < records.count {
            let status = records[index]
            index += 1
            guard status.hasPrefix(":"), status.count >= 15, index < records.count else { continue }
            let fields = status.dropFirst().split(separator: " ").map(String.init)
            guard fields.count >= 5, let x = fields[4].first else { continue }
            if staged == .workTree && x == "U" { index += 1; continue }
            var path = records[index]
            index += 1
            var oldPath: String?
            var score: String?
            if x == "R" || x == "C" {
                score = String(fields[4].dropFirst())
                oldPath = path
                if index < records.count { path = records[index]; index += 1 }
            }
            var file = changedFile(path: path, oldPath: oldPath, status: x, staged: staged)
            file.renameCopyPercentage = score
            file.isSubmodule = fields[0] == "160000" || fields[1] == "160000"
            result.append(file)
        }
        return result
    }


    package static func parseTree(_ output: String) -> [ChangedFile] {
        output.split(separator: "\0", omittingEmptySubsequences: true).compactMap { record in
            guard let tab = record.firstIndex(of: "\t") else { return nil }
            let meta = record[..<tab].split(separator: " ")
            let path = String(record[record.index(after: tab)...])
            var file = changedFile(path: path, oldPath: nil, status: "M", staged: .unset)
            file.isUnchanged = true
            file.isSubmodule = meta.count > 1 && meta[1] == "commit"
            return file
        }
    }


    package static func parseIndexTree(_ output: String) -> [ChangedFile] {
        var seen = Set<String>()
        return output.split(separator: "\0", omittingEmptySubsequences: true).compactMap { record in
            guard let tab = record.firstIndex(of: "\t") else { return nil }
            let path = String(record[record.index(after: tab)...])
            guard seen.insert(path).inserted else { return nil }
            var file = changedFile(path: path, oldPath: nil, status: "M", staged: .unset)
            file.isUnchanged = true
            file.isSubmodule = record.hasPrefix("160000")
            return file
        }
    }


    package static func parseListFilesVerbose(_ output: String, skipWorktree: Bool, assumeUnchanged: Bool) -> [ChangedFile] {
        output.split(separator: "\0", omittingEmptySubsequences: true).compactMap { line in
            guard let status = line.first, let space = line.firstIndex(of: " ") else { return nil }
            let path = String(line[line.index(after: space)...])
            let isAssume = status.isLowercase
            let isSkip = status == "S" || (status == "s" && !assumeUnchanged)
            guard (assumeUnchanged && isAssume) || (skipWorktree && isSkip) else { return nil }
            var file = changedFile(path: path, oldPath: nil, status: "M", staged: .unset)
            file.isUnchanged = true
            file.isAssumeUnchanged = assumeUnchanged && isAssume
            file.isSkipWorktree = skipWorktree && isSkip
            return file
        }
    }



    package static func parseGrepFile(_ output: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        var pendingSeparator = false
        var skipNextSeparator = false
        for line in output.components(separatedBy: "\n") {
            if line == "--" {
                if !skipNextSeparator && !lines.isEmpty { pendingSeparator = true }
                continue
            }
            let digits = line.prefix { $0.isNumber }
            guard !digits.isEmpty, let number = Int(digits), digits.endIndex < line.endIndex else {

                if !line.isEmpty { lines.append(DiffLine(id: String(lines.count), oldLineNumber: nil, newLineNumber: nil, kind: .context, text: line)) }
                pendingSeparator = false
                continue
            }
            let kind = line[digits.endIndex]
            let text = String(line[line.index(after: digits.endIndex)...])
            skipNextSeparator = kind == "="
            if pendingSeparator && !skipNextSeparator {
                lines.append(DiffLine(id: String(lines.count), oldLineNumber: nil, newLineNumber: nil, kind: .hunk, text: "--"))
            }
            pendingSeparator = false
            let lineKind: DiffLine.Kind = kind == "=" ? .hunk : kind == ":" ? .addition : .context
            lines.append(DiffLine(id: String(lines.count), oldLineNumber: nil, newLineNumber: number, kind: lineKind, text: text))
        }
        return lines
    }


    package static func parseGrepFiles(_ output: String, revision: RevisionID, grepText: String) -> [ChangedFile] {
        output.split(separator: "\0", omittingEmptySubsequences: true).map { entry in
            var path = String(entry)
            if case .object(let id) = revision, path.hasPrefix(id.string + ":") { path = String(path.dropFirst(id.string.count + 1)) }
            var file = changedFile(path: path, oldPath: nil, status: "M", staged: .unset)
            file.isUnchanged = true
            file.grepString = grepText
            return file
        }
    }


    package static func parseRangeCount(_ output: String) -> (Int?, Int?) {
        let counts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t").map { Int($0) }
        return counts.count == 2 ? (counts[0], counts[1]) : (nil, nil)
    }


    package static func changedFile(path: String, oldPath: String?, status: Character, staged: FileStagedStatus) -> ChangedFile {
        let type: FileChangeType = switch status {
        case "A", "?", "!": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        default: .modified
        }
        var file = ChangedFile(id: "\(staged.rawValue):\(oldPath.map { $0 + "\u{0}" } ?? "")\(path)", path: path, oldPath: oldPath,
                               changeType: type, additions: 0, deletions: 0)
        file.staged = staged
        file.isConflict = status == "U"
        file.isTypeChanged = status == "T"
        return file
    }
}


package struct FileStatusDiffCalculator {
    package var diffFiles: (_ first: RevisionID?, _ second: RevisionID, _ parentToSecond: ObjectID?) async throws -> [ChangedFile]
    package var treeFiles: (_ revision: RevisionID) async throws -> [ChangedFile]
    package var combinedDiffFiles: (_ merge: ObjectID) async throws -> [ChangedFile]
    package var mergeBase: (_ a: ObjectID, _ b: ObjectID) async throws -> ObjectID?
    package var rangeCount: (_ first: ObjectID, _ second: ObjectID) async throws -> (Int?, Int?)
    package var grepFiles: (_ revision: RevisionID, _ arguments: [String], _ text: String) async throws -> [ChangedFile]
    package var describe: (ObjectID) -> String

    package static let diffWithParent = "Diff with A: "

    private func describe(_ revision: RevisionID) -> String {
        switch revision {
        case .object(let id): describe(id)
        case .workingDirectory: "Working directory"
        case .index: "Commit index"
        }
    }


    package static func stagedStatus(first: RevisionID?, second: RevisionID, parentToSecond: ObjectID?) -> FileStagedStatus {
        if first == .index && second == .workingDirectory { return .workTree }
        if second == .index, let parentToSecond, first == .object(parentToSecond) { return .index }
        if case .object = first, case .object = second { return .none }
        return .unknown
    }

    package func calculate(_ request: FileStatusDiffRequest) async throws -> [FileStatusGroup] {
        guard let selected = request.revisions.first else { return [] }
        var groups: [FileStatusGroup] = []
        if request.includeDiffs && !request.fileTreeMode {
            groups = try await calculateDiffs(request, selected: selected)
        }
        if !request.grepArguments.isEmpty || request.fileTreeMode {
            let files = request.grepArguments.isEmpty
                ? try await treeFiles(selected.id)
                : try await grepFiles(selected.id, request.grepArguments, request.grepText)
            groups.append(FileStatusGroup(first: nil, second: selected.id, summary: "grep: \(Self.grepSummary(request)) \(describe(selected.id))",
                                          kind: .grep, files: files))
        }
        return groups
    }


    static func grepSummary(_ request: FileStatusDiffRequest) -> String {
        if request.grepArguments.count == 2, request.grepArguments[0] == "-e" { return "-e \"\(request.grepArguments[1])\"" }
        return request.grepArguments.isEmpty ? "" : request.grepText
    }

    private func calculateDiffs(_ request: FileStatusDiffRequest, selected: Commit) async throws -> [FileStatusGroup] {
        var groups: [FileStatusGroup] = []
        let revisions = request.revisions
        if revisions.count == 1 {
            let parents = Self.parents(of: selected, headID: request.headID)
            if !parents.isEmpty {
                let count = request.showDiffForAllParents ? parents.count : 1
                for parent in parents.prefix(count) {

                    if count == 3, describe(parent).contains(": untracked files on ") { continue }
                    let files = try await diffFiles(parent, selected.id, parents.first?.objectID)
                    groups.append(FileStatusGroup(first: parent, second: selected.id,
                                                  summary: Self.diffWithParent + describe(parent), files: files))
                }
            } else {
                var files = try await treeFiles(selected.id)
                for index in files.indices {
                    files[index].isUnchanged = false
                    files[index].changeType = .added
                }
                groups.append(FileStatusGroup(first: nil, second: selected.id, summary: describe(selected.id), files: files))
            }
            if selected.parentIDs.count > 1, request.showDiffForAllParents, let merge = selected.objectID {
                let conflicts = try await combinedDiffFiles(merge)
                if !conflicts.isEmpty {
                    groups.append(FileStatusGroup(first: nil, second: selected.id, summary: "Combined diff", kind: .combined, files: conflicts))
                }
            }
            return groups
        }

        let maxMultiCompare = 4
        let firstRevision = request.showDiffForAllParents && revisions.count == maxMultiCompare ? revisions[2] : revisions[revisions.count - 1]
        let allAToB = try await diffFiles(firstRevision.id, selected.id, Self.parents(of: selected, headID: request.headID).first?.objectID)
        groups.append(FileStatusGroup(first: firstRevision.id, second: selected.id,
                                      summary: Self.diffWithParent + describe(firstRevision.id), files: allAToB))
        guard request.showDiffForAllParents, revisions.count <= maxMultiCompare, request.allowMultiDiff else { return groups }

        func headOrSelf(_ commit: Commit) -> ObjectID? { commit.isArtificial ? request.headID : commit.objectID }
        func base(_ a: ObjectID?, _ b: ObjectID?) async throws -> ObjectID? {
            guard let a, let b, a != b else { return nil }
            return try await mergeBase(a, b)
        }
        let firstHead = headOrSelf(firstRevision)
        let selectedHead = headOrSelf(selected)
        var baseID: ObjectID?
        if revisions.count != 3 {
            baseID = try await base(firstHead, selectedHead)
        } else if let middle = revisions[1].objectID,
                  try await base(firstHead, middle) == middle, try await base(selectedHead, middle) == middle {
            baseID = middle
        }
        if let current = baseID {
            if revisions.count < 4 {
                if current == firstHead || current == selectedHead { baseID = nil }
            } else {
                var isRange = false
                if try await base(headOrSelf(revisions[3]), firstHead) == revisions[3].objectID,
                   try await base(headOrSelf(revisions[1]), selectedHead) == revisions[1].objectID {
                    isRange = true
                }
                if !isRange { baseID = nil }
            }
        }
        guard let baseID else {
            for revision in revisions where revision.id != firstRevision.id && revision.id != selected.id {
                let files = try await diffFiles(revision.id, selected.id, Self.parents(of: selected, headID: request.headID).first?.objectID)
                groups.append(FileStatusGroup(first: revision.id, second: selected.id,
                                              summary: Self.diffWithParent + describe(revision.id), files: files))
            }
            return groups
        }

        let allBaseToB = try await diffFiles(.object(baseID), selected.id, Self.parents(of: selected, headID: request.headID).first?.objectID)
        let allBaseToA = try await diffFiles(.object(baseID), firstRevision.id, Self.parents(of: firstRevision, headID: request.headID).first?.objectID)
        func key(_ file: ChangedFile) -> String { file.path }
        let aToBExceptExactRenameCopy = Set(allAToB.filter { !(($0.changeType == .renamed || $0.changeType == .copied) && $0.renameCopyPercentage == "100") }.map(key))
        let baseToB = Set(allBaseToB.map(key))
        let baseToA = Set(allBaseToA.map(key))
        let same = baseToB.intersection(baseToA).subtracting(aToBExceptExactRenameCopy)
        let onlyA = baseToA.subtracting(baseToB)
        let onlyB = baseToB.subtracting(baseToA)
        func mark(_ files: [ChangedFile]) -> [ChangedFile] {
            files.map { file in
                var file = file
                file.diffStatus = same.contains(key(file)) ? .same : onlyA.contains(key(file)) ? .onlyA : onlyB.contains(key(file)) ? .onlyB : .unequal
                return file
            }
        }
        groups[0].files = mark(allAToB)
        groups.append(FileStatusGroup(first: .object(baseID), second: selected.id, summary: "Diff BASE with B \(describe(selected.id))",
                                      kind: .diffB, files: mark(allBaseToB)))
        groups.append(FileStatusGroup(first: .object(baseID), second: firstRevision.id, summary: "Diff BASE with A \(describe(firstRevision.id))",
                                      kind: .diffA, files: mark(allBaseToA)))
        if let firstHead, let selectedHead {
            let (left, right) = try await rangeCount(firstHead, selectedHead)
            let description = "Range diff \(left ?? -1)↓ \(right ?? -1)↑ BASE \(describe(baseID))"
            var item = ChangedFile(id: "range:\(description)", path: description, oldPath: nil, changeType: .modified, additions: 0, deletions: 0)
            item.isRangeDiff = true
            item.isUnchanged = true
            item.rangeDiffFirst = firstHead
            item.rangeDiffSecond = selectedHead
            groups.insert(FileStatusGroup(first: firstRevision.id, second: selected.id, summary: description, kind: .range, files: [item]), at: 1)
        }
        return groups
    }
}

extension FileStatusDiffCalculator {

    package static func parents(of commit: Commit, headID: ObjectID?) -> [RevisionID] {
        switch commit.kind {
        case .workingDirectory: [.index]
        case .index: headID.map { [.object($0)] } ?? []
        case .revision: commit.parentIDs.map(RevisionID.object)
        }
    }
}
