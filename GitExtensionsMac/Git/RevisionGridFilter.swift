import Foundation
import GitExtensionsCore


package enum RevisionSortOrder: String, Codable, Sendable, CaseIterable {
    case gitDefault, authorDate, topology
}



package struct RevisionGridFilter: Codable, Equatable, Sendable {
    package var byDateFrom = false
    package var dateFrom: Date?
    package var byDateTo = false
    package var dateTo: Date?
    package var byAuthor = false
    package var author = ""
    package var byCommitter = false
    package var committer = ""
    package var byMessage = false
    package var message = ""
    package var byDiffContent = false
    package var diffContent = ""
    package var ignoreCase = true
    package var byCommitsLimit = false
    package var commitsLimit = -1
    package var byPathFilter = false
    package var pathFilter = ""

    package var byBranchFilter = false
    package var branchFilter = ""

    package var showCurrentBranchOnly = false
    package var showOnlyFirstParent = false

    package var showReflogReferences = false
    package var showSimplifyByDecoration = false
    package var hideMergeCommits = false

    package var showFullHistory = false
    package var showSimplifyMerges = false

    package var lastRevisionToDisplay: String?

    package init() {}


    package var effectiveAuthor: String { byAuthor ? author : "" }
    package var effectiveCommitter: String { byCommitter ? committer : "" }
    package var effectiveMessage: String { byMessage ? message : "" }
    package var effectiveDiffContent: String { byDiffContent ? diffContent : "" }
    package var effectivePathFilter: String { byPathFilter ? pathFilter : "" }
    package var effectiveBranchFilter: String { byBranchFilter ? branchFilter : "" }
    package func effectiveCommitsLimit(default limit: Int) -> Int { byCommitsLimit && commitsLimit >= 0 ? commitsLimit : limit }

    package var isShowAllBranchesChecked: Bool { !byBranchFilter && !showCurrentBranchOnly }
    package var isShowCurrentBranchOnlyChecked: Bool { showCurrentBranchOnly }
    package var isShowFilteredBranchesChecked: Bool { byBranchFilter && !showCurrentBranchOnly }


    package var hasRevisionFilter: Bool {
        byAuthor || byCommitter || byMessage || byDiffContent
            || !effectivePathFilter.trimmingCharacters(in: .whitespaces).isEmpty
            || hideMergeCommits || showSimplifyByDecoration
    }

    package var hasFilter: Bool {
        hasRevisionFilter || byDateFrom || byDateTo || showOnlyFirstParent
            || !effectiveBranchFilter.trimmingCharacters(in: .whitespaces).isEmpty
    }



    package mutating func resetAllFilters() {
        byDateFrom = false; byDateTo = false; byAuthor = false; byCommitter = false
        byMessage = false; byDiffContent = false; byPathFilter = false; byBranchFilter = false
        showOnlyFirstParent = false; hideMergeCommits = false; showSimplifyByDecoration = false
    }


    package mutating func setBranchFilter(_ filter: String) {
        showCurrentBranchOnly = false
        let value = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        byBranchFilter = !value.isEmpty
        branchFilter = value
    }


    package struct TextFilter: Equatable, Sendable {
        package var text: String
        package var message: Bool
        package var committer: Bool
        package var author: Bool
        package var diffContent: Bool
        package init(text: String, message: Bool, committer: Bool, author: Bool, diffContent: Bool) {
            self.text = text; self.message = message; self.committer = committer; self.author = author; self.diffContent = diffContent
        }
    }


    package mutating func apply(_ filter: TextFilter) -> Bool {
        var changed = filter.author != byAuthor || filter.committer != byCommitter
            || filter.message != byMessage || filter.diffContent != byDiffContent
        let blank = filter.text.trimmingCharacters(in: .whitespaces).isEmpty
        if filter.author { if effectiveAuthor != filter.text { byAuthor = !blank; author = filter.text; changed = true } } else { byAuthor = false }
        if filter.committer { if effectiveCommitter != filter.text { byCommitter = !blank; committer = filter.text; changed = true } } else { byCommitter = false }
        if filter.message { if effectiveMessage != filter.text { byMessage = !blank; message = filter.text; changed = true } } else { byMessage = false }
        if filter.diffContent { if effectiveDiffContent != filter.text { byDiffContent = !blank; diffContent = filter.text; changed = true } } else { byDiffContent = false }
        return changed
    }


    private static func gitDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd hh:mm:ss"
        return formatter.string(from: date)
    }


    package func revisionArguments(currentCheckout: ObjectID?, defaultCommitsLimit: Int, showStashes: Bool,
                                   showGitNotes: Bool, showSessionRefs: Bool) -> [String] {
        var arguments: [String] = []

        let limit = effectiveCommitsLimit(default: defaultCommitsLimit)
        if limit > 0 { arguments.append("--max-count=\(limit)") }
        if byDateFrom, let dateFrom { arguments.append("--since=\(Self.gitDate(dateFrom))") }
        if byDateTo, let dateTo { arguments.append("--until=\(Self.gitDate(dateTo))") }

        if hideMergeCommits { arguments.append("--no-merges") }
        if showSimplifyByDecoration { arguments.append("--simplify-by-decoration") }
        if byAuthor, !author.trimmingCharacters(in: .whitespaces).isEmpty { arguments.append("--author=\(author)") }
        if byCommitter, !committer.trimmingCharacters(in: .whitespaces).isEmpty { arguments.append("--committer=\(committer)") }
        if ignoreCase && (byAuthor || byCommitter || byMessage || byDiffContent) { arguments.append("--regexp-ignore-case") }
        if byDiffContent, !diffContent.trimmingCharacters(in: .whitespaces).isEmpty { arguments.append("-G\(diffContent)") }
        if byMessage, !message.trimmingCharacters(in: .whitespaces).isEmpty {

            arguments += message.hasPrefix("--") ? Self.splitOptions(message) : ["--grep=\(message)"]
        }
        if hasRevisionFilter {
            arguments.append("--parents")
            if showFullHistory {
                arguments.append("--full-history")
                if showSimplifyMerges { arguments.append("--simplify-merges") }
            }
        }

        if showOnlyFirstParent { arguments.append("--first-parent") }
        if showReflogReferences { arguments.append("--reflog") }
        let stashGlob = "--glob=refs/stas[h]"
        if isShowCurrentBranchOnlyChecked, let currentCheckout {
            if showStashes { arguments.append(stashGlob) }
            arguments.append(currentCheckout.string)
        } else if isShowFilteredBranchesChecked, !branchFilter.trimmingCharacters(in: .whitespaces).isEmpty {
            if showStashes { arguments.append(stashGlob) }
            for branch in branchFilter.split(whereSeparator: \.isWhitespace).map(String.init) {
                let wildcard = branch.contains { "?*[".contains($0) }
                arguments.append(wildcard && !branch.hasPrefix("--") && !branch.contains("..") ? "--branches=\(branch)" : branch)
            }
        } else {
            if !showGitNotes { arguments.append("--exclude=refs/notes/commits") }
            if !showStashes { arguments.append("--exclude=refs/stash") }
            if !showSessionRefs {
                arguments.append("--exclude=refs/agents/**")
                arguments.append("--exclude=refs/sessions/**")
                arguments.append("--exclude=refs/copilot/checkpoints/**")
            }
            arguments.append("--all")

            if !effectiveMessage.trimmingCharacters(in: .whitespaces).isEmpty
                && !effectiveDiffContent.trimmingCharacters(in: .whitespaces).isEmpty {
                arguments.append("--boundary")
            }
        }
        if let lastRevisionToDisplay, !lastRevisionToDisplay.isEmpty { arguments.append("..." + lastRevisionToDisplay) }
        return arguments
    }


    package static func splitOptions(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for character in text {
            if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character; hasToken = true
            } else if character.isWhitespace {
                if hasToken { result.append(current); current = ""; hasToken = false }
            } else {
                current.append(character); hasToken = true
            }
        }
        if hasToken { result.append(current) }
        return result
    }


    package var pathArguments: [String] {
        let path = effectivePathFilter.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return [] }
        return path.contains("\"") || path.contains("'") || path.contains(" ") ? Self.splitOptions(path) : [path]
    }

    package var followsRenames: Bool {
        let paths = pathArguments
        return paths.count == 1 && !paths[0].hasSuffix("/")
    }


    package var summary: String {
        var lines: [String] = []
        let formatter = DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .medium
        if byDateFrom, let dateFrom { lines.append("Since: \(formatter.string(from: dateFrom))") }
        if byDateTo, let dateTo { lines.append("Until: \(formatter.string(from: dateTo))") }
        if byPathFilter { lines.append("Path filter: \(pathFilter)") }
        if byAuthor, !author.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("Author: \(author)") }
        if byCommitter, !committer.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("Committer: \(committer)") }
        if showSimplifyByDecoration { lines.append("Simplify by decoration") }
        if byMessage, !message.isEmpty { lines.append(message.hasPrefix("--") ? message : "Message: \(message)") }
        if byDiffContent, !diffContent.isEmpty { lines.append("Diff contains: \(diffContent)") }
        if showOnlyFirstParent { lines.append("Show only first parent") }
        if showReflogReferences { lines.append("Show reflog") }
        if isShowCurrentBranchOnlyChecked { lines.append("Show current branch only") }
        else if !effectiveBranchFilter.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("Branches: \(branchFilter)") }
        return lines.map { $0 + "\n" }.joined()
    }
}


package enum RevisionLogCommands {
    package static func format(notes: Bool) -> String {
        "--format=%H%x00%P%x00%at%x00%ct%x00%aN%x00%aE%x00%cN%x00%cE%x00%B" + (notes ? "%x00%N" : "")
    }
    package static func log(sortOrder: RevisionSortOrder, revisionArguments: [String], paths: [String], notes: Bool = false) -> GitCommand {
        var arguments = ["log", "-z", format(notes: notes)]
        switch sortOrder {
        case .authorDate: arguments.append("--author-date-order")
        case .topology: arguments.append("--topo-order")
        case .gitDefault: break
        }
        arguments += revisionArguments
        arguments.append("--")
        arguments += paths
        return GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: false)
    }

    package static let followPrefix = "Commit: "
    package static func follow(path: String, exactOnly: Bool? = nil) -> GitCommand {
        let renameOptions = exactOnly.map { $0 ? ["--find-renames=100%", "--find-copies=100%"] : ["--find-renames", "--find-copies"] } ?? ["-M", "-C"]
        return GitCommand(arguments: ["log", "--format=\(followPrefix)%H", "--name-only", "--follow"] + renameOptions + ["-z", "--", path],
                   accessesRemote: false, changesRepositoryState: false)
    }
    package static func fileName(path: String, revision: ObjectID, exactOnly: Bool) -> GitCommand {
        GitCommand(arguments: ["log", "--format=\(followPrefix)%H", "--name-only", "--follow", "--diff-merges=separate",
            exactOnly ? "--find-renames=100%" : "--find-renames", exactOnly ? "--find-copies=100%" : "--find-copies",
            revision.string, "--max-count=1", "-z", "--", path], accessesRemote: false, changesRepositoryState: false)
    }
    package static func followedPaths(_ output: String) -> (names: [String], byRevision: [ObjectID: String]) {
        var names: [String] = [], paths: [ObjectID: String] = [:]
        var revision: ObjectID?
        for raw in output.split(separator: "\0", omittingEmptySubsequences: false) {


            let token = raw.hasPrefix("\n") ? String(raw.dropFirst()) : String(raw)
            if !raw.hasPrefix("\n"), token.hasPrefix(followPrefix),
               let parsed = try? ObjectID.parse(String(token.dropFirst(followPrefix.count))) {
                revision = parsed
            } else if !token.isEmpty, let revision {
                if paths[revision] == nil { paths[revision] = token }
                if !names.contains(token) { names.append(token) }
            }
        }
        return (names, paths)
    }

    package static func followedNames(_ output: String) -> [String] {
        var names: [String] = []
        for token in output.split(whereSeparator: { $0 == "\0" || $0 == "\n" }).map(String.init) {
            guard !token.hasPrefix(followPrefix), !token.isEmpty, !names.contains(token) else { continue }
            names.append(token)
        }
        return names
    }

    package static func parents(of revision: ObjectID) -> GitCommand {
        GitCommand(arguments: ["rev-list", "--max-count=50", revision.string], accessesRemote: false, changesRepositoryState: false)
    }
}


package protocol RepositoryRevisionGridDataSource: Sendable {

    func resolveRevision(_ expression: String) async -> ObjectID?

    func openDirDiffWithDifftool(first: RevisionID?, second: RevisionID) async throws

    func mergeBase(of revisions: [ObjectID], includesArtificial: Bool) async throws -> ObjectID?

    func ancestors(of revision: ObjectID) async -> [ObjectID]

    func aheadBehindData() async -> [String: AheadBehindData]

    func superprojectInfo(branches: Bool, remoteBranches: Bool, tags: Bool) async -> SuperprojectInfo?
}


package struct AheadBehindData: Equatable, Sendable {
    package static let gone = "gone"
    package static let goneSymbol = "✗"
    package var branch: String
    package var remoteRef: String
    package var aheadCount: String
    package var behindCount: String

    package init(branch: String, remoteRef: String, aheadCount: String, behindCount: String) {
        self.branch = branch
        self.remoteRef = remoteRef
        self.aheadCount = aheadCount
        self.behindCount = behindCount
    }

    package var isGone: Bool { aheadCount == Self.gone }

    package func display(withCounts: Bool = true, reverse: Bool = false) -> String {
        if isGone { return Self.goneSymbol }
        let isBehind = !behindCount.isEmpty
        var text = ""
        if aheadCount == "0" && !isBehind {
            if withCounts { text += "0" }
            return text + (reverse ? "↓↑" : "↑↓")
        }
        if !aheadCount.isEmpty && aheadCount != "0" {
            if withCounts { text += aheadCount }
            text += reverse ? "↓" : "↑"
            if isBehind && withCounts { text += " " }
        }
        if isBehind {
            if withCounts { text += behindCount }
            text += reverse ? "↑" : "↓"
        }
        return text
    }


    package static let command = GitCommand(
        arguments: ["for-each-ref", "--format=%(push:track,nobracket)%00%(upstream:track,nobracket)%00%(push)%00%(upstream)%00%(refname:short)%00", "refs/heads/"],
        accessesRemote: false, changesRepositoryState: false)


    package static func parse(_ output: String) -> [String: AheadBehindData] {
        var fields = output.components(separatedBy: "\0").map { $0.trimmingCharacters(in: .newlines) }
        if fields.last?.isEmpty == true { fields.removeLast() }
        var result: [String: AheadBehindData] = [:]
        func track(_ value: String) -> (gone: Bool, ahead: String?, behind: String?, unknown: Bool) {
            if value == "gone" { return (true, nil, nil, false) }
            var ahead: String?, behind: String?
            for part in value.components(separatedBy: ", ") {
                if part.hasPrefix("ahead "), Int(part.dropFirst(6)) != nil { ahead = String(part.dropFirst(6)) }
                if part.hasPrefix("behind "), Int(part.dropFirst(7)) != nil { behind = String(part.dropFirst(7)) }
            }

            let unknown = ahead == nil && behind == nil && !value.trimmingCharacters(in: .whitespaces).isEmpty
            return (false, ahead, behind, unknown)
        }
        for index in stride(from: 0, to: fields.count - fields.count % 5, by: 5) {
            let push = track(fields[index]), upstream = track(fields[index + 1])
            let branch = fields[index + 4]
            let remoteRef = !fields[index + 2].isEmpty && !push.gone ? fields[index + 2] : fields[index + 3]
            guard !branch.isEmpty, !remoteRef.isEmpty else { continue }
            let ahead = push.ahead ?? (push.behind != nil ? "" : upstream.ahead
                ?? ((push.gone || upstream.gone) ? gone : (push.unknown || upstream.unknown) ? "" : "0"))
            let behind = push.behind ?? (push.ahead != nil ? "" : upstream.behind ?? "")
            result[branch] = AheadBehindData(branch: branch, remoteRef: remoteRef, aheadCount: ahead, behindCount: behind)
        }
        return result
    }
}


package struct SuperprojectInfo: Equatable, Sendable {
    package static let maxRefs = 4
    package var currentCommit: ObjectID?
    package var conflictBase: ObjectID?
    package var conflictLocal: ObjectID?
    package var conflictRemote: ObjectID?

    package var refs: [ObjectID: [RevisionReference]] = [:]
    package init() {}

    package enum Commands {
        package static let superprojectWorkingTree = GitCommand(arguments: ["rev-parse", "--show-superproject-working-tree"], accessesRemote: false, changesRepositoryState: false)
        package static func status(path: String) -> GitCommand {
            GitCommand(arguments: ["submodule", "status", "--cached", path], accessesRemote: false, changesRepositoryState: false)
        }
        package static func conflict(path: String) -> GitCommand {
            GitCommand(arguments: ["ls-files", "-z", "--unmerged", "--", path], accessesRemote: false, changesRepositoryState: false)
        }

        package static func refs(branches: Bool, remoteBranches: Bool, tags: Bool) -> GitCommand? {
            let patterns = (branches ? ["refs/heads/"] : []) + (remoteBranches ? ["refs/remotes/"] : []) + (tags ? ["refs/tags/"] : [])
            guard !patterns.isEmpty else { return nil }
            return GitCommand(arguments: ["for-each-ref", "--sort=-committerdate", "--count=100", "--format=%(refname)"] + patterns,
                              accessesRemote: false, changesRepositoryState: false)
        }
        package static func submoduleCommit(ref: String, path: String) -> GitCommand {
            GitCommand(arguments: ["ls-tree", ref, "--", path], accessesRemote: false, changesRepositoryState: false)
        }
    }


    package static func parseStatus(_ output: String) -> (code: Character, commit: ObjectID)? {
        guard let line = output.split(separator: "\n").first, let hash = line.dropFirst().split(separator: " ").first,
              let id = try? ObjectID.parse(String(hash)) else { return nil }
        return (line.first!, id)
    }


    package mutating func applyConflict(_ output: String) {
        for record in output.split(separator: "\0") {
            let parts = record.split(separator: " ", maxSplits: 2)
            guard parts.count == 3, let id = try? ObjectID.parse(String(parts[1])), let stage = parts[2].first else { continue }
            switch stage {
            case "1": conflictBase = id
            case "2": conflictLocal = id
            case "3": conflictRemote = id
            default: break
            }
        }
    }


    package static func reference(_ fullName: String) -> RevisionReference? {
        if fullName.hasPrefix("refs/heads/") { return .init(id: fullName, name: String(fullName.dropFirst(11)), kind: .localBranch) }
        if fullName.hasPrefix("refs/remotes/") { return .init(id: fullName, name: String(fullName.dropFirst(13)), kind: .remoteBranch) }
        if fullName.hasPrefix("refs/tags/") { return .init(id: fullName, name: String(fullName.dropFirst(10)), kind: .tag) }
        return nil
    }


    package static func parseTreeCommit(_ output: String) -> ObjectID? {
        guard let line = output.split(separator: "\n").first else { return nil }
        let fields = line.split(separator: "\t", maxSplits: 1).first?.split(separator: " ") ?? []
        guard fields.count == 3 else { return nil }
        return try? ObjectID.parse(String(fields[2]))
    }
}

package enum RevisionGridCommands {

    package static func mergeBase(revisions: [ObjectID], head: ObjectID, includesArtificial: Bool) -> GitCommand {
        var arguments = ["merge-base"]
        if revisions.count > 2 || (revisions.count == 2 && includesArtificial) { arguments.append("--octopus") }
        if revisions.count < 1 { arguments.append(head.string) }
        if revisions.count < 2 { arguments.append(head.string) }
        arguments += revisions.map(\.string)
        return GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: false)
    }
}


package enum RevisionDiffArguments {
    package static func arguments(first: RevisionID?, second: RevisionID?) -> [String] {
        func option(_ revision: RevisionID?) -> String {
            switch revision {
            case .workingDirectory, nil: ""
            case .index: "--cached"
            case .object(let id): id.string
            }
        }
        var first = option(first), second = option(second)
        var extra: [String] = []
        if first != second && (first.isEmpty || (first == "--cached" && !second.isEmpty)) { extra.append("-R") }
        if (first.isEmpty && second == "--cached") || (first == "--cached" && second.isEmpty) { first = ""; second = "" }
        if second == "--cached" { extra.append("--cached"); second = "" }
        return extra + [first, second].filter { !$0.isEmpty }
    }
    package static func dirDiff(first: RevisionID?, second: RevisionID) -> GitCommand {
        GitCommand(arguments: ["difftool", "--gui", "--find-renames", "--find-copies", "--no-prompt", "--dir-diff"]
                   + arguments(first: first, second: second),
                   accessesRemote: false, changesRepositoryState: false)
    }
}

extension GitRepositoryModule: RepositoryRevisionGridDataSource {
    package func resolveRevision(_ expression: String) async -> ObjectID? {
        let expression = expression.trimmingCharacters(in: .whitespaces)
        guard let repository = resolvedRepository, !expression.isEmpty, !expression.hasPrefix("-") else { return nil }
        let result = try? await git.run(GitCommand(arguments: ["rev-parse", "--verify", "--quiet", expression + "^{commit}"],
                                                   accessesRemote: false, changesRepositoryState: false), in: repository.rootURL)
        guard let result, result.succeeded else { return nil }
        return try? ObjectID.parse(result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    package func mergeBase(of revisions: [ObjectID], includesArtificial: Bool) async throws -> ObjectID? {
        guard let repository = resolvedRepository, let head = await resolveRevision("HEAD"),
              !(revisions.isEmpty && !includesArtificial) else { return nil }
        let result = try await git.run(RevisionGridCommands.mergeBase(revisions: revisions, head: head, includesArtificial: includesArtificial),
                                       in: repository.rootURL)
        if result.exitStatus == 1 { return nil }
        guard result.succeeded else {
            throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString)
        }
        return try? ObjectID.parse(result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    package func ancestors(of revision: ObjectID) async -> [ObjectID] {
        guard let repository = resolvedRepository,
              let result = try? await git.run(RevisionLogCommands.parents(of: revision), in: repository.rootURL), result.succeeded else { return [] }
        return result.standardOutputString.split(separator: "\n").compactMap { try? ObjectID.parse(String($0)) }
    }

    package func aheadBehindData() async -> [String: AheadBehindData] {
        guard let repository = resolvedRepository,
              let result = try? await git.run(AheadBehindData.command, in: repository.rootURL), result.succeeded else { return [:] }
        return AheadBehindData.parse(result.standardOutputString)
    }

    package func superprojectInfo(branches: Bool, remoteBranches: Bool, tags: Bool) async -> SuperprojectInfo? {
        guard let repository = resolvedRepository,
              let located = try? await git.run(SuperprojectInfo.Commands.superprojectWorkingTree, in: repository.rootURL), located.succeeded
        else { return nil }
        let superPath = located.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !superPath.isEmpty else { return nil }
        let superURL = URL(fileURLWithPath: superPath).standardizedFileURL.resolvingSymlinksInPath()
        let root = repository.rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard root.hasPrefix(superURL.path + "/") else { return nil }
        let path = String(root.dropFirst(superURL.path.count + 1))
        func run(_ command: GitCommand) async -> String? {
            guard let result = try? await git.run(command, in: superURL), result.succeeded else { return nil }
            return result.standardOutputString
        }
        var info = SuperprojectInfo()
        if let status = await run(SuperprojectInfo.Commands.status(path: path)).flatMap(SuperprojectInfo.parseStatus) {
            if status.code == "U" {
                if let conflict = await run(SuperprojectInfo.Commands.conflict(path: path)) { info.applyConflict(conflict) }
            } else { info.currentCommit = status.commit }
        }
        if let command = SuperprojectInfo.Commands.refs(branches: branches, remoteBranches: remoteBranches, tags: tags),
           let refs = await run(command) {
            for name in refs.split(separator: "\n").map(String.init) {
                guard let reference = SuperprojectInfo.reference(name),
                      let commit = await run(SuperprojectInfo.Commands.submoduleCommit(ref: name, path: path)).flatMap(SuperprojectInfo.parseTreeCommit)
                else { continue }
                info.refs[commit, default: []].append(reference)
            }
        }
        return info
    }

    package func openDirDiffWithDifftool(first: RevisionID?, second: RevisionID) async throws {
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        let result = try await git.run(RevisionDiffArguments.dirDiff(first: first, second: second), in: repository.rootURL)
        guard result.succeeded else {
            throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString)
        }
    }
}
