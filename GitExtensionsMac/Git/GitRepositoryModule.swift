import GitExtensionsCore
import Foundation

package struct RevisionReadRequest: Sendable {
    package let context: RevisionReadContext
    package let reader: RevisionReader

    package init(context: RevisionReadContext, reader: RevisionReader) {
        self.context = context
        self.reader = reader
    }
}

package struct FileHistoryReadRequest: Sendable {
    package let context: RevisionReadContext
    package let reader: RevisionReader
    package let identity: RepositoryIdentityState
    package let references: RepositoryReferenceState
}

package protocol RepositoryFileHistoryDataSource: Sendable {


    func fileHistoryReadRequest() async throws -> FileHistoryReadRequest
}

extension GitRepositoryModule: RepositoryFileHistoryDataSource {
    package func fileHistoryReadRequest() async throws -> FileHistoryReadRequest {
        let state = try await loadRepositoryState()
        guard let repository = resolvedRepository else { throw RepositoryDataSourceError.unavailable }
        return FileHistoryReadRequest(context: state.revisionReadRequest.context,
            reader: RevisionReader(git: git, directory: repository.rootURL), identity: state.identity, references: state.references)
    }
}



package struct RevisionBatchPolicy: Sendable {
    package let initialCount: Int
    package let subsequentCount: Int
    package let maximumDelay: TimeInterval

    package static let upstream = RevisionBatchPolicy(initialCount: 100, subsequentCount: 25_000, maximumDelay: 0.5)
    package static func fixed(_ count: Int) -> Self {
        Self(initialCount: max(1, count), subsequentCount: max(1, count), maximumDelay: .infinity)
    }

    package func shouldPublish(count: Int, firstBatch: Bool, elapsed: TimeInterval) -> Bool {
        count >= (firstBatch ? initialCount : subsequentCount) || (count > 0 && elapsed >= maximumDelay)
    }
}

package actor RevisionReader {
    private let source: Source
    private var activeSession: RevisionStreamSession?
    private var readGeneration = 0
    private var filePaths: [ObjectID: String] = [:]


    package func fileName(at revision: ObjectID, path: String, exactOnly: Bool = false) async -> String {
        guard !path.hasSuffix("/") else { return path }
        if let name = filePaths[revision] { return name }
        guard case .repository(let git, let directory) = source else { return path }
        let generation = readGeneration
        let result = try? await git.run(RevisionLogCommands.fileName(path: path, revision: revision, exactOnly: exactOnly), in: directory)
        guard generation == readGeneration, result?.succeeded == true else { return path }
        let parsed = RevisionLogCommands.followedPaths(result!.standardOutputString)
        filePaths.merge(parsed.byRevision) { first, _ in first }
        return filePaths[revision] ?? parsed.names.first ?? path
    }

    private func rememberPaths(_ paths: [ObjectID: String], generation: Int) {
        guard readGeneration == generation else { return }
        filePaths = paths
    }

    private enum Source: Sendable {
        case repository(git: any GitCommandRunning, directory: URL)
        case revisions([Commit])
    }

    package init(git: any GitCommandRunning, directory: URL) {
        source = .repository(git: git, directory: directory)
    }

    package init(revisions: [Commit]) {
        source = .revisions(revisions)
    }

    package func read(_ context: RevisionReadContext, batchSize: Int? = nil, maximumCount: Int = 0) -> AsyncThrowingStream<[Commit], Error> {
        activeSession?.cancel()
        readGeneration += 1
        let generation = readGeneration
        filePaths = [:]
        var createdSession: RevisionStreamSession?
        let stream = AsyncThrowingStream<[Commit], Error> { continuation in
            let session = RevisionStreamSession(
                context: context,
                batching: batchSize.map(RevisionBatchPolicy.fixed) ?? .upstream,
                continuation: continuation
            )
            createdSession = session
            let task = Task { [source] in
                do {
                    switch source {
                    case .revisions(let revisions):
                        session.publish(revisions)
                    case .repository(let git, let directory):
                        let options = context.options
                        var paths = options.filter.pathArguments
                        if options.followRenames, options.filter.followsRenames {

                            let follow = try await git.run(RevisionLogCommands.follow(path: paths[0], exactOnly: options.followRenamesExactOnly), in: directory)
                            guard !Task.isCancelled else { throw CancellationError() }
                            let parsed = RevisionLogCommands.followedPaths(follow.standardOutputString)
                            await self.rememberPaths(parsed.byRevision, generation: generation)
                            let names = parsed.names
                            if follow.succeeded, !names.isEmpty { paths = names }
                        }
                        let command = RevisionLogCommands.log(
                            sortOrder: options.sortOrder,
                            revisionArguments: options.filter.revisionArguments(
                                currentCheckout: context.headID, defaultCommitsLimit: maximumCount,
                                showStashes: options.showStashes, showGitNotes: options.showGitNotes,
                                showSessionRefs: options.showSessionRefs),
                            paths: paths, notes: options.loadNotes)
                        let result = try await git.runStreaming(command, in: directory) { event in
                            guard event.stream == .standardOutput else { return }
                            session.receive(event.data)
                        }
                        guard result.succeeded else {
                            throw GitError.commandFailed(
                                arguments: result.arguments,
                                status: result.exitStatus,
                                stderr: result.standardErrorString
                            )
                        }
                        try await session.finishHistory { headID in

                            let parents = try? await git.run(RevisionLogCommands.parents(of: headID), in: directory)
                            return (parents?.standardOutputString ?? "").split(separator: "\n").compactMap { try? ObjectID.parse(String($0)) }
                        }
                    }
                    session.finish()
                } catch is CancellationError {
                    session.finish()
                } catch {
                    session.finish(throwing: error)
                }
            }
            session.task = task
            continuation.onTermination = { _ in Task { session.cancel() } }
        }
        activeSession = createdSession
        return stream
    }

    package func cancel() { activeSession?.cancel(); activeSession = nil }
}

private final class RevisionStreamSession: @unchecked Sendable {
    private let lock = NSLock()
    private let context: RevisionReadContext
    private let batching: RevisionBatchPolicy
    private var firstBatch = true
    private var lastPublication = ProcessInfo.processInfo.systemUptime
    private let continuation: AsyncThrowingStream<[Commit], Error>.Continuation
    private var input = Data()
    private var fields: [String] = []
    private var records: [GitLogRecord] = []
    private var commits: [Commit] = []
    private var recordIndex = 0
    private var cancelled = false
    private var parseError: Error?
    private var incrementalBuilder: RevisionIncrementalCommitBuilder
    private let requiredStashIDs: Set<ObjectID>
    private var seenStashIDs = Set<ObjectID>()
    private var streamingEnabled: Bool
    private let fieldCount: Int
    private var publishedIDs = Set<ObjectID>()
    var task: Task<Void, Never>?

    init(
        context: RevisionReadContext,
        batching: RevisionBatchPolicy,
        continuation: AsyncThrowingStream<[Commit], Error>.Continuation
    ) {
        self.context = context
        self.batching = batching
        self.continuation = continuation
        requiredStashIDs = Set(context.effectiveStashes.map(\.objectID))
        streamingEnabled = requiredStashIDs.isEmpty
        fieldCount = context.options.loadNotes ? 10 : 9
        incrementalBuilder = RevisionIncrementalCommitBuilder(context: context, knownHistoryIDs: [])
    }

    func receive(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, parseError == nil else { return }
        input.append(data)
        do {
            while let separator = input.firstIndex(of: 0) {
                fields.append(String(decoding: input[..<separator], as: UTF8.self))
                input.removeSubrange(input.startIndex...separator)
                if fields.count == fieldCount {
                    let record = try GitOutputParser.parseLogRecord(fields, recordIndex: recordIndex)
                    records.append(record)
                    if requiredStashIDs.contains(record.objectID) { seenStashIDs.insert(record.objectID) }
                    recordIndex += 1
                    fields.removeAll(keepingCapacity: true)
                }
            }
            publishReadyRecordsIfPossible()
        } catch {
            parseError = error
        }
    }

    func finishHistory(headAncestors: @escaping @Sendable (ObjectID) async -> [ObjectID]) async throws {
        let pending: (artificial: Bool, head: ObjectID?) = try lock.withLock {
            if let parseError { throw parseError }
            guard input.isEmpty, fields.isEmpty else {
                throw GitError.malformedOutput(command: "log", detail: "incomplete trailing revision record")
            }
            guard !cancelled else { return (false, nil) }
            if streamingEnabled {
                publish(incrementalBuilder.finish(), locked: true)
            } else if !records.isEmpty {
                publish(RevisionCommitBuilder.build(history: records, context: context), locked: true)
                records.removeAll()
            }
            return (context.showsArtificial && !artificialPublished, context.headID)
        }
        guard pending.artificial else { return }

        var anchor: ObjectID?
        if let head = pending.head {
            let ancestors = await headAncestors(head)
            anchor = lock.withLock { ancestors.first { publishedIDs.contains($0) } }
        }
        lock.withLock {
            guard !cancelled else { return }
            publish(RevisionCommitBuilder.artificialRevisions(headID: context.headID, attachedTo: anchor), locked: true)
        }
    }

    private var artificialPublished: Bool {
        commits.contains { $0.isArtificial } || publishedArtificial
    }
    private var publishedArtificial = false

    func publish(_ revisions: [Commit]) {
        lock.lock()
        defer { lock.unlock() }
        publish(revisions, locked: true)
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        let shouldFinish = !cancelled
        cancelled = true
        let remainder = commits
        commits.removeAll()
        lock.unlock()
        guard shouldFinish else { return }
        if !remainder.isEmpty { continuation.yield(remainder) }
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }

    func cancel() {
        lock.lock()
        let shouldFinish = !cancelled
        cancelled = true
        commits.removeAll()
        lock.unlock()
        guard shouldFinish else { return }
        task?.cancel()
        continuation.finish()
    }

    private func publishReadyRecordsIfPossible() {
        if !streamingEnabled, seenStashIDs == requiredStashIDs {
            streamingEnabled = true
            incrementalBuilder = RevisionIncrementalCommitBuilder(
                context: context,
                knownHistoryIDs: requiredStashIDs
            )
        }
        guard streamingEnabled, !records.isEmpty else { return }
        let ready = records
        records.removeAll(keepingCapacity: true)
        publish(incrementalBuilder.append(ready), locked: true)
    }

    private func publish(_ revisions: [Commit], locked: Bool) {
        guard !cancelled else { return }
        for revision in revisions {
            if let objectID = revision.objectID { publishedIDs.insert(objectID) }
            if revision.isArtificial { publishedArtificial = true }
        }
        for revision in revisions {
            commits.append(revision)
            let now = ProcessInfo.processInfo.systemUptime
            if batching.shouldPublish(count: commits.count, firstBatch: firstBatch, elapsed: now - lastPublication) {
                continuation.yield(commits)
                commits.removeAll(keepingCapacity: true)
                firstBatch = false
                lastPublication = now
            }
        }
    }
}

private struct RevisionIncrementalCommitBuilder {
    private let context: RevisionReadContext
    private let historyIDs: Set<ObjectID>
    private let stashByID: [ObjectID: GitStashRecord]
    private let stashByBase: [ObjectID: [GitStashRecord]]
    private var insertedArtificial = false

    init(context: RevisionReadContext, knownHistoryIDs: Set<ObjectID>) {
        self.context = context
        historyIDs = knownHistoryIDs
        stashByID = Dictionary(uniqueKeysWithValues: context.effectiveStashes.map { ($0.objectID, $0) })
        stashByBase = Dictionary(grouping: context.effectiveStashes.compactMap { stash in
            stash.parentIDs.first.map { ($0, stash) }
        }, by: \.0).mapValues { $0.map(\.1) }
    }

    mutating func append(_ records: [GitLogRecord]) -> [Commit] {
        var revisions: [Commit] = []
        for record in records {
            if record.objectID == context.headID { appendArtificial(to: &revisions) }
            for stash in stashByBase[record.objectID] ?? [] where !historyIDs.contains(stash.objectID) {
                revisions.append(RevisionCommitBuilder.stashRevision(stash))
            }
            if let stash = stashByID[record.objectID] {
                revisions.append(RevisionCommitBuilder.stashRevision(stash))
                continue
            }
            revisions.append(RevisionCommitBuilder.revision(record, references: context.referencesByCommit[record.objectID] ?? []))
        }
        return revisions
    }

    mutating func finish() -> [Commit] { [] }

    private mutating func appendArtificial(to revisions: inout [Commit]) {
        guard context.showsArtificial, !insertedArtificial else { return }
        insertedArtificial = true
        revisions.append(contentsOf: RevisionCommitBuilder.artificialRevisions(headID: context.headID))
    }
}

package struct ResolvedGitRepository: Sendable {
    package let rootURL: URL
    package let gitDirectoryURL: URL
    package let isBare: Bool
}


package struct RevisionReadOptions: Sendable, Equatable {
    package var filter = RevisionGridFilter()
    package var sortOrder: RevisionSortOrder = .gitDefault

    package var showStashes = true
    package var showGitNotes = false
    package var showSessionRefs = false
    package var showArtificialCommits = true

    package var loadNotes = false

    package var followRenames = true


    package var followRenamesExactOnly: Bool? = nil
    package init() {}
}

package struct RevisionReadContext: Sendable {
    package let stashes: [GitStashRecord]
    package let referencesByCommit: [ObjectID: [RevisionReference]]
    package let headID: ObjectID?
    package let includeArtificial: Bool
    package private(set) var options: RevisionReadOptions
    package var showReflogReferences: Bool { options.filter.showReflogReferences }

    package init(
        stashes: [GitStashRecord],
        referencesByCommit: [ObjectID: [RevisionReference]],
        headID: ObjectID?,
        includeArtificial: Bool,
        showReflogReferences: Bool = false
    ) {
        self.stashes = stashes
        self.referencesByCommit = referencesByCommit
        self.headID = headID
        self.includeArtificial = includeArtificial
        var options = RevisionReadOptions()
        options.filter.showReflogReferences = showReflogReferences
        self.options = options
    }

    package func showingReflogReferences(_ show: Bool) -> RevisionReadContext {
        var context = self
        context.options.filter.showReflogReferences = show
        return context
    }

    package func with(_ options: RevisionReadOptions) -> RevisionReadContext {
        var context = self
        context.options = options
        return context
    }


    package var effectiveStashes: [GitStashRecord] { options.showStashes ? stashes : [] }
    package var showsArtificial: Bool { includeArtificial && options.showArtificialCommits }
}

package enum RevisionCommitBuilder {
    package static func placeholderRevision(id: ObjectID, subject: String = "") -> Commit {
        Commit(
            id: .object(id),
            shortID: id.shortString,
            subject: subject,
            body: "",
            authorName: "",
            authorEmail: "",
            authorDate: .distantPast,
            committerName: "",
            committerEmail: "",
            commitDate: .distantPast,
            parentIDs: [],
            references: []
        )
    }


    package static func artificialRevisions(headID: ObjectID?, attachedTo anchor: ObjectID?) -> [Commit] {
        var rows = artificialRevisions(headID: headID)
        if headID != nil {
            let index = rows[1]
            rows[1] = Commit(id: index.id, shortID: index.shortID, subject: index.subject, body: index.body,
                             authorName: index.authorName, authorEmail: index.authorEmail, authorDate: index.authorDate,
                             committerName: index.committerName, committerEmail: index.committerEmail, commitDate: index.commitDate,
                             parentIDs: anchor.map { [$0] } ?? [], references: [], kind: .index)
        }
        return rows
    }

    package static func artificialRevisions(headID: ObjectID?) -> [Commit] {
        let now = Date()
        return [
            Commit(
                id: .workingDirectory, shortID: "", subject: "Working directory", body: "",
                authorName: "", authorEmail: "", authorDate: now,
                committerName: "", committerEmail: "", commitDate: now,
                parentIDs: [], references: [], kind: .workingDirectory
            ),
            Commit(
                id: .index, shortID: "", subject: "Commit index", body: "",
                authorName: "", authorEmail: "", authorDate: now,
                committerName: "", committerEmail: "", commitDate: now,
                parentIDs: headID.map { [$0] } ?? [], references: [], kind: .index
            )
        ]
    }

    package static func stashRevision(_ stash: Stash) -> Commit {
        Commit(
            id: .object(stash.commitID),
            shortID: stash.commitID.shortString,
            subject: stash.subject,
            body: "",
            authorName: "",
            authorEmail: "",
            authorDate: .distantPast,
            committerName: "",
            committerEmail: "",
            commitDate: .distantPast,
            parentIDs: [],
            references: [RevisionReference(id: stash.selector, name: stash.selector, kind: .stash)]
        )
    }

    package static func stashRevision(_ stash: GitStashRecord) -> Commit {
        Commit(
            id: .object(stash.objectID),
            shortID: stash.objectID.shortString,
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

    package static func revision(_ record: GitLogRecord, references: [RevisionReference]) -> Commit {
        let parts = record.body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        return Commit(
            id: .object(record.objectID),
            shortID: record.objectID.shortString,
            subject: parts.first.map(String.init) ?? "",
            body: parts.count > 1 ? String(parts[1]) : "",
            authorName: record.authorName,
            authorEmail: record.authorEmail,
            authorDate: record.authorDate,
            committerName: record.committerName,
            committerEmail: record.committerEmail,
            commitDate: record.commitDate,
            parentIDs: record.parentIDs,
            references: references
        ).withNotes(record.notes)
    }

    package static func build(history: [GitLogRecord], context: RevisionReadContext) -> [Commit] {
        let historyIDs = Set(history.map(\.objectID))
        let byID = Dictionary(uniqueKeysWithValues: context.effectiveStashes.map { ($0.objectID, $0) })
        let byBase = Dictionary(grouping: context.effectiveStashes.compactMap { stash in stash.parentIDs.first.map { ($0, stash) } }, by: \.0).mapValues { $0.map(\.1) }
        var commits: [Commit] = []; var inserted = false
        func artificial() {
            guard context.showsArtificial, !inserted else { return }
            inserted = true
            commits.append(contentsOf: artificialRevisions(headID: context.headID))
        }
        for record in history {
            if record.objectID == context.headID { artificial() }
            for value in byBase[record.objectID] ?? [] where !historyIDs.contains(value.objectID) { commits.append(stashRevision(value)) }
            if let value = byID[record.objectID] { commits.append(stashRevision(value)); continue }
            commits.append(revision(record, references: context.referencesByCommit[record.objectID] ?? []))
        }
        return commits
    }
}

package actor GitRepositoryModule: RepositoryOpeningDataSource {
    package let git: any GitCommandRunning
    private var requestedURL: URL
    package var resolvedRepository: ResolvedGitRepository?
    private var statusRecords: [GitStatusRecord] = []
    private var detailsCache: [RevisionID: RepositoryRevisionDetails] = [:]
    private var treeCache: [RevisionID: [RepositoryFileEntry]] = [:]
    private var diffCache: [String: FileDiff] = [:]
    private var difftasticEnabled: Bool?
    private var diffColorConfiguredKeys: Set<String>?
    package var pendingCherryPickItems: [RepositoryCherryPickItem] = []
    package var pendingCherryPickOptions: RepositoryCherryPickOptions?
    package var pendingRebaseActions: [String: RepositoryRebaseTodoAction] = [:]
    private var latestRevisionReadRequest: RevisionReadRequest?

    package init(repositoryURL: URL, git: any GitCommandRunning = GitProcess()) {
        requestedURL = repositoryURL.standardizedFileURL
        self.git = git
    }

    package func openRepository(at url: URL) async throws -> RepositoryLoadState {
        requestedURL = url.standardizedFileURL
        resolvedRepository = nil
        statusRecords = []
        detailsCache = [:]
        treeCache = [:]
        diffCache = [:]
        difftasticEnabled = nil
        diffColorConfiguredKeys = nil
        pendingCherryPickItems = []
        pendingCherryPickOptions = nil
        pendingRebaseActions = [:]
        latestRevisionReadRequest = nil
        return try await loadRepositoryState()
    }

    package func loadRepositoryState() async throws -> RepositoryLoadState {
        try Task.checkCancellation()
        detailsCache = [:]
        treeCache = [:]
        diffCache = [:]
        diffColorConfiguredKeys = nil
        let repository = try await resolveRepository(at: requestedURL)
        resolvedRepository = repository

        async let currentBranchOutput = checked(
            GitCommand(arguments: ["branch", "--show-current"], accessesRemote: false, changesRepositoryState: false),
            directory: repository.rootURL
        )
        async let headOutput = checked(
            GitCommand(arguments: ["rev-parse", "--verify", "HEAD"], accessesRemote: false, changesRepositoryState: false),
            directory: repository.rootURL,
            acceptedStatuses: [0, 128]
        )
        async let refsOutput = checked(
            GitCommand(
                arguments: [
                    "--no-optional-locks", "for-each-ref",
                    "--format=%(objectname)%00%(refname)%00%(*objectname)%00%(upstream:remotename)%00%(upstream:remoteref)%00%(upstream:track,nobracket)%00%(authordate:unix)%00%(committerdate:unix)%00%(creatordate:unix)%00%(taggerdate:unix)%00%(objectsize)%00"
                ],
                accessesRemote: false,
                changesRepositoryState: false
            ),
            directory: repository.rootURL
        )
        async let remotesOutput = checked(
            GitCommand(arguments: ["remote", "-v"], accessesRemote: false, changesRepositoryState: false),
            directory: repository.rootURL
        )
        async let remoteConfigurations = loadRemoteConfigurations()
        async let worktreesOutput = checked(
            GitCommand(arguments: ["worktree", "list", "--porcelain", "-z"], accessesRemote: false, changesRepositoryState: false),
            directory: repository.rootURL
        )

        let currentBranchResult = try await currentBranchOutput
        let headResult = try await headOutput
        let refsResult = try await refsOutput
        let remotesResult = try await remotesOutput
        let configuredRemotes = try await remoteConfigurations
        let worktreesResult = try await worktreesOutput

        let currentBranch = currentBranchResult.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        let headID = headResult.succeeded
            ? try ObjectID.parse(headResult.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines))
            : nil
        let refRecords = try GitOutputParser.parseRefs(refsResult.standardOutput)

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
        let remotes = makeRemotes(
            output: remotesResult.standardOutputString,
            branches: remoteBranches,
            configurations: configuredRemotes
        )
        let stashes = makeStashes(stashRecords)
        let worktrees = try makeWorktrees(output: worktreesResult.standardOutput, repository: repository)
        let submodules = repository.isBare ? [] : try await loadSubmodules(repository: repository, recursive: true)
        let submoduleTree = try await loadSubmoduleTree(repository: repository, descendants: submodules)
        let revisionContext = RevisionReadContext(
            stashes: stashRecords,
            referencesByCommit: refModels.referencesByCommit,
            headID: headID,
            includeArtificial: !repository.isBare
        )
        let revisionReadRequest = RevisionReadRequest(
            context: revisionContext,
            reader: RevisionReader(git: git, directory: repository.rootURL)
        )
        latestRevisionReadRequest = revisionReadRequest

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

        let identity = RepositoryIdentityState(
            repositories: [repositoryModel],
            currentRepository: repositoryModel,
            headID: headID
        )
        let references = RepositoryReferenceState(
            branches: branches,
            tags: tags,
            referencesByCommit: refModels.referencesByCommit
        )
        let navigation = RepositoryNavigationState(
            remotes: remotes,
            stashes: stashes,
            worktrees: worktrees,
            submodules: submodules,
            submoduleTree: submoduleTree
        )
        let status = RepositoryStatusSummary(
            workingDirectoryChangeCount: workingDirectoryChangeCount,
            worktree: GitStatusRecord.revisionChangeCounts(parsedStatus, staged: false),
            index: GitStatusRecord.revisionChangeCounts(parsedStatus, staged: true)
        )
        return RepositoryLoadState(
            identity: identity,
            references: references,
            navigation: navigation,
            status: status,
            revisionReadRequest: revisionReadRequest
        )
    }

    package func revisionReadRequest() async throws -> RevisionReadRequest {
        if let latestRevisionReadRequest { return latestRevisionReadRequest }
        return try await loadRepositoryState().revisionReadRequest
    }

    package func loadRevisionDetails(for commit: Commit) async throws -> RepositoryRevisionDetails {
        if let cached = detailsCache[commit.id] { return cached }
        guard let repository = resolvedRepository else {
            throw RepositoryDataSourceError.unavailable
        }

        let changedPaths: [GitChangedPath]
        let numstat: [String: (Int, Int)]
        switch commit.kind {
        case .revision:
            guard let objectID = commit.objectID else { throw RepositoryDataSourceError.unavailable }
            let isStash = commit.references.contains { $0.kind == .stash }
            let commands = revisionDiffArguments(commit: commit)
            let nameArguments = isStash
                ? ["stash", "show", "--include-untracked", "--name-status", "-z", objectID.string]
                : commands.nameStatus
            let numstatArguments = isStash
                ? ["stash", "show", "--include-untracked", "--numstat", "-z", objectID.string]
                : commands.numstat
            async let namesResult = checked(
                GitCommand(arguments: nameArguments, accessesRemote: false, changesRepositoryState: false),
                directory: repository.rootURL
            )
            async let countsResult = checked(
                GitCommand(arguments: numstatArguments, accessesRemote: false, changesRepositoryState: false),
                directory: repository.rootURL
            )
            changedPaths = try GitOutputParser.parseNameStatus(try await namesResult.standardOutput)
            numstat = GitOutputParser.parseNumstat(try await countsResult.standardOutput)
        case .index:
            async let namesResult = checked(
                GitCommand(arguments: diffBaseArguments() + ["--cached", "--name-status", "-z"], accessesRemote: false, changesRepositoryState: false),
                directory: repository.rootURL
            )
            async let countsResult = checked(
                GitCommand(arguments: diffBaseArguments() + ["--cached", "--numstat", "-z"], accessesRemote: false, changesRepositoryState: false),
                directory: repository.rootURL
            )
            changedPaths = try GitOutputParser.parseNameStatus(try await namesResult.standardOutput)
            numstat = GitOutputParser.parseNumstat(try await countsResult.standardOutput)
        case .workingDirectory:
            changedPaths = changedPathsFromStatus(index: false)
            async let countsResult = checked(
                GitCommand(arguments: diffBaseArguments() + ["--numstat", "-z"], accessesRemote: false, changesRepositoryState: false),
                directory: repository.rootURL
            )
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

    package func loadRepositoryFiles(for commit: Commit) async throws -> [RepositoryFileEntry] {
        if let cached = treeCache[commit.id] { return cached }
        guard let repository = resolvedRepository else {
            throw RepositoryDataSourceError.unavailable
        }

        let tree = try await loadTree(for: commit, repository: repository)
        treeCache[commit.id] = tree
        return tree
    }

    package func isDifftasticEnabled() async -> Bool {
        if let difftasticEnabled { return difftasticEnabled }
        guard let repository = resolvedRepository else { return false }
        let result = try? await git.run(
            GitCommand(arguments: ["config", "--get", GitDiffAppearance.difftasticCommandKey], accessesRemote: false, changesRepositoryState: false),
            in: repository.rootURL
        )
        let enabled = result.map { $0.succeeded && !$0.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        difftasticEnabled = enabled
        return enabled
    }

    func emptyTreeID(in directory: URL) async throws -> String {
        let result = try await git.run(
            GitCommand(arguments: ["hash-object", "-t", "tree", "--stdin"], accessesRemote: false, changesRepositoryState: false),
            in: directory, standardInput: Data(), environment: [:]
        )
        guard result.succeeded else {
            throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString)
        }
        return result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func appearanceDiff(
        file: ChangedFile,
        options: FileDiffOptions,
        patchArguments: [String],
        difftastic: () async throws -> (revisions: [String], paths: [String], noIndex: Bool),
        directory: URL
    ) async throws -> FileDiff? {
        guard !file.isSubmodule else { return nil }
        switch options.appearance {
        case .patch:
            guard options.useGitColoring else { return nil }
            let configured: Set<String>
            if let diffColorConfiguredKeys { configured = diffColorConfiguredKeys }
            else {
                let config = try await git.run(GitCommand(arguments: ["config", "--get-regexp", GitDiffAppearance.colorConfigurationPattern], accessesRemote: false, changesRepositoryState: false), in: directory)
                configured = config.succeeded ? GitDiffAppearance.configuredKeys(fromGetRegexp: config.standardOutputString) : []
                diffColorConfiguredKeys = configured
            }
            var arguments = patchArguments.filter { $0 != "--no-color" }
            arguments.insert("--color=always", at: min(1, arguments.count))
            let result = try await git.run(GitCommand(arguments: GitDiffAppearance.colorConfiguration(configured: configured, reverse: options.reverseGitColoring) + arguments, accessesRemote: false, changesRepositoryState: false), in: directory)
            guard result.succeeded || result.exitStatus == 1 else { throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString) }
            return GitDiffAppearance.parseColoredPatch(result.standardOutput, file: file)
        case .difftastic:
            guard await isDifftasticEnabled() else { return nil }
            let target = try await difftastic()
            let result = try await git.run(
                GitCommand(arguments: GitDiffAppearance.difftasticArguments(revisions: target.revisions, paths: target.paths,
                                                                            noIndex: target.noIndex, options: options),
                           accessesRemote: false, changesRepositoryState: false),
                in: directory, standardInput: nil, environment: GitDiffAppearance.difftasticEnvironment(options)
            )
            guard result.succeeded || (target.noIndex && result.exitStatus == 1) else {
                throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString)
            }
            return GitDiffAppearance.parseDifftastic(result.standardOutput, file: file, width: options.difftasticWidth, reverse: options.reverseGitColoring)
        case .gitWordDiff:
            let configured: Set<String>
            if let diffColorConfiguredKeys {
                configured = diffColorConfiguredKeys
            } else {
                let result = try await git.run(
                    GitCommand(arguments: ["config", "--get-regexp", GitDiffAppearance.colorConfigurationPattern],
                               accessesRemote: false, changesRepositoryState: false),
                    in: directory
                )
                configured = result.succeeded ? GitDiffAppearance.configuredKeys(fromGetRegexp: result.standardOutputString) : []
                diffColorConfiguredKeys = configured
            }
            let result = try await git.run(
                GitCommand(arguments: GitDiffAppearance.wordDiffCommand(patchArguments, configured: configured, reverse: options.reverseGitColoring),
                           accessesRemote: false, changesRepositoryState: false),
                in: directory
            )
            guard result.succeeded || result.exitStatus == 1 else {
                throw GitError.commandFailed(arguments: result.arguments, status: result.exitStatus, stderr: result.standardErrorString)
            }
            return GitDiffAppearance.parseWordDiff(result.standardOutput, file: file)
        }
    }

    package func loadDiff(for commit: Commit, file: ChangedFile, options: FileDiffOptions) async throws -> FileDiff? {
        let cacheKey = "\(commit.id.description)\u{0}\(file.id)\u{0}\(options.hashValue)"
        if let cached = diffCache[cacheKey] { return cached }
        guard let repository = resolvedRepository else {
            throw RepositoryDataSourceError.unavailable
        }

        var seenPaths = Set<String>()
        let paths = [file.oldPath, file.path].compactMap { $0 }.filter { seenPaths.insert($0).inserted }
        let arguments: [String]
        var acceptedStatuses: Set<Int32> = [0]
        let difftastic: () async throws -> (revisions: [String], paths: [String], noIndex: Bool)
        switch commit.kind {
        case .revision:
            guard let objectID = commit.objectID else { throw RepositoryDataSourceError.unavailable }
            if commit.references.contains(where: { $0.kind == .stash }) {
                let untrackedObject = try await checked(
                    GitCommand(arguments: ["cat-file", "-e", "\(objectID.string)^3:\(file.path)"], accessesRemote: false, changesRepositoryState: false),
                    directory: repository.rootURL,
                    acceptedStatuses: [0, 1, 128]
                )
                if untrackedObject.succeeded {
                    arguments = ["show", "--format=", "--patch", "--no-color"] + options.gitArguments + ["\(objectID.string)^3", "--"] + paths
                    difftastic = { [self] in ([try await emptyTreeID(in: repository.rootURL), "\(objectID.string)^3"], paths, false) }
                } else {
                    arguments = ["diff", "--no-ext-diff", "--patch", "--no-color"] + options.gitArguments + ["\(objectID.string)^1", objectID.string, "--"] + paths
                    difftastic = { (["\(objectID.string)^1", objectID.string], paths, false) }
                }
            } else {
                arguments = revisionDiffArguments(commit: commit).patch + options.gitArguments + ["--"] + paths
                if let parent = commit.parentIDs.first {
                    difftastic = { ([parent.string, objectID.string], paths, false) }
                } else {
                    difftastic = { [self] in ([try await emptyTreeID(in: repository.rootURL), objectID.string], paths, false) }
                }
            }
        case .index:
            arguments = diffBaseArguments() + ["--cached", "--patch", "--no-color"] + options.gitArguments + ["--"] + paths
            difftastic = { (["--cached"], paths, false) }
        case .workingDirectory:
            if statusRecords.contains(where: { $0.path == file.path && $0.isUntracked }) {
                arguments = ["diff", "--no-ext-diff", "--no-index", "--patch", "--no-color"] + options.gitArguments + ["--", "/dev/null", file.path]
                acceptedStatuses = [0, 1]
                difftastic = { ([], ["/dev/null", file.path], true) }
            } else {
                arguments = diffBaseArguments() + ["--patch", "--no-color"] + options.gitArguments + ["--"] + paths
                difftastic = { ([], paths, false) }
            }
        }
        if let diff = try await appearanceDiff(file: file, options: options, patchArguments: arguments,
                                               difftastic: difftastic, directory: repository.rootURL) {
            diffCache[cacheKey] = diff
            return diff
        }
        let output = try await checked(
            GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: false),
            directory: repository.rootURL,
            acceptedStatuses: acceptedStatuses
        )

        let parsed = GitOutputParser.parseUnifiedDiff(output.standardOutput, files: [file])
        let diff = parsed[file.id] ?? parsed.values.first
        if let diff { diffCache[cacheKey] = diff }
        return diff
    }

    package func loadFileContent(for commit: Commit, file: RepositoryFileEntry) async throws -> RepositoryFileEntry {
        let data = try await loadFileData(for: commit, file: file)
        let content = FileContentDecoder.decode(data, path: file.path, requestedEncoding: .automatic).text
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

    package func loadFilePresentation(
        for commit: Commit,
        file: RepositoryFileEntry,
        encoding: RepositoryTextEncoding
    ) async throws -> RepositoryFileContent {
        let data = try await loadFileData(for: commit, file: file)
        let configured = encoding == .automatic ? try await configuredFileEncoding() : nil
        return FileContentDecoder.decode(data, path: file.path, requestedEncoding: encoding, configuredEncoding: configured)
    }

    package func openWithDifftool(for commit: Commit, file: ChangedFile, customToolPath: String?) async throws {
        guard let repository = resolvedRepository else {
            throw RepositoryDataSourceError.unavailable
        }

        _ = try await checked(
            FileViewerCommandBuilder.difftool(commit: commit, file: file, customToolPath: customToolPath),
            directory: repository.rootURL
        )
    }

    private func loadFileData(for commit: Commit, file: RepositoryFileEntry) async throws -> Data {
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
            data = Data("Submodule commit \(file.gitObjectID?.string ?? "unknown")\n".utf8)
        } else if let objectID = file.gitObjectID {
            data = try await checked(
                GitCommand(arguments: ["cat-file", "blob", objectID.string], accessesRemote: false, changesRepositoryState: false),
                directory: repository.rootURL
            ).standardOutput
        } else {
            throw GitError.fileUnavailable(file.path)
        }

        return data
    }

    func resolveRepository(at url: URL) async throws -> ResolvedGitRepository {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GitError.invalidRepository(url.path)
        }

        let probe = await result(GitCommand(arguments: ["rev-parse", "--absolute-git-dir"], accessesRemote: false, changesRepositoryState: false), directory: url)
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

        let bareResult = try await checked(GitCommand(arguments: ["rev-parse", "--is-bare-repository"], accessesRemote: false, changesRepositoryState: false), directory: url)
        let isBare = bareResult.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        let rootURL: URL
        if isBare {
            rootURL = url.standardizedFileURL
        } else {
            let rootResult = try await checked(GitCommand(arguments: ["rev-parse", "--show-toplevel"], accessesRemote: false, changesRepositoryState: false), directory: url)
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

    private func loadStashes(repository: ResolvedGitRepository) async throws -> [GitStashRecord] {
        let output = try await checked(
            GitCommand(
                arguments: [
                    "stash", "list", "-z",
                    "--format=%gd%x00%H%x00%P%x00%at%x00%ct%x00%aN%x00%aE%x00%cN%x00%cE%x00%gs"
                ],
                accessesRemote: false,
                changesRepositoryState: false
            ),
            directory: repository.rootURL
        )
        return try GitOutputParser.parseStashes(output.standardOutput)
    }

    private func loadStatus(repository: ResolvedGitRepository) async throws -> [GitStatusRecord] {
        let output = try await checked(
            GitCommand(
                arguments: ["--no-optional-locks", "status", "--porcelain=2", "-z", "--untracked-files=all"],
                accessesRemote: false,
                changesRepositoryState: false
            ),
            directory: repository.rootURL
        )
        return try GitOutputParser.parsePorcelainV2(output.standardOutput)
    }

    func loadSubmodules(repository: ResolvedGitRepository, recursive: Bool = false, parentPath: String = "") async throws -> [Submodule] {
        let modulesURL = repository.rootURL.appendingPathComponent(".gitmodules")
        guard FileManager.default.fileExists(atPath: modulesURL.path) else { return [] }

        let configResult = try await checked(
            GitCommand(
                arguments: [
                    "config", "--null", "--file", modulesURL.path,
                    "--get-regexp", "^submodule\\..*\\.(path|url)$"
                ],
                accessesRemote: false,
                changesRepositoryState: false
            ),
            directory: repository.rootURL,
            acceptedStatuses: [0, 1]
        )
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

        let statusResult = try await checked(
            GitCommand(arguments: ["submodule", "status"], accessesRemote: false, changesRepositoryState: false),
            directory: repository.rootURL
        )
        let statusLines = statusResult.standardOutputString.split(separator: "\n", omittingEmptySubsequences: true).compactMap { rawLine -> (prefix: Character, objectID: ObjectID, pathAndDescription: String)? in
            guard let prefix = rawLine.first else { return nil }
            let fields = rawLine.dropFirst().split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2,
                  let objectID = try? ObjectID.parse(String(fields[0]))
            else { return nil }
            return (prefix, objectID, String(fields[1]))
        }
        let modules: [Submodule] = config.values.compactMap { item in
            guard let path = item.path else { return nil }
            let matching = statusLines.first { record in
                let paths = config.values.compactMap(\.path).filter {
                    record.pathAndDescription == $0 || record.pathAndDescription.hasPrefix($0 + " (")
                }
                return paths.max(by: { $0.count < $1.count }) == path
            }
            guard matching != nil else { return nil }
            let prefix = matching?.prefix
            let commitID = matching.flatMap { $0.objectID.string.allSatisfy { $0 == "0" } ? nil : $0.objectID }
            let description = matching.flatMap { record -> String? in
                let remainder = String(record.pathAndDescription.dropFirst(path.count)).trimmingCharacters(in: .whitespaces)
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
        let index = try await checked(GitCommand(arguments: ["ls-files", "--stage", "-z"], accessesRemote: false, changesRepositoryState: false), directory: repository.rootURL)
        var expected: [String: ObjectID] = [:]
        for record in index.standardOutput.split(separator: 0) {
            guard let tab = record.firstIndex(of: 9) else { continue }
            let fields = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
            if fields.count == 3, fields[0] == "160000", fields[2] == "0", let id = try? ObjectID.parse(String(fields[1])) {
                expected[String(decoding: record[record.index(after: tab)...], as: UTF8.self)] = id
            }
        }
        var result: [Submodule] = []
        for module in modules {
            let path = parentPath.isEmpty ? module.path : parentPath + "/" + module.path
            let childURL = repository.rootURL.appendingPathComponent(module.path).standardizedFileURL
            let inside = childURL.resolvingSymlinksInPath().path.hasPrefix(repository.rootURL.resolvingSymlinksInPath().path + "/")
            let initialized = inside && module.state != .uninitialized && FileManager.default.fileExists(atPath: childURL.appendingPathComponent(".git").path)
            var dirty = false
            if initialized {
                let status = try await git.run(GitCommand(arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all"], accessesRemote: false, changesRepositoryState: false), in: childURL)
                dirty = status.succeeded && !status.standardOutput.isEmpty
            }
            result.append(Submodule(id: path, name: module.name, path: path, url: module.url, commitID: module.commitID,
                description: module.description, state: module.state, parentPath: parentPath, localPath: module.path, isDirty: dirty, expectedCommitID: expected[module.path]))
            if recursive && initialized {
                let child = try await resolveRepository(at: childURL)
                result += try await loadSubmodules(repository: child, recursive: true, parentPath: path)
            }
        }
        return result
    }

    private func makeRefs(records: [GitRefRecord], currentBranch: String, headID: ObjectID?) -> (
        localBranches: [Branch], remoteBranches: [Branch], tags: [Tag], referencesByCommit: [ObjectID: [RevisionReference]]
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
        var references: [ObjectID: [RevisionReference]] = [:]

        for record in filteredRecords {
            if record.fullName.hasPrefix("refs/heads/") {
                let name = String(record.fullName.dropFirst("refs/heads/".count))
                let counts = aheadBehind(record.upstreamTrack)
                let branch = Branch(
                    id: record.fullName, name: name, commitID: record.objectID,
                    isCurrent: name == currentBranch, isRemote: false,
                    remoteName: record.upstreamRemote, ahead: counts.ahead, behind: counts.behind,
                    sortMetadata: record.sortMetadata
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
                    isCurrent: false, isRemote: true, remoteName: pieces[0], ahead: 0, behind: 0,
                    sortMetadata: record.sortMetadata
                )
                remotes.append(branch)
                references[record.objectID, default: []].append(RevisionReference(id: record.fullName, name: combined, kind: .remoteBranch))
            } else if record.fullName.hasPrefix("refs/tags/") {
                let name = String(record.fullName.dropFirst("refs/tags/".count))
                let target = record.peeledObjectID ?? record.objectID
                tags.append(Tag(id: record.fullName, name: name, commitID: target, sortMetadata: record.sortMetadata))
                references[target, default: []].append(RevisionReference(id: record.fullName, name: name, kind: .tag,
                                                                         isAnnotated: record.peeledObjectID != nil))
            } else if record.fullName.hasPrefix("refs/bisect/bad") || record.fullName.hasPrefix("refs/bisect/good") {
                references[record.objectID, default: []].append(RevisionReference(
                    id: record.fullName, name: String(record.fullName.dropFirst("refs/bisect/".count)),
                    kind: record.fullName.hasPrefix("refs/bisect/bad") ? .bisectBad : .bisectGood))
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
                behind: trackingLocal.ahead,
                sortMetadata: remoteBranch.sortMetadata
            )
        }

        return (
            locals.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            remotes.sorted { ($0.remoteName ?? "", $0.name) < ($1.remoteName ?? "", $1.name) },
            tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            references
        )
    }

    private func makeRemotes(
        output: String,
        branches: [Branch],
        configurations: [RepositoryRemoteConfiguration]
    ) -> [Remote] {
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
        let activeConfigurations = configurations.filter { !$0.isDisabled }
        let names = Set(fetchURLs.keys)
            .union(branches.compactMap(\.remoteName))
            .union(activeConfigurations.map(\.name))
        let active = names.sorted().map { name in
            Remote(
                id: name,
                name: name,
                fetchURL: fetchURLs[name]
                    ?? activeConfigurations.first(where: { $0.name == name })?.fetchURL
                    ?? "",
                branches: branches.filter { $0.remoteName == name }
            )
        }
        let inactive = configurations.filter(\.isDisabled).map { remote in
            Remote(
                id: "inactive:\(remote.name)",
                name: remote.name,
                fetchURL: remote.fetchURL,
                branches: [],
                isDisabled: true
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return active + inactive
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

    func makeWorktrees(output: Data, repository: ResolvedGitRepository) throws -> [Worktree] {
        try GitOutputParser.parseWorktrees(output).enumerated().map { index, record in
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
                isCurrent: pathURL.resolvingSymlinksInPath() == repository.rootURL.resolvingSymlinksInPath(),
                headID: record.headID,
                isMain: index == 0,
                isBare: record.isBare,
                isDetached: record.isDetached,
                isDeleted: !FileManager.default.fileExists(atPath: pathURL.path)
            )
        }
    }

    private func revisionDiffArguments(commit: Commit) -> (nameStatus: [String], numstat: [String], patch: [String]) {
        guard let objectID = commit.objectID else { return ([], [], []) }
        if let parent = commit.parentIDs.first {
            let base = diffBaseArguments()
            return (
                base + ["--name-status", "-z", parent.string, objectID.string],
                base + ["--numstat", "-z", parent.string, objectID.string],
                base + ["--patch", "--no-color", parent.string, objectID.string]
            )
        }
        let base = ["diff-tree", "--root", "--no-commit-id", "-r", "--no-ext-diff", "--find-renames", "--find-copies"]
        return (
            base + ["--name-status", "-z", objectID.string],
            base + ["--numstat", "-z", objectID.string],
            base + ["--patch", "--no-color", objectID.string]
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
            guard let objectID = commit.objectID else { throw RepositoryDataSourceError.unavailable }
            let output = try await checked(
                GitCommand(arguments: ["ls-tree", "-r", "-z", "--long", objectID.string], accessesRemote: false, changesRepositoryState: false),
                directory: repository.rootURL
            )
            records = try GitOutputParser.parseTree(output.standardOutput)
        case .index:
            let output = try await checked(
                GitCommand(arguments: ["ls-files", "-s", "-z"], accessesRemote: false, changesRepositoryState: false),
                directory: repository.rootURL
            )
            records = try GitOutputParser.parseIndexTree(output.standardOutput)
        case .workingDirectory:
            let indexOutput = try await checked(
                GitCommand(arguments: ["ls-files", "-s", "-z"], accessesRemote: false, changesRepositoryState: false),
                directory: repository.rootURL
            )
            var indexed = try GitOutputParser.parseIndexTree(indexOutput.standardOutput)
            let deletedPaths = Set(statusRecords.filter { $0.worktreeStatus == "D" }.map(\.path))
            indexed.removeAll { deletedPaths.contains($0.path) }
            let untrackedOutput = try await checked(
                GitCommand(arguments: ["ls-files", "--others", "--exclude-standard", "-z"], accessesRemote: false, changesRepositoryState: false),
                directory: repository.rootURL
            )
            let untracked = [UInt8](untrackedOutput.standardOutput).split(separator: 0).map { raw in
                GitTreeRecord(mode: "100644", objectType: "working-tree", objectID: nil, byteCount: 0, path: String(decoding: raw, as: UTF8.self))
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
                gitObjectID: record.objectID,
                gitObjectType: record.objectType
            )
        }
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

    private func checked(
        _ command: GitCommand,
        directory: URL,
        acceptedStatuses: Set<Int32> = [0]
    ) async throws -> GitCommandResult {
        let commandResult = try await git.run(command, in: directory)
        guard acceptedStatuses.contains(commandResult.exitStatus) else {
            throw GitError.commandFailed(
                arguments: command.arguments,
                status: commandResult.exitStatus,
                stderr: commandResult.standardErrorString
            )
        }
        return commandResult
    }

    private func result(_ command: GitCommand, directory: URL) async -> GitCommandResult {
        do {
            return try await git.run(command, in: directory)
        } catch {
            return GitCommandResult(arguments: command.arguments, standardOutput: Data(), standardError: Data(error.localizedDescription.utf8), exitStatus: -1, executionClass: command.executionClass)
        }
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> Substring {
        hasPrefix(prefix) ? dropFirst(prefix.count) : self[...]
    }
}
