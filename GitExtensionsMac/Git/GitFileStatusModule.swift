import Foundation
import GitExtensionsCore



extension FileStatusCommands {

    package static func validateMove(oldName: String, newName: String) -> Bool {
        !oldName.trimmingCharacters(in: .whitespaces).isEmpty && !newName.trimmingCharacters(in: .whitespaces).isEmpty && oldName != newName
    }
}

extension GitRepositoryModule: RepositoryFileStatusDataSource {
    private func fileStatusRoot() throws -> URL {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        return repository.rootURL
    }

    private func run(_ command: GitCommand, input: Data? = nil) async throws -> GitCommandResult {
        try await git.run(command, in: try fileStatusRoot(), standardInput: input)
    }

    private func runChecked(_ arguments: [String], changes: Bool = true, input: Data? = nil) async throws -> GitCommandResult {
        let result = try await run(GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: changes), input: input)
        guard result.succeeded else {
            throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString)
        }
        return result
    }


    private static func errorItem(_ message: String) -> ChangedFile {
        var file = ChangedFile(id: "error:\(message)", path: message.trimmingCharacters(in: .whitespacesAndNewlines),
                               oldPath: nil, changeType: .modified, additions: 0, deletions: 0)
        file.isStatusOnly = true
        file.isUnchanged = true
        return file
    }


    private func workingDirectoryStatus(showUntracked: Bool, showSkipWorktree: Bool) async throws -> [ChangedFile] {
        let result = try await run(FileStatusCommands.status(showUntracked: showUntracked))
        var files = FileStatusCommands.parseStatus(result.standardOutputString)
        if !result.succeeded { files.append(Self.errorItem(result.standardErrorString)) }
        if showSkipWorktree {
            let listing = try await run(FileStatusCommands.listFilesVerbose)
            for var file in FileStatusCommands.parseListFilesVerbose(listing.standardOutputString, skipWorktree: true, assumeUnchanged: false) {
                file.staged = .workTree
                file.id = "workTree:skip:\(file.path)"
                files.append(file)
            }
        }
        return files
    }


    package func fileStatusDiff(first: RevisionID?, second: RevisionID, parentToSecond: ObjectID?,
                                showSkipWorktree: Bool, showUntracked: Bool) async throws -> [ChangedFile] {
        let staged = FileStatusDiffCalculator.stagedStatus(first: first, second: second, parentToSecond: parentToSecond)
        if staged == .workTree || staged == .index {
            return try await workingDirectoryStatus(showUntracked: showUntracked, showSkipWorktree: showSkipWorktree)
                .filter { $0.staged == staged || $0.isStatusOnly }
        }
        let result = try await run(FileStatusCommands.diff(first: first, second: second))
        var files = FileStatusCommands.parseRawDiff(result.standardOutputString, staged: staged)
        if !result.succeeded { files.append(Self.errorItem(result.standardErrorString)) }
        if first == .workingDirectory || second == .workingDirectory {

            let untracked = try await workingDirectoryStatus(showUntracked: true, showSkipWorktree: false)
                .filter { ($0.staged == .workTree && $0.changeType == .added && !$0.isTracked) || $0.isStatusOnly }
            for var file in untracked {
                if first == .workingDirectory, !file.isStatusOnly { file.changeType = .deleted }
                files.append(file)
            }
        }
        return files
    }


    package func fileStatusTree(_ revision: RevisionID) async throws -> [ChangedFile] {
        switch revision {
        case .object(let id):
            let result = try await run(FileStatusCommands.tree(id.string))
            return result.succeeded ? FileStatusCommands.parseTree(result.standardOutputString) : [Self.errorItem(result.standardErrorString)]
        case .index, .workingDirectory:
            let result = try await run(FileStatusCommands.indexTree)
            return result.succeeded ? FileStatusCommands.parseIndexTree(result.standardOutputString) : [Self.errorItem(result.standardErrorString)]
        }
    }

    package func calculateFileStatus(_ request: FileStatusDiffRequest, describe: @escaping @Sendable (ObjectID) -> String) async throws -> [FileStatusGroup] {
        let calculator = FileStatusDiffCalculator(
            diffFiles: { first, second, parent in
                try await self.fileStatusDiff(first: first, second: second, parentToSecond: parent,
                                              showSkipWorktree: request.showSkipWorktreeFiles, showUntracked: request.showUntrackedFiles)
            },
            treeFiles: { try await self.fileStatusTree($0) },
            combinedDiffFiles: { merge in
                let result = try await self.run(FileStatusCommands.combinedDiffFiles(merge))
                return result.standardOutputString.split(separator: "\0", omittingEmptySubsequences: true).map { path in
                    var file = FileStatusCommands.changedFile(path: String(path), oldPath: nil, status: "M", staged: .none)
                    file.id = "combined:\(path)"
                    return file
                }
            },
            mergeBase: { a, b in
                let result = try await self.run(FileStatusCommands.mergeBase(a, b))
                return result.succeeded ? try? ObjectID.parse(result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
            },
            rangeCount: { first, second in
                guard first != second else { return (0, 0) }
                let result = try await self.run(FileStatusCommands.rangeCount(first.string, second.string))
                return result.succeeded ? FileStatusCommands.parseRangeCount(result.standardOutputString) : (nil, nil)
            },
            grepFiles: { revision, arguments, text in
                let result = try await self.run(try FileStatusCommands.grepFiles(arguments, revision: revision, options: request.grepSettings))

                return result.succeeded ? FileStatusCommands.parseGrepFiles(result.standardOutputString, revision: revision, grepText: text) : []
            },
            describe: describe
        )
        return try await calculator.calculate(request)
    }

    package func loadFileStatusDiff(group: FileStatusGroup, file: ChangedFile, options: FileDiffOptions, grep: GitGrepOptions) async throws -> FileStatusContent {
        if file.isStatusOnly { return .text(file.path) }
        if file.isRangeDiff, let first = file.rangeDiffFirst, let second = file.rangeDiffSecond {
            let result = try await run(FileStatusCommands.rangeDiff(first.string, second.string, path: nil))
            return .text(result.succeeded ? result.standardOutputString : result.standardErrorString)
        }
        if group.isGrep, let text = file.grepString, !text.isEmpty {
            let command = try FileStatusCommands.grepFile(try FileStatusCommands.grepArguments(for: text), revision: group.second,
                                                          path: file.path, options: grep, viewer: options)
            let result = try await run(command)
            guard result.succeeded else {
                return .text("\(result.standardErrorString)\nGit command (exit code: \(result.exitStatus)): git \(result.arguments.joined(separator: " "))\n")
            }
            return .diff(FileDiff(id: file.id, fileID: file.id, lines: FileStatusCommands.parseGrepFile(result.standardOutputString)))
        }
        var seen = Set<String>()
        let paths = [file.oldPath, file.path].compactMap { $0 }.filter { seen.insert($0).inserted }
        let output: GitCommandResult
        if group.kind == .combined, case .object(let merge) = group.second {
            output = try await run(FileStatusCommands.combinedDiff(merge, path: file.path, options: options))
        } else if !file.isTracked {
            output = try await run(GitCommand(arguments: ["diff", "--no-ext-diff", "--no-index", "--patch", "--no-color"] + options.gitArguments
                                              + ["--", "/dev/null", file.path], accessesRemote: false, changesRepositoryState: false))
        } else if group.first == nil, case .object(let id) = group.second {
            output = try await run(GitCommand(arguments: ["diff-tree", "--root", "--no-commit-id", "-r", "--patch", "--no-color",
                                                          "--find-renames", "--find-copies"] + options.gitArguments + [id.string, "--"] + paths,
                                              accessesRemote: false, changesRepositoryState: false))
        } else {
            output = try await run(GitCommand(arguments: ["diff", "--no-ext-diff", "--patch", "--no-color", "--find-renames", "--find-copies"]
                                              + options.gitArguments + FileStatusCommands.revisionArguments(first: group.first, second: group.second)
                                              + ["--"] + paths, accessesRemote: false, changesRepositoryState: false))
        }
        guard output.succeeded || output.exitStatus == 1 else {
            throw GitError.commandFailed(arguments: output.arguments, status: output.exitStatus, stderr: output.standardErrorString)
        }
        let parsed = GitOutputParser.parseUnifiedDiff(output.standardOutput, files: [file])
        return .diff(parsed[file.id] ?? parsed.values.first)
    }

    package func loadFileData(path: String, at revision: RevisionID) async throws -> Data {
        let root = try fileStatusRoot()
        switch revision {
        case .workingDirectory:
            let url = root.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw GitError.fileUnavailable(path) }
            return try Data(contentsOf: url)
        case .index:
            return try await runChecked(["show", ":\(path)"], changes: false).standardOutput
        case .object(let id):
            return try await runChecked(["show", "\(id.string):\(path)"], changes: false).standardOutput
        }
    }

    package func blobSpecifier(path: String, at revision: RevisionID) async throws -> String? {
        switch revision {
        case .workingDirectory: return path
        case .index:
            let result = try await run(GitCommand(arguments: ["rev-parse", "--verify", "--quiet", ":\(path)"], accessesRemote: false, changesRepositoryState: false))
            return result.succeeded ? result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        case .object(let id):
            let result = try await run(GitCommand(arguments: ["rev-parse", "--verify", "--quiet", "\(id.string):\(path)"], accessesRemote: false, changesRepositoryState: false))
            return result.succeeded ? result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
    }


    package func resetFiles(to revision: RevisionID, items: [ChangedFile], resetAndDelete: Bool) async throws -> String {
        guard revision == .index || revision.objectID != nil else { return "" }
        let root = try fileStatusRoot()
        var output = ""
        func statusNow() async throws -> [ChangedFile] {
            try await workingDirectoryStatus(showUntracked: true, showSkipWorktree: false)
        }
        if revision != .index {

            let status = try await statusNow()
            let unstage = Set(items.compactMap { item -> String? in
                item.staged == .index || status.contains(where: { $0.path == item.path && $0.staged == .index }) ? item.path : nil
            })
            if !unstage.isEmpty {
                let result = try await run(GitCommand(arguments: ["reset", "-q", "--"] + unstage.sorted(), accessesRemote: false, changesRepositoryState: true))
                if !result.succeeded {

                    _ = try await run(GitCommand(arguments: ["rm", "--cached", "-q", "-r", "--"] + unstage.sorted(), accessesRemote: false, changesRepositoryState: true))
                }
            }
        }
        let postUnstage = try await statusNow()
        func isNew(_ file: ChangedFile) -> Bool { file.changeType == .added || file.changeType == .copied }
        var deleted = Set<String>()
        var checkout: [String] = []
        for item in items {
            if resetAndDelete, isNew(item) || (revision != .index && postUnstage.contains(where: { isNew($0) && $0.path == item.path })) {
                let url = root.appendingPathComponent(item.path)
                if FileManager.default.fileExists(atPath: url.path) {
                    do {
                        try FileManager.default.removeItem(at: url)
                        deleted.insert(item.path)
                    } catch { output += "\u{2022}\u{00a0}\(item.path): \(error.localizedDescription)\n" }
                }
            }
            let name = item.changeType == .renamed ? (item.oldPath ?? item.path) : item.path
            if revision == .index {
                guard !deleted.contains(item.path), postUnstage.contains(where: { $0.path == item.path }) else { continue }
                if postUnstage.contains(where: { $0.path == item.path && $0.isConflict }) {
                    output += "\u{2022}\u{00a0}\(item.path)\n"
                    continue
                }
                checkout.append(name)
            } else if !isNew(item) && !postUnstage.contains(where: { isNew($0) && $0.path == item.path }) {
                checkout.append(name)
            }
        }
        if !checkout.isEmpty {
            var arguments = ["checkout"]
            if case .object(let id) = revision { arguments.append(id.string) }
            arguments += ["--"] + checkout
            let result = try await run(GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: true))
            if !result.succeeded { output += result.standardErrorString }
        }
        return output
    }

    package func setSkipWorktree(_ paths: [String], _ value: Bool) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runChecked(["update-index", value ? "--skip-worktree" : "--no-skip-worktree", "--"] + paths)
    }

    package func setAssumeUnchanged(_ paths: [String], _ value: Bool) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runChecked(["update-index", value ? "--assume-unchanged" : "--no-assume-unchanged", "--"] + paths)
    }

    package func stopTracking(_ path: String) async throws {
        _ = try await runChecked(["rm", "--cached", "--", path])
    }



    package func move(from oldName: String, to newName: String, isFolder: Bool) async throws {
        guard FileStatusCommands.validateMove(oldName: oldName, newName: newName) else { return }
        let root = try fileStatusRoot()
        let parent = (newName as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(parent), withIntermediateDirectories: true)
        }
        let target = isFolder && !newName.hasSuffix("/") ? newName + "/" : newName
        _ = try await runChecked(["mv", oldName, target])
    }



    package func cherryPickChanges(group: FileStatusGroup, file: ChangedFile) async throws -> FileStatusApplyResult {
        let patch: Data
        if group.first == nil, case .object(let id) = group.second {
            patch = try await runChecked(["diff-tree", "--no-color", "--no-ext-diff", "-p", "--root", id.string, "--", file.path], changes: false).standardOutput
        } else {
            let paths = [file.oldPath, file.path].compactMap { $0 }
            patch = try await runChecked(["diff", "--no-color", "--no-ext-diff", "--find-renames", "--find-copies"]
                + FileStatusCommands.revisionArguments(first: group.first, second: group.second) + ["--"] + paths,
                changes: false).standardOutput
        }
        guard !patch.isEmpty else { return FileStatusApplyResult(succeeded: true, output: "", patch: "") }
        let result = try await run(GitCommand(arguments: ["apply", "--3way", "--index", "--whitespace=nowarn"],
                                              accessesRemote: false, changesRepositoryState: true), input: patch)
        let output = (result.standardOutputString + result.standardErrorString).trimmingCharacters(in: .whitespacesAndNewlines)
        return FileStatusApplyResult(succeeded: result.succeeded, output: output, patch: String(decoding: patch, as: UTF8.self))
    }


    package func submoduleCommit(path: String, at revision: RevisionID?) async throws -> ObjectID? {
        guard let revision, revision != .workingDirectory else { return nil }
        return try ObjectID.parseIfPresent(try await blobSpecifier(path: path, at: revision))
    }

    package func fileStatusSubmodule(group: FileStatusGroup, file: ChangedFile) async throws -> FileStatusSubmodule? {
        guard file.isSubmodule, group.kind != .combined, !group.isGrep else { return nil }
        var arguments: [String]
        if group.first == nil, let revision = group.second.objectID {
            arguments = ["diff-tree", "--root", "--no-commit-id", "-r", revision.string]
        } else {
            arguments = ["diff"] + FileStatusCommands.revisionArguments(first: group.first, second: group.second)
        }
        arguments += ["--no-ext-diff", "--patch", "--no-color", "--submodule=short", "--"]
            + [file.oldPath, file.path].compactMap { $0 }
        let patch = try await run(GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: false))
        guard patch.succeeded, var status = FileStatusCommands.submoduleChanges(patch.standardOutputString) else { return nil }
        guard let first = status.first, let second = status.second else { return status }
        if first == second {
            status.state = .same; status.added = 0; status.removed = 0
            return status
        }
        let child = try fileStatusRoot().appendingPathComponent(file.path)

        guard FileManager.default.fileExists(atPath: child.appendingPathComponent(".git").path) else { return status }
        let counts = try await git.run(FileStatusCommands.rangeCount(second.string, first.string), in: child)
        guard counts.succeeded else { return status }
        (status.added, status.removed) = FileStatusCommands.parseRangeCount(counts.standardOutputString)
        if status.added == 0, status.removed != nil { status.state = .behind }
        else if status.removed == 0, status.added != nil { status.state = .ahead }
        else if status.added != nil, status.removed != nil {
            var dates: [Int64] = []
            for id in [second, first] {
                let result = try await git.run(GitCommand(arguments: ["show", "-s", "--format=%ct", id.string],
                                                         accessesRemote: false, changesRepositoryState: false), in: child)
                if result.succeeded, let date = Int64(result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)) { dates.append(date) }
            }
            if dates.count == 2 {
                if dates[0] > dates[1] { status.state = .newer }
                else if dates[0] < dates[1] { status.state = .older }
            }
        }
        return status
    }

    @discardableResult package func deleteFiles(_ items: [ChangedFile]) async throws -> Bool {
        let root = try fileStatusRoot()
        let files = items.filter { !$0.isSubmodule }
        let staged = files.filter { $0.staged == .index }.map(\.path)
        var changed = false
        do {
            if !staged.isEmpty {
                _ = try await runChecked(["reset", "-q", "--"] + staged)
                changed = true
            }
            for file in files {
                let url = root.appendingPathComponent(file.path)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                    changed = true
                }
            }
        } catch {
            if changed { throw FileStatusPartialMutationError(message: error.localizedDescription) }
            throw error
        }
        return changed
    }



    private static func difftoolPrefix(customTool: String?, externalCommand: String?) -> [String] {
        var arguments = ["difftool"]
        if let customTool, !customTool.isEmpty { arguments.append("--tool=\(customTool)") }
        else if let externalCommand, !externalCommand.isEmpty { arguments.append("--extcmd=\(externalCommand)") }
        else { arguments.append("--gui") }
        return arguments + ["--find-renames", "--find-copies", "--no-prompt"]
    }

    package func openDifftool(first: RevisionID?, second: RevisionID?, path: String, oldPath: String?, isTracked: Bool,
                              customTool: String?, externalCommand: String?) async throws {
        var arguments = Self.difftoolPrefix(customTool: customTool, externalCommand: externalCommand)
        if !isTracked {
            arguments += ["--no-index", "--", "/dev/null", path]
        } else {
            if first == nil, let second, case .object(let id) = second {
                arguments += ["--root", id.string]
            } else {
                arguments += FileStatusCommands.revisionArguments(first: first, second: second)
            }
            var seen = Set<String>()
            arguments += ["--"] + [oldPath, path].compactMap { $0 }.filter { seen.insert($0).inserted }
        }
        _ = try await runChecked(arguments, changes: false)
    }

    package func openDifftool(firstBlob: String, secondBlob: String, customTool: String?, externalCommand: String?) async throws {
        let arguments = Self.difftoolPrefix(customTool: customTool, externalCommand: externalCommand) + [firstBlob, secondBlob]
        _ = try await runChecked(arguments, changes: false)
    }


    package func loadDiffTools() async throws -> [String] {
        let result = try await run(GitCommand(arguments: ["config", "--get-regexp", "^(difftool\\..*\\.(cmd|path)|diff\\.tool)$"],
                                              accessesRemote: false, changesRepositoryState: false))
        var names: [String] = []
        for line in result.standardOutputString.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let key = parts.first else { continue }
            let name: String
            if key == "diff.tool" {
                name = parts.count > 1 ? String(parts[1]) : ""
            } else {
                let components = key.split(separator: ".")
                guard components.count >= 3 else { continue }
                name = components.dropFirst().dropLast().joined(separator: ".")
            }
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }
}
