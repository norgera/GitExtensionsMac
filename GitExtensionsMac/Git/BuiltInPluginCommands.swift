import Foundation
import GitExtensionsCore

package struct ObsoleteBranch: Identifiable, Sendable {
    package var id: String { name }
    package let name: String
    package let date: Date
    package let author: String
    package let subject: String
}

package struct LargeGitFile: Identifiable, Sendable {
    package var id: ObjectID { objectID }
    package let objectID: ObjectID
    package let path: String
    package let size: Int64
    package var compressedSize: Int64?
    package var revisions: Set<ObjectID>
    package var lastDate: Date
}

package struct ReleaseNote: Equatable, Sendable {
    package let commit: String
    package var message: [String]
}

package struct CodeStatistics: Sendable {
    package var total = 0
    package var blank = 0
    package var comments = 0
    package var designer = 0
    package var test = 0
    package var byExtension: [String: Int] = [:]
    package var contributors: [(String, Int)] = []
    package var code: Int { total - blank - comments - designer }
}

package struct BuiltInMutationOutcome: Sendable {
    package let changed: Bool
    package let errors: [String]
}

package struct BuiltInMutationError: LocalizedError, Sendable {
    package let changed: Bool
    package let cancelled: Bool
    package let message: String
    package var errorDescription: String? { message }
}

package enum CodeLineCounter {
    package static func analyze(_ text: String, path: String) -> CodeStatistics {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let designerFile = path.lowercased().contains(".designer.") || (path.contains("Web References") && path.hasSuffix("Reference.cs"))
        let xml = ["xml", "resx", "html", "cshtml", "htm"].contains(ext)
        var generated = false, comment = false, testFile = false
        var result = CodeStatistics()
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for raw in lines {
            let line = String(raw.drop(while: { $0.isWhitespace }))
            var skipReset = false
            if ["#region Windows Form Designer generated code", "#Region \" Windows Form Designer generated code", "#region Component Designer generated code", "#Region \" Component Designer generated code \"", "#region Web Form Designer generated code", "#Region \" Web Form Designer Generated Code \""].contains(where: { line.hasPrefix($0) }) { generated = true }
            if line.hasPrefix("/*") { comment = true }
            if ["pas", "inc"].contains(ext), (line.hasPrefix("(*") && !line.hasPrefix("(*$")) || (line.hasPrefix("{") && !line.hasPrefix("{$")) { comment = true }
            if ["rb", "pl"].contains(ext), line.hasPrefix("=begin") { comment = true }
            if ext == "lua", line.hasPrefix("--[[") { comment = true }
            if ext == "m", line.hasPrefix("%{") { comment = true }
            if xml, line.contains("<!--") { comment = true }
            if ext == "aspx", line.contains("<%--") { comment = true }
            if ext == "py", !comment, line.hasPrefix("'''") || line.hasPrefix("\"\"\"") { comment = true; skipReset = true }
            if !comment, !generated, line.hasPrefix("[Test") { testFile = true }
            result.total += 1
            if generated || designerFile { result.designer += 1 }
            else if line.isEmpty { result.blank += 1 }
            else if comment || line.hasPrefix("'") || line.hasPrefix("//") ||
                (["py", "rb", "pl"].contains(ext) && line.hasPrefix("#")) ||
                (ext == "lua" && line.hasPrefix("--")) ||
                (ext == "cshtml" && line.contains("@*") && line.contains("*@")) ||
                (ext == "m" && line.hasPrefix("%")) ||
                (["asm", "s", "inc"].contains(ext) && line.hasPrefix(";")) { result.comments += 1 }
            if !skipReset {
                if generated, line.contains("#endregion") || line.contains("#End Region") { generated = false }
                if line.contains("*/") || (["pas", "inc"].contains(ext) && (line.contains("*)") || line.contains("}"))) ||
                    (["rb", "pl"].contains(ext) && line.contains("=end")) || (ext == "lua" && line.contains("]]")) ||
                    (ext == "m" && line.contains("%}")) || (xml && line.contains("-->")) ||
                    (ext == "aspx" && line.contains("--%>")) || (ext == "py" && (line.contains("'''") || line.contains("\"\"\""))) { comment = false }
            }
        }
        result.byExtension["." + ext] = result.code
        if testFile || URL(fileURLWithPath: path).deletingLastPathComponent().path.lowercased().contains("test") { result.test = result.code }
        return result
    }
}

package enum BuiltInPluginCommands {
    package static let releaseArguments = "--pretty=\"format:%h@%s%b\" --abbrev-commit {0}..{1}"

    package static func backgroundFetch(_ value: String, submodules: Bool = false) -> GitCommand {
        let arguments = submodules ? ["submodule", "foreach", "--recursive", "git", "fetch", "--all"]
            : value.split(separator: " ").map(String.init)
        return GitCommand(arguments: arguments.isEmpty ? ["fetch", "--all"] : arguments,
            accessesRemote: true, changesRepositoryState: true)
    }

    package static func shouldRefreshAfterFetch(_ command: GitCommand, result: GitCommandResult) -> Bool {
        command.arguments.first?.lowercased() != "fetch" || result.standardErrorString.contains("From")
    }

    package static func trackingBranch(_ name: String, remote: String) -> GitCommand {
        GitCommand(arguments: ["branch", "--track", name, "remotes/\(remote)/\(name)"],
            accessesRemote: false, changesRepositoryState: true)
    }

    package static func branchCandidates(_ output: String, current: String, base: String,
        remote: String?, pattern: String?, ignoreCase: Bool, invert: Bool) throws -> [String] {
        let regex = try pattern.map { try NSRegularExpression(pattern: $0, options: ignoreCase ? .caseInsensitive : []) }
        return output.split(separator: "\n").compactMap { line in
            let name = line.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first.map(String.init) ?? ""
            guard !name.isEmpty, !name.hasPrefix("("), name != current, name != base,
                name != "HEAD", name != remote.map({ $0 + "/HEAD" }) else { return nil }
            if let remote, !name.hasPrefix(remote + "/") { return nil }
            if let regex {
                let matches = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
                if matches == invert { return nil }
            }
            return name
        }
    }

    package static func deleteBranch(_ name: String, remote: String?, unmerged: Bool) -> GitCommand {
        let args = remote.map { ["push", $0, ":" + String(name.dropFirst($0.count + 1))] }
            ?? ["branch", unmerged ? "-D" : "-d", name]
        return GitCommand(arguments: args, accessesRemote: remote != nil, changesRepositoryState: true)
    }

    package static func parseReleaseNotes(_ output: String) -> [ReleaseNote] {
        var notes: [ReleaseNote] = []
        for line in output.components(separatedBy: "\n") {
            if let separator = line.firstIndex(of: "@"), !line[..<separator].isEmpty,
                line[..<separator].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                notes.append(ReleaseNote(commit: String(line[..<separator]), message: [String(line[line.index(after: separator)...])]))
            } else if !notes.isEmpty { notes[notes.count - 1].message.append(line) }
        }
        return notes
    }

    package static func releaseNotes(from: String, to: String, arguments: String) throws -> GitCommand {
        guard !from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "BuiltInPlugins", code: 1, userInfo: [NSLocalizedDescriptionKey: "Both From and To commits must be specified."])
        }
        let args = arguments.replacingOccurrences(of: "{0}", with: from).replacingOccurrences(of: "{1}", with: to)
        return GitCommand(arguments: ["log"] + (try ScriptExecution.arguments(args)), accessesRemote: false, changesRepositoryState: false)
    }

    package static func rewriteRemoving(_ path: String) -> GitCommand {
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return GitCommand(arguments: ["filter-branch", "--index-filter", "git rm -r -f --cached --ignore-unmatch " + quoted,
            "--prune-empty", "--", "--all"], accessesRemote: false, changesRepositoryState: true)
    }

    package static func proxy(host: String, port: String, username: String, password: String, global: Bool, remove: Bool) -> GitCommand {
        let credentials = username.isEmpty ? "" : username + (password.isEmpty ? "" : ":" + password) + "@"
        let address = credentials + host + (port.isEmpty ? "" : ":" + port)
        return GitCommand(arguments: ["config"] + (global ? ["--global"] : []) +
            (remove ? ["--unset", "http.proxy"] : ["http.proxy", address]), accessesRemote: false, changesRepositoryState: true)
    }

    package static func globalProxy(_ command: GitCommand, executable: URL) async throws -> GitCommandResult {
        try await GitProcess(executableURL: executable).run(command, in: FileManager.default.temporaryDirectory)
    }

    package static func parseLargeFiles(_ data: Data, revision: ObjectID, date: Date, minimum: Int64) -> [LargeGitFile] {
        data.split(separator: 0).compactMap { record in
            let text = String(decoding: record, as: UTF8.self)
            guard let tab = text.firstIndex(of: "\t") else { return nil }
            let fields = text[..<tab].split(whereSeparator: { $0 == " " })
            guard fields.count == 4, fields[1] == "blob", let size = Int64(fields[3]), size >= minimum,
                let id = try? ObjectID(parsing: String(fields[2])) else { return nil }
            return LargeGitFile(objectID: id, path: String(text[text.index(after: tab)...]), size: size,
                revisions: [revision], lastDate: date)
        }
    }
}

package protocol RepositoryBuiltInPluginDataSource: RepositoryPluginDataSource {
    func createTrackingBranches(remote: String) async throws -> (references: Int, created: Int)
    func obsoleteBranches(base: String, remote: String?, unmerged: Bool, pattern: String?, ignoreCase: Bool, invert: Bool) async throws -> [ObsoleteBranch]
    func findLargeFiles(minimum: Int64, progress: @escaping @Sendable (Int, Int, [LargeGitFile]) -> Void) async throws -> [LargeGitFile]
    func removeLargeFiles(_ paths: [String]) async throws -> BuiltInMutationOutcome
    func gourceAuthors() async throws -> [(String, String)]
    func codeStatistics(pattern: String, ignoredDirectories: String, includeSubmodules: Bool) async throws -> CodeStatistics
    func solutionFiles() async throws -> [URL]
}

extension GitRepositoryModule: RepositoryBuiltInPluginDataSource {
    private func builtInRun(_ command: GitCommand) async throws -> GitCommandResult {
        try Task.checkCancellation()
        let result = try await executePluginCommand(command, standardInput: nil)
        try Task.checkCancellation()
        guard result.succeeded else { throw GitError.commandFailed(arguments: command.arguments, status: result.exitStatus, stderr: result.standardErrorString) }
        return result
    }

    private func builtInRead(_ arguments: [String]) async throws -> String {
        try await builtInRun(GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: false)).standardOutputString
    }

    package func createTrackingBranches(remote: String) async throws -> (references: Int, created: Int) {
        let lines = try await builtInRead(["branch", "-a"]).split(separator: "\n")
        let prefix = "remotes/\(remote)/"
        let before = try await builtInRead(["for-each-ref", "--format=%(refname)%00%(objectname)", "refs/heads/"])
        var count = 0
        do {
        for line in lines {
            try Task.checkCancellation()
            let ref = line.trimmingCharacters(in: CharacterSet(charactersIn: "* \r\n"))
            if ref.hasPrefix(prefix) {
                let result = try await executePluginCommand(BuiltInPluginCommands.trackingBranch(String(ref.dropFirst(prefix.count)), remote: remote), standardInput: nil)
                if result.succeeded { count += 1 }
            }
        }
        return (lines.count, count)
        } catch {
            let after = await Task.detached { try? await self.builtInRead(["for-each-ref", "--format=%(refname)%00%(objectname)", "refs/heads/"]) }.value
            throw BuiltInMutationError(changed: count > 0 || after.map { $0 != before } == true,
                cancelled: error is CancellationError, message: error.localizedDescription)
        }
    }

    package func obsoleteBranches(base: String, remote: String?, unmerged: Bool, pattern: String?, ignoreCase: Bool, invert: Bool) async throws -> [ObsoleteBranch] {
        var arguments = ["branch", "--list"]
        if remote != nil { arguments.append("-r") }
        if !unmerged { arguments += ["--merged", base] }
        let current = (try? await builtInRead(["symbolic-ref", "--short", "HEAD"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidates = try BuiltInPluginCommands.branchCandidates(try await builtInRead(arguments), current: current,
            base: base, remote: remote, pattern: pattern, ignoreCase: ignoreCase, invert: invert)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var branches: [ObsoleteBranch] = []
        for name in candidates {
            let fields = try await builtInRead(["log", "--pretty=format:%ci\n%an\n%s", "--max-count=1", name, "--"]).components(separatedBy: "\n")
            if fields.count >= 3 {
                branches.append(ObsoleteBranch(name: name, date: formatter.date(from: fields[0]) ?? .distantPast,
                    author: fields[1], subject: fields[2]))
            }
        }
        return branches
    }

    package func findLargeFiles(minimum: Int64, progress: @escaping @Sendable (Int, Int, [LargeGitFile]) -> Void) async throws -> [LargeGitFile] {
        let revisions = try await builtInRead(["rev-list", "HEAD"]).split(separator: "\n").map { try ObjectID(parsing: String($0)) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var objects: [ObjectID: LargeGitFile] = [:]
        for (index, revision) in revisions.enumerated() {
            let date = formatter.date(from: try await builtInRead(["show", "-s", revision.string, "--format=%ci"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? .distantPast
            let result = try await builtInRun(GitCommand(arguments: ["ls-tree", "-zrl", revision.string], accessesRemote: false, changesRepositoryState: false))
            for object in BuiltInPluginCommands.parseLargeFiles(result.standardOutput, revision: revision, date: date, minimum: minimum) {
                if var known = objects[object.id] {
                    known.revisions.insert(revision); known.lastDate = max(date, known.lastDate); objects[object.id] = known
                } else { objects[object.id] = object }
            }
            progress(index + 1, revisions.count, objects.values.sorted { $0.size == $1.size ? $0.path < $1.path : $0.size > $1.size })
        }
        let common = try await builtInRead(["rev-parse", "--git-common-dir"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = try await settingsDirectories().working
        let pack = URL(fileURLWithPath: common, relativeTo: directory).appendingPathComponent("objects/pack")
        for file in (try? FileManager.default.contentsOfDirectory(at: pack, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "idx" {
            let output = try await builtInRead(["verify-pack", "-v", file.path])
            for line in output.split(separator: "\n") {
                let fields = line.split(separator: " ")
                if fields.count >= 4, fields[1] == "blob", let id = try? ObjectID(parsing: String(fields[0])), let compressed = Int64(fields[3]) {
                    objects[id]?.compressedSize = compressed
                }
            }
        }
        return objects.values.sorted { $0.size == $1.size ? $0.path < $1.path : $0.size > $1.size }
    }

    package func removeLargeFiles(_ paths: [String]) async throws -> BuiltInMutationOutcome {
        let before = try await builtInRead(["for-each-ref", "--format=%(refname)%00%(objectname)"])
        do {
        var errors: [String] = []
        for path in paths {
            let result = try await executePluginCommand(BuiltInPluginCommands.rewriteRemoving(path), standardInput: nil)
            if !result.succeeded { errors.append(result.standardErrorString) }
            try Task.checkCancellation()
        }
        let refs = try await builtInRead(["for-each-ref", "--format=%(refname)", "refs/original/"])
        for ref in refs.split(separator: "\n") {
            _ = try await builtInRun(GitCommand(arguments: ["update-ref", "-d", String(ref)], accessesRemote: false, changesRepositoryState: true))
        }
        for args in [["reflog", "expire", "--expire=now", "--all"], ["gc", "--aggressive", "--prune=now"]] {
            _ = try await builtInRun(GitCommand(arguments: args, accessesRemote: false, changesRepositoryState: true))
        }
        let after = try await builtInRead(["for-each-ref", "--format=%(refname)%00%(objectname)"])
        return BuiltInMutationOutcome(changed: before != after, errors: errors)
        } catch {
            let after = await Task.detached { try? await self.builtInRead(["for-each-ref", "--format=%(refname)%00%(objectname)"]) }.value
            throw BuiltInMutationError(changed: after.map { $0 != before } ?? false, cancelled: error is CancellationError, message: error.localizedDescription)
        }
    }

    package func gourceAuthors() async throws -> [(String, String)] {
        var names: Set<String> = []
        return try await builtInRead(["log", "--pretty=format:%aE|%aN"]).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty, names.insert(fields[1]).inserted else { return nil }
            return (fields[0], fields[1])
        }
    }

    private func builtInDirectories(_ includeSubmodules: Bool) async throws -> [URL] {
        let root = try await settingsDirectories().working
        guard includeSubmodules else { return [root] }
        let raw = try? await builtInRead(["config", "--file", ".gitmodules", "--get-regexp", "submodule\\..*\\.path"])
        return [root] + (raw ?? "").split(separator: "\n").compactMap { line in
            line.firstIndex(of: " ").map { root.appendingPathComponent(String(line[line.index(after: $0)...])) }
        }
    }

    package func codeStatistics(pattern: String, ignoredDirectories: String, includeSubmodules: Bool) async throws -> CodeStatistics {
        var result = CodeStatistics()
        let shortlog = try await builtInRead(["shortlog", "--all", "-s", "-n", "--no-merges"])
        result.contributors = shortlog.split(separator: "\n").compactMap { line in
            let fields = line.trimmingCharacters(in: .whitespaces).split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, let count = Int(fields[0]) else { return nil }
            return (String(fields[1]), count)
        }
        let extensions = Set(pattern.replacingOccurrences(of: "*", with: "").lowercased().split(separator: ";").map(String.init))
        let filters = ignoredDirectories.replacingOccurrences(of: "\\", with: "/").lowercased().split(separator: ";").map(String.init)
        for directory in try await builtInDirectories(includeSubmodules) {
            let output = try await builtInRead(["-C", directory.path, "ls-tree", "-rz", "HEAD"])
            for record in output.split(separator: "\0") {
                try Task.checkCancellation()
                guard let tab = record.firstIndex(of: "\t") else { continue }
                let path = String(record[record.index(after: tab)...])
                let file = directory.appendingPathComponent(path)
                guard extensions.contains("." + file.pathExtension.lowercased()),
                    !filters.contains(where: { file.deletingLastPathComponent().path.lowercased().hasSuffix($0) }),
                    let data = try? Data(contentsOf: file) else { continue }
                let text: String
                if data.starts(with: [0xff, 0xfe]) { text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
                else if data.starts(with: [0xfe, 0xff]) { text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
                else { text = String(decoding: data.starts(with: [0xef, 0xbb, 0xbf]) ? data.dropFirst(3) : data, as: UTF8.self) }
                let count = CodeLineCounter.analyze(text, path: file.path)
                result.total += count.total; result.blank += count.blank; result.comments += count.comments
                result.designer += count.designer; result.test += count.test
                for (ext, code) in count.byExtension { result.byExtension[ext, default: 0] += code }
            }
        }
        return result
    }

    package func solutionFiles() async throws -> [URL] {
        let directory = try await settingsDirectories().working
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return files.compactMap { $0 as? URL }.filter { $0.pathExtension == "sln" }
    }
}
