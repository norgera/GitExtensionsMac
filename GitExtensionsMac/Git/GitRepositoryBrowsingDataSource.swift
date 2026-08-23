import Foundation

struct ResolvedGitRepository: Sendable {
    let rootURL: URL
    let gitDirectoryURL: URL
    let isBare: Bool
}

actor GitRepositoryBrowsingDataSource: RepositoryOpeningDataSource {
    let git: any GitCommandRunning
    private var requestedURL: URL
    var resolvedRepository: ResolvedGitRepository?
    private var statusRecords: [GitStatusRecord] = []
    private var detailsCache: [String: RepositoryRevisionDetails] = [:]
    private var treeCache: [String: [RepositoryFileEntry]] = [:]
    private var diffCache: [String: FileDiff] = [:]
    var pendingCherryPickItems: [RepositoryCherryPickItem] = []
    var pendingCherryPickOptions: RepositoryCherryPickOptions?
    var pendingRebaseActions: [String: RepositoryRebaseTodoAction] = [:]

    init(repositoryURL: URL, git: any GitCommandRunning = GitProcess()) {
        requestedURL = repositoryURL.standardizedFileURL
        self.git = git
    }

    func openRepository(at url: URL) async throws -> RepositorySnapshot {
        requestedURL = url.standardizedFileURL
        resolvedRepository = nil
        statusRecords = []
        detailsCache = [:]
        treeCache = [:]
        diffCache = [:]
        pendingCherryPickItems = []
        pendingCherryPickOptions = nil
        pendingRebaseActions = [:]
        return try await loadSnapshot()
    }

    func loadSnapshot() async throws -> RepositorySnapshot {
        try Task.checkCancellation()
        detailsCache = [:]
        treeCache = [:]
        diffCache = [:]
        let repository = try await resolveRepository(at: requestedURL)
        resolvedRepository = repository

        async let currentBranchOutput = run(arguments: ["branch", "--show-current"], repository: repository)
        async let headOutput = run(arguments: ["rev-parse", "--verify", "HEAD"], repository: repository, acceptedStatuses: [0, 128])
        async let refsOutput = run(arguments: [
            "--no-optional-locks", "for-each-ref",
            "--format=%(objectname)%00%(refname)%00%(*objectname)%00%(upstream:remotename)%00%(upstream:remoteref)%00%(upstream:track,nobracket)%00"
        ], repository: repository)
        async let remotesOutput = run(arguments: ["remote", "-v"], repository: repository)
        async let worktreesOutput = run(arguments: ["worktree", "list", "--porcelain", "-z"], repository: repository)

        let currentBranchResult = try await currentBranchOutput
        let headResult = try await headOutput
        let refsResult = try await refsOutput
        let remotesResult = try await remotesOutput
        let worktreesResult = try await worktreesOutput

        let currentBranch = currentBranchResult.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        let headID = headResult.succeeded
            ? headResult.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let refRecords = try GitOutputParser.parseRefs(refsResult.standardOutput)

        let historyResult = try await loadHistory(repository: repository)
        let stashRecords = repository.isBare ? [] : try await loadStashes(repository: repository)
        let parsedStatus = repository.isBare ? [] : try await loadStatus(repository: repository)
        statusRecords = parsedStatus
        let workingDirectoryChangeCount = parsedStatus.filter { record in
            record.indexStatus != "." && record.indexStatus != " "
                || record.worktreeStatus != "." && record.worktreeStatus != " "
                || record.isUntracked
                || record.isConflict
        }.count

        let refModels = makeRefs(records: refRecords, currentBranch: currentBranch, headID: headID)
        let branches = refModels.localBranches
        let remoteBranches = refModels.remoteBranches
        let tags = refModels.tags
        let remotes = makeRemotes(output: remotesResult.standardOutputString, branches: remoteBranches)
        let stashes = makeStashes(stashRecords)
        let worktrees = try makeWorktrees(output: worktreesResult.standardOutput, repository: repository)
        let submodules = repository.isBare ? [] : try await loadSubmodules(repository: repository)
        let commits = makeCommits(
            history: historyResult,
            stashes: stashRecords,
            referencesByCommit: refModels.referencesByCommit,
            headID: headID,
            includeArtificial: !repository.isBare
        )

        let name = repository.rootURL.lastPathComponent.isEmpty
            ? repository.gitDirectoryURL.deletingPathExtension().lastPathComponent
            : repository.rootURL.lastPathComponent
        let repositoryModel = Repository(
            id: repository.gitDirectoryURL.path,
            name: name,
            path: repository.rootURL.path,
            description: repository.isBare ? "Bare Git repository" : "Git repository",
            isBare: repository.isBare
        )

        return RepositorySnapshot(
            repositories: [repositoryModel],
            currentRepository: repositoryModel,
            branches: branches,
            tags: tags,
            remotes: remotes,
            stashes: stashes,
            worktrees: worktrees,
            submodules: submodules,
            commits: commits,
            filesByCommit: [:],
            diffsByFile: [:],
            repositoryFilesByCommit: [:],
            gpgInfoByCommit: [:],
            workingDirectoryChangeCount: workingDirectoryChangeCount
        )
    }

    func loadRevisionDetails(for commit: Commit) async throws -> RepositoryRevisionDetails {
        if let cached = detailsCache[commit.id] { return cached }
        guard let repository = resolvedRepository else {
            throw RepositoryDataSourceError.unavailable
        }

        let changedPaths: [GitChangedPath]
        let numstat: [String: (Int, Int)]
        switch commit.kind {
        case .revision:
            let isStash = commit.references.contains { $0.kind == .stash }
            let commands = revisionDiffArguments(commit: commit)
            let nameArguments = isStash
                ? ["stash", "show", "--include-untracked", "--name-status", "-z", commit.id]
                : commands.nameStatus
            let numstatArguments = isStash
                ? ["stash", "show", "--include-untracked", "--numstat", "-z", commit.id]
                : commands.numstat
            async let namesResult = run(arguments: nameArguments, repository: repository)
            async let countsResult = run(arguments: numstatArguments, repository: repository)
            changedPaths = try GitOutputParser.parseNameStatus(try await namesResult.standardOutput)
            numstat = GitOutputParser.parseNumstat(try await countsResult.standardOutput)
        case .index:
            async let namesResult = run(arguments: diffBaseArguments() + ["--cached", "--name-status", "-z"], repository: repository)
            async let countsResult = run(arguments: diffBaseArguments() + ["--cached", "--numstat", "-z"], repository: repository)
            changedPaths = try GitOutputParser.parseNameStatus(try await namesResult.standardOutput)
            numstat = GitOutputParser.parseNumstat(try await countsResult.standardOutput)
        case .workingDirectory:
            changedPaths = changedPathsFromStatus(index: false)
            async let countsResult = run(arguments: diffBaseArguments() + ["--numstat", "-z"], repository: repository)
            numstat = GitOutputParser.parseNumstat(try await countsResult.standardOutput)
        }

        let files = changedPaths.map { path in
            let counts = numstat[path.path] ?? (0, 0)
            return ChangedFile(
                id: path.path,
                path: path.path,
                oldPath: path.oldPath,
                changeType: path.type,
                additions: counts.0,
                deletions: counts.1
            )
        }
        let details = RepositoryRevisionDetails(
            files: files,
            diffsByFile: [:],
            repositoryFiles: [],
            gpgInfo: nil
        )
        detailsCache[commit.id] = details
        return details
    }

    func loadRepositoryFiles(for commit: Commit) async throws -> [RepositoryFileEntry] {
        if let cached = treeCache[commit.id] { return cached }
        guard let repository = resolvedRepository else {
            throw RepositoryDataSourceError.unavailable
        }

        let tree = try await loadTree(for: commit, repository: repository)
        treeCache[commit.id] = tree
        return tree
    }

    func loadDiff(for commit: Commit, file: ChangedFile) async throws -> FileDiff? {
        let cacheKey = "\(commit.id)\u{0}\(file.id)"
        if let cached = diffCache[cacheKey] { return cached }
        guard let repository = resolvedRepository else {
            throw RepositoryDataSourceError.unavailable
        }

        var seenPaths = Set<String>()
        let paths = [file.oldPath, file.path].compactMap { $0 }.filter { seenPaths.insert($0).inserted }
        let output: GitCommandResult
        switch commit.kind {
        case .revision:
            if commit.references.contains(where: { $0.kind == .stash }) {
                let untrackedObject = try await run(
                    arguments: ["cat-file", "-e", "\(commit.id)^3:\(file.path)"],
                    repository: repository,
                    acceptedStatuses: [0, 1, 128]
                )
                if untrackedObject.succeeded {
                    output = try await run(
                        arguments: ["show", "--format=", "--patch", "--no-color", "\(commit.id)^3", "--"] + paths,
                        repository: repository
                    )
                } else {
                    output = try await run(
                        arguments: ["diff", "--no-ext-diff", "--patch", "--no-color", "\(commit.id)^1", commit.id, "--"] + paths,
                        repository: repository
                    )
                }
            } else {
                let commands = revisionDiffArguments(commit: commit)
                output = try await run(arguments: commands.patch + ["--"] + paths, repository: repository)
            }
        case .index:
            output = try await run(
                arguments: diffBaseArguments() + ["--cached", "--patch", "--no-color", "--"] + paths,
                repository: repository
            )
        case .workingDirectory:
            if statusRecords.contains(where: { $0.path == file.path && $0.isUntracked }) {
                output = try await run(
                    arguments: ["diff", "--no-ext-diff", "--no-index", "--patch", "--no-color", "--", "/dev/null", file.path],
                    repository: repository,
                    acceptedStatuses: [0, 1]
                )
            } else {
                output = try await run(
                    arguments: diffBaseArguments() + ["--patch", "--no-color", "--"] + paths,
                    repository: repository
                )
            }
        }

        let parsed = GitOutputParser.parseUnifiedDiff(output.standardOutput, files: [file])
        let diff = parsed[file.id] ?? parsed.values.first
        if let diff { diffCache[cacheKey] = diff }
        return diff
    }

    func loadFileContent(for commit: Commit, file: RepositoryFileEntry) async throws -> RepositoryFileEntry {
        guard let repository = resolvedRepository else {
            throw RepositoryDataSourceError.unavailable
        }

        let data: Data
        if commit.kind == .workingDirectory {
            let fileURL = repository.rootURL.appendingPathComponent(file.path).standardizedFileURL
            let rootPath = repository.rootURL.standardizedFileURL.path + "/"
            guard fileURL.path.hasPrefix(rootPath) else { throw GitError.fileUnavailable(file.path) }
            do {
                data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            } catch {
                throw GitError.fileUnavailable(file.path)
            }
        } else if file.gitObjectType == "commit" {
            data = Data("Submodule commit \(file.gitObjectID ?? "unknown")\n".utf8)
        } else if let objectID = file.gitObjectID {
            data = try await run(arguments: ["cat-file", "blob", objectID], repository: repository).standardOutput
        } else {
            throw GitError.fileUnavailable(file.path)
        }

        let content: String
        if data.contains(0) {
            content = "Binary file (\(data.count) bytes)"
        } else {
            content = String(decoding: data, as: UTF8.self)
        }
        return RepositoryFileEntry(
            id: file.id,
            path: file.path,
            content: content,
            byteCount: data.count,
            isExecutable: file.isExecutable,
            gitObjectID: file.gitObjectID,
            gitObjectType: file.gitObjectType
        )
    }

    private func resolveRepository(at url: URL) async throws -> ResolvedGitRepository {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GitError.invalidRepository(url.path)
        }

        let probe = await result(arguments: ["rev-parse", "--absolute-git-dir"], directory: url)
        if !probe.succeeded {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let repositoryChildren = children.filter { child in
                var childIsDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: child.path, isDirectory: &childIsDirectory), childIsDirectory.boolValue else {
                    return false
                }
                return FileManager.default.fileExists(atPath: child.appendingPathComponent(".git").path)
            }
            if repositoryChildren.count == 1 {
                return try await resolveRepository(at: repositoryChildren[0])
            }
            throw GitError.invalidRepository(url.path)
        }
        let gitDirectoryPath = probe.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gitDirectoryPath.isEmpty else { throw GitError.invalidRepository(url.path) }

        let bareResult = try await checked(arguments: ["rev-parse", "--is-bare-repository"], directory: url)
        let isBare = bareResult.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        let rootURL: URL
        if isBare {
            rootURL = url.standardizedFileURL
        } else {
            let rootResult = try await checked(arguments: ["rev-parse", "--show-toplevel"], directory: url)
            let rootPath = rootResult.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rootPath.isEmpty else { throw GitError.invalidRepository(url.path) }
            rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        }
        return ResolvedGitRepository(
            rootURL: rootURL,
            gitDirectoryURL: URL(fileURLWithPath: gitDirectoryPath, isDirectory: true).standardizedFileURL,
            isBare: isBare
        )
    }

    private func loadHistory(repository: ResolvedGitRepository) async throws -> [GitLogRecord] {
        let arguments = [
            "log", "-z", "--all",
            "--format=%H%x00%P%x00%at%x00%ct%x00%aN%x00%aE%x00%cN%x00%cE%x00%B"
        ]
        let output = try await run(arguments: arguments, repository: repository)
        return try GitOutputParser.parseLog(output.standardOutput)
    }

    private func loadStashes(repository: ResolvedGitRepository) async throws -> [GitStashRecord] {
        let output = try await run(arguments: [
            "stash", "list", "-z",
            "--format=%gd%x00%H%x00%P%x00%at%x00%ct%x00%aN%x00%aE%x00%cN%x00%cE%x00%gs"
        ], repository: repository)
        return try GitOutputParser.parseStashes(output.standardOutput)
    }

    private func loadStatus(repository: ResolvedGitRepository) async throws -> [GitStatusRecord] {
        let output = try await run(arguments: [
            "--no-optional-locks", "status", "--porcelain=2", "-z", "--untracked-files=all"
        ], repository: repository)
        return try GitOutputParser.parsePorcelainV2(output.standardOutput)
    }

    private func loadSubmodules(repository: ResolvedGitRepository) async throws -> [Submodule] {
        let modulesURL = repository.rootURL.appendingPathComponent(".gitmodules")
        guard FileManager.default.fileExists(atPath: modulesURL.path) else { return [] }

        let configResult = try await run(arguments: [
            "config", "--null", "--file", modulesURL.path,
            "--get-regexp", "^submodule\\..*\\.(path|url)$"
        ], repository: repository, acceptedStatuses: [0, 1])
        var config: [String: (name: String, path: String?, url: String?)] = [:]
        for rawRecord in [UInt8](configResult.standardOutput).split(separator: 0) {
            let record = String(decoding: rawRecord, as: UTF8.self)
            guard let newline = record.firstIndex(of: "\n") else { continue }
            let key = String(record[..<newline])
            let value = String(record[record.index(after: newline)...])
            guard key.hasPrefix("submodule."),
                  let suffix = key.range(of: ".path", options: .backwards) ?? key.range(of: ".url", options: .backwards)
            else { continue }
            let name = String(key[key.index(key.startIndex, offsetBy: "submodule.".count)..<suffix.lowerBound])
            var item = config[name] ?? (name, nil, nil)
            if key.hasSuffix(".path") { item.path = value } else { item.url = value }
            config[name] = item
        }

        let statusResult = try await run(arguments: ["submodule", "status"], repository: repository)
        let statusLines = statusResult.standardOutputString.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return config.values.compactMap { item in
            guard let path = item.path else { return nil }
            let matching = statusLines.first { line in
                guard line.count > 42 else { return false }
                let remainder = line.dropFirst(42)
                return remainder == path || remainder.hasPrefix(path + " ")
            }
            let prefix = matching?.first
            let commitID = matching.map { String($0.dropFirst().prefix(40)) }
            let description = matching.flatMap { line -> String? in
                let remainder = String(line.dropFirst(42 + path.count)).trimmingCharacters(in: .whitespaces)
                return remainder.isEmpty ? nil : remainder
            }
            let state: Submodule.State = switch prefix {
            case " ": .clean
            case "-": .uninitialized
            case "+": .modified
            case "U": .conflicted
            default: .unknown
            }
            return Submodule(id: path, name: item.name, path: path, url: item.url, commitID: commitID, description: description, state: state)
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func makeRefs(records: [GitRefRecord], currentBranch: String, headID: String?) -> (
        localBranches: [Branch], remoteBranches: [Branch], tags: [Tag], referencesByCommit: [String: [RevisionReference]]
    ) {
        let remoteRecords = records.filter { $0.fullName.hasPrefix("refs/remotes/") }
        let filteredRecords = records.filter { record in
            guard record.fullName.hasSuffix("/HEAD"), record.fullName.hasPrefix("refs/remotes/") else { return true }
            let components = record.fullName.split(separator: "/")
            guard components.count >= 4 else { return true }
            let remotePrefix = "refs/remotes/\(components[2])/"
            return !remoteRecords.contains { $0.fullName.hasPrefix(remotePrefix) && !$0.fullName.hasSuffix("/HEAD") && $0.objectID == record.objectID }
        }

        var locals: [Branch] = []
        var remotes: [Branch] = []
        var tags: [Tag] = []
        var references: [String: [RevisionReference]] = [:]

        for record in filteredRecords {
            if record.fullName.hasPrefix("refs/heads/") {
                let name = String(record.fullName.dropFirst("refs/heads/".count))
                let counts = aheadBehind(record.upstreamTrack)
                let branch = Branch(
                    id: record.fullName, name: name, commitID: record.objectID,
                    isCurrent: name == currentBranch, isRemote: false,
                    remoteName: record.upstreamRemote, ahead: counts.ahead, behind: counts.behind
                )
                locals.append(branch)
                references[record.objectID, default: []].append(RevisionReference(
                    id: record.fullName,
                    name: name,
                    kind: name == currentBranch ? .currentBranch : .localBranch,
                    trackingRemote: record.upstreamRemote,
                    mergeWith: record.upstreamRef.map { String($0.dropPrefix("refs/heads/")) }
                ))
            } else if record.fullName.hasPrefix("refs/remotes/") {
                let combined = String(record.fullName.dropFirst("refs/remotes/".count))
                let pieces = combined.split(separator: "/", maxSplits: 1).map(String.init)
                guard pieces.count == 2 else { continue }
                let branch = Branch(
                    id: record.fullName, name: pieces[1], commitID: record.objectID,
                    isCurrent: false, isRemote: true, remoteName: pieces[0], ahead: 0, behind: 0
                )
                remotes.append(branch)
                references[record.objectID, default: []].append(RevisionReference(id: record.fullName, name: combined, kind: .remoteBranch))
            } else if record.fullName.hasPrefix("refs/tags/") {
                let name = String(record.fullName.dropFirst("refs/tags/".count))
                let target = record.peeledObjectID ?? record.objectID
                tags.append(Tag(id: record.fullName, name: name, commitID: target))
                references[target, default: []].append(RevisionReference(id: record.fullName, name: name, kind: .tag))
            }
        }

        if currentBranch.isEmpty, let headID {
            references[headID, default: []].append(
                RevisionReference(id: "HEAD", name: "HEAD", kind: .head)
            )
        }

        remotes = remotes.map { remoteBranch in
            guard let remoteName = remoteBranch.remoteName,
                  let trackingLocal = locals.first(where: { localBranch in
                      localBranch.remoteName == remoteName &&
                      references[localBranch.commitID]?.contains(where: { reference in
                          reference.name == localBranch.name
                              && (reference.kind == .currentBranch || reference.kind == .localBranch)
                              && reference.trackingRemote == remoteName
                              && reference.mergeWith == remoteBranch.name
                      }) == true
                  })
            else { return remoteBranch }
            return Branch(
                id: remoteBranch.id,
                name: remoteBranch.name,
                commitID: remoteBranch.commitID,
                isCurrent: false,
                isRemote: true,
                remoteName: remoteName,
                ahead: trackingLocal.behind,
                behind: trackingLocal.ahead
            )
        }

        return (
            locals.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            remotes.sorted { ($0.remoteName ?? "", $0.name) < ($1.remoteName ?? "", $1.name) },
            tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            references
        )
    }

    private func makeRemotes(output: String, branches: [Branch]) -> [Remote] {
        var fetchURLs: [String: String] = [:]
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            guard line.hasSuffix(" (fetch)") else { continue }
            let content = String(line.dropLast(" (fetch)".count))
            let separator = content.firstIndex(of: "\t")
                ?? content.firstIndex(where: { $0 == " " })
            guard let separator else { continue }
            let name = String(content[..<separator])
            let url = String(content[content.index(after: separator)...])
            guard !name.isEmpty else { continue }
            fetchURLs[name] = url
        }
        let names = Set(fetchURLs.keys).union(branches.compactMap(\.remoteName))
        return names.sorted().map { name in
            Remote(
                id: name,
                name: name,
                fetchURL: fetchURLs[name] ?? "",
                branches: branches.filter { $0.remoteName == name }
            )
        }
    }

    private func makeStashes(_ records: [GitStashRecord]) -> [Stash] {
        records.map { record in
            let branch = stashBranch(record.subject)
            return Stash(
                id: record.selector,
                selector: record.selector,
                subject: record.subject,
                branchName: branch,
                commitID: record.objectID
            )
        }
    }

    private func makeWorktrees(output: Data, repository: ResolvedGitRepository) throws -> [Worktree] {
        try GitOutputParser.parseWorktrees(output).map { record in
            let pathURL = URL(fileURLWithPath: record.path, isDirectory: true).standardizedFileURL
            let branchName: String
            if let branchRef = record.branchRef {
                branchName = String(branchRef.dropPrefix("refs/heads/"))
            } else if record.isBare {
                branchName = "Bare"
            } else {
                branchName = "Detached HEAD"
            }
            return Worktree(
                id: pathURL.path,
                name: pathURL.lastPathComponent,
                path: pathURL.path,
                branchName: branchName,
                isCurrent: pathURL.path == repository.rootURL.path
            )
        }
    }

    private func makeCommits(
        history: [GitLogRecord],
        stashes: [GitStashRecord],
        referencesByCommit: [String: [RevisionReference]],
        headID: String?,
        includeArtificial: Bool
    ) -> [Commit] {
        let historyIDs = Set(history.map(\.objectID))
        let stashByObjectID = Dictionary(uniqueKeysWithValues: stashes.map { ($0.objectID, $0) })
        let stashByBase = Dictionary(grouping: stashes.compactMap { stash -> (String, GitStashRecord)? in
            stash.parentIDs.first.map { ($0, stash) }
        }, by: \.0).mapValues { $0.map(\.1) }
        var commits: [Commit] = []
        var insertedArtificial = false

        func appendArtificial() {
            guard includeArtificial, !insertedArtificial else { return }
            insertedArtificial = true
            let now = Date()
            commits.append(Commit(
                id: "$working-directory", shortID: "", subject: "Working directory", body: "",
                authorName: "", authorEmail: "", authorDate: now,
                committerName: "", committerEmail: "", commitDate: now,
                parentIDs: ["$index"], references: [], kind: .workingDirectory
            ))
            commits.append(Commit(
                id: "$index", shortID: "", subject: "Commit index", body: "",
                authorName: "", authorEmail: "", authorDate: now,
                committerName: "", committerEmail: "", commitDate: now,
                parentIDs: headID.map { [$0] } ?? [], references: [], kind: .index
            ))
        }

        for record in history {
            if record.objectID == headID { appendArtificial() }
            for stash in stashByBase[record.objectID] ?? [] where !historyIDs.contains(stash.objectID) {
                commits.append(makeStashCommit(stash))
            }
            if let stash = stashByObjectID[record.objectID] {
                commits.append(makeStashCommit(stash))
            } else {
                commits.append(makeCommit(record, references: referencesByCommit[record.objectID] ?? []))
            }
        }
        if !insertedArtificial { appendArtificial() }
        return commits
    }

    private func makeCommit(_ record: GitLogRecord, references: [RevisionReference]) -> Commit {
        let message = splitMessage(record.body)
        return Commit(
            id: record.objectID,
            shortID: String(record.objectID.prefix(8)),
            subject: message.subject,
            body: message.body,
            authorName: record.authorName,
            authorEmail: record.authorEmail,
            authorDate: record.authorDate,
            committerName: record.committerName,
            committerEmail: record.committerEmail,
            commitDate: record.commitDate,
            parentIDs: record.parentIDs,
            references: references
        )
    }

    private func makeStashCommit(_ stash: GitStashRecord) -> Commit {
        Commit(
            id: stash.objectID,
            shortID: String(stash.objectID.prefix(8)),
            subject: stash.subject,
            body: "",
            authorName: stash.authorName,
            authorEmail: stash.authorEmail,
            authorDate: stash.authorDate,
            committerName: stash.committerName,
            committerEmail: stash.committerEmail,
            commitDate: stash.commitDate,
            parentIDs: Array(stash.parentIDs.prefix(1)),
            references: [RevisionReference(id: stash.selector, name: stash.selector, kind: .stash)]
        )
    }

    private func revisionDiffArguments(commit: Commit) -> (nameStatus: [String], numstat: [String], patch: [String]) {
        if let parent = commit.parentIDs.first {
            let base = diffBaseArguments()
            return (
                base + ["--name-status", "-z", parent, commit.id],
                base + ["--numstat", "-z", parent, commit.id],
                base + ["--patch", "--no-color", parent, commit.id]
            )
        }
        let base = ["diff-tree", "--root", "--no-commit-id", "-r", "--no-ext-diff", "--find-renames", "--find-copies"]
        return (
            base + ["--name-status", "-z", commit.id],
            base + ["--numstat", "-z", commit.id],
            base + ["--patch", "--no-color", commit.id]
        )
    }

    private func diffBaseArguments() -> [String] {
        ["diff", "--no-ext-diff", "--find-renames", "--find-copies"]
    }

    private func changedPathsFromStatus(index: Bool) -> [GitChangedPath] {
        statusRecords.compactMap { record in
            let status = index ? record.indexStatus : record.worktreeStatus
            guard status != "." && status != " " else { return nil }
            return GitChangedPath(
                path: record.path,
                oldPath: record.oldPath,
                type: record.isUntracked ? .added : GitOutputParser.fileChangeType(for: status)
            )
        }
    }

    private func loadTree(for commit: Commit, repository: ResolvedGitRepository) async throws -> [RepositoryFileEntry] {
        let records: [GitTreeRecord]
        switch commit.kind {
        case .revision:
            let output = try await run(arguments: ["ls-tree", "-r", "-z", "--long", commit.id], repository: repository)
            records = try GitOutputParser.parseTree(output.standardOutput)
        case .index:
            let output = try await run(arguments: ["ls-files", "-s", "-z"], repository: repository)
            records = try GitOutputParser.parseIndexTree(output.standardOutput)
        case .workingDirectory:
            let indexOutput = try await run(arguments: ["ls-files", "-s", "-z"], repository: repository)
            var indexed = try GitOutputParser.parseIndexTree(indexOutput.standardOutput)
            let deletedPaths = Set(statusRecords.filter { $0.worktreeStatus == "D" }.map(\.path))
            indexed.removeAll { deletedPaths.contains($0.path) }
            let untrackedOutput = try await run(arguments: ["ls-files", "--others", "--exclude-standard", "-z"], repository: repository)
            let untracked = [UInt8](untrackedOutput.standardOutput).split(separator: 0).map { raw in
                GitTreeRecord(mode: "100644", objectType: "working-tree", objectID: "", byteCount: 0, path: String(decoding: raw, as: UTF8.self))
            }
            let untrackedPaths = Set(untracked.map(\.path))
            indexed.removeAll { untrackedPaths.contains($0.path) }
            records = indexed + untracked
        }

        return records.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.map { record in
            RepositoryFileEntry(
                path: record.path,
                content: "",
                byteCount: record.byteCount,
                isExecutable: record.mode == "100755",
                gitObjectID: record.objectID.isEmpty ? nil : record.objectID,
                gitObjectType: record.objectType
            )
        }
    }

    private func splitMessage(_ body: String) -> (subject: String, body: String) {
        guard let newline = body.firstIndex(of: "\n") else { return (body, "") }
        let subject = String(body[..<newline])
        let remainder = body[body.index(after: newline)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (subject, remainder)
    }

    private func aheadBehind(_ track: String?) -> (ahead: Int, behind: Int) {
        guard let track else { return (0, 0) }
        var ahead = 0
        var behind = 0
        let words = track.replacingOccurrences(of: ",", with: "").split(separator: " ")
        for index in words.indices where index + 1 < words.endIndex {
            if words[index] == "ahead" { ahead = Int(words[index + 1]) ?? 0 }
            if words[index] == "behind" { behind = Int(words[index + 1]) ?? 0 }
        }
        return (ahead, behind)
    }

    private func stashBranch(_ subject: String) -> String {
        for prefix in ["WIP on ", "On "] where subject.hasPrefix(prefix) {
            let remainder = subject.dropFirst(prefix.count)
            return String(remainder.split(separator: ":", maxSplits: 1).first ?? "")
        }
        return ""
    }

    private func run(
        arguments: [String],
        repository: ResolvedGitRepository,
        acceptedStatuses: Set<Int32> = [0]
    ) async throws -> GitCommandResult {
        try await checked(arguments: arguments, directory: repository.rootURL, acceptedStatuses: acceptedStatuses)
    }

    private func checked(
        arguments: [String],
        directory: URL,
        acceptedStatuses: Set<Int32> = [0]
    ) async throws -> GitCommandResult {
        let commandResult = try await git.run(arguments: arguments, in: directory)
        guard acceptedStatuses.contains(commandResult.exitStatus) else {
            throw GitError.commandFailed(
                arguments: arguments,
                status: commandResult.exitStatus,
                stderr: commandResult.standardErrorString
            )
        }
        return commandResult
    }

    private func result(arguments: [String], directory: URL) async -> GitCommandResult {
        do {
            return try await git.run(arguments: arguments, in: directory)
        } catch {
            return GitCommandResult(arguments: arguments, standardOutput: Data(), standardError: Data(error.localizedDescription.utf8), exitStatus: -1)
        }
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> Substring {
        hasPrefix(prefix) ? dropFirst(prefix.count) : self[...]
    }
}
