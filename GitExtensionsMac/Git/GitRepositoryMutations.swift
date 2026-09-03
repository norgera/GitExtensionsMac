import GitExtensionsCore
import CoreFoundation
import Foundation

package enum CheckoutLocalChangesAction: Hashable, Sendable {
    case keep
    case merge
    case stash(includeUntracked: Bool, reapply: Bool)
    case force
}

package enum RemoteCheckoutMode: Hashable, Sendable {
    case createTracking(localBranch: String)
    case resetTracking(localBranch: String)
    case detached
}

package enum RepositoryCheckoutTarget: Hashable, Sendable {
    case localBranch(String)
    case remoteBranch(remote: String, branch: String, mode: RemoteCheckoutMode)
    case revision(String)
}

package struct RepositoryCheckoutRequest: Hashable, Sendable {
    package let target: RepositoryCheckoutTarget
    package let localChanges: CheckoutLocalChangesAction
    package let updateSubmodulesAfterCheckout: Bool

    package init(
        target: RepositoryCheckoutTarget,
        localChanges: CheckoutLocalChangesAction,
        updateSubmodulesAfterCheckout: Bool = false
    ) {
        self.target = target
        self.localChanges = localChanges
        self.updateSubmodulesAfterCheckout = updateSubmodulesAfterCheckout
    }
}

package enum RepositoryHunkDirection: Hashable, Sendable {
    case stage
    case unstage
}

package struct RepositoryHunkSelection: Hashable, Sendable {
    package let file: ChangedFile
    package let diff: FileDiff
    package let lineID: String
    package let direction: RepositoryHunkDirection

    package init(file: ChangedFile, diff: FileDiff, lineID: String, direction: RepositoryHunkDirection) {
        self.file = file
        self.diff = diff
        self.lineID = lineID
        self.direction = direction
    }
}

package struct RepositoryLineSelection: Hashable, Sendable {
    package let file: ChangedFile
    package let diff: FileDiff
    package let lineIDs: Set<String>
    package let direction: RepositoryHunkDirection

    package init(file: ChangedFile, diff: FileDiff, lineIDs: Set<String>, direction: RepositoryHunkDirection) {
        self.file = file
        self.diff = diff
        self.lineIDs = lineIDs
        self.direction = direction
    }
}

package enum RepositoryCommitMode: Hashable, Sendable {
    case normal
    case amend
    case amendMessageOnly
}

package enum RepositoryCommitGPGSigning: Hashable, Sendable {
    case gitDefault
    case doNotSign
    case signDefault
    case signSpecificKey(String)
}

package struct RepositoryCommitRequest: Hashable, Sendable {
    package let message: String
    package let mode: RepositoryCommitMode
    package let stageAllBeforeCommit: Bool
    package let allowEmpty: Bool
    package let signOff: Bool
    package let author: String?
    package let resetAuthor: Bool
    package let noVerify: Bool
    package let gpgSigning: RepositoryCommitGPGSigning
    package let messageEncoding: String?
    package let usingTemplate: Bool
    package let ensureSecondLineEmpty: Bool

    package init(
        message: String,
        mode: RepositoryCommitMode,
        stageAllBeforeCommit: Bool,
        allowEmpty: Bool,
        signOff: Bool,
        author: String?,
        resetAuthor: Bool,
        noVerify: Bool = false,
        gpgSigning: RepositoryCommitGPGSigning = .gitDefault,
        messageEncoding: String? = nil,
        usingTemplate: Bool = false,
        ensureSecondLineEmpty: Bool = true
    ) {
        self.message = message
        self.mode = mode
        self.stageAllBeforeCommit = stageAllBeforeCommit
        self.allowEmpty = allowEmpty
        self.signOff = signOff
        self.author = author
        self.resetAuthor = resetAuthor
        self.noVerify = noVerify
        self.gpgSigning = gpgSigning
        self.messageEncoding = messageEncoding
        self.usingTemplate = usingTemplate
        self.ensureSecondLineEmpty = ensureSecondLineEmpty
    }
}

package struct RepositoryCommitState: Sendable {
    package let mutationState: RepositoryMutationState
    package let message: String
    package let loadedTemplate: String?
    package let commitEncoding: String
    package let previousMessages: [String]
    package let committer: String
    package let isMergeCommit: Bool
    package let rememberedAmend: Bool
    package let messageLoadError: String?
}

package enum RepositoryResetChangesScope: Hashable, Sendable {
    case worktree
    case all
}

package struct RepositoryResetChangesRequest: Hashable, Sendable {
    package let scope: RepositoryResetChangesScope
    package let deleteUntracked: Bool

    package init(scope: RepositoryResetChangesScope, deleteUntracked: Bool) {
        self.scope = scope
        self.deleteUntracked = deleteUntracked
    }
}

package struct RepositoryStashCreateRequest: Hashable, Sendable {
    package let message: String
    package let includeUntracked: Bool
    package let keepIndex: Bool
    package let stagedOnly: Bool
    package let selectedPaths: [String]

    package init(
        message: String,
        includeUntracked: Bool,
        keepIndex: Bool,
        stagedOnly: Bool,
        selectedPaths: [String] = []
    ) {
        self.message = message
        self.includeUntracked = includeUntracked
        self.keepIndex = keepIndex
        self.stagedOnly = stagedOnly
        self.selectedPaths = selectedPaths
    }
}

package struct RepositoryCherryPickItem: Hashable, Sendable {
    package let commitID: ObjectID
    package let mainlineParent: Int?

    package init(commitID: ObjectID, mainlineParent: Int?) {
        self.commitID = commitID
        self.mainlineParent = mainlineParent
    }
}

package struct RepositoryCherryPickOptions: Hashable, Sendable {
    package let automaticallyCommit: Bool
    package let addReference: Bool

    package init(automaticallyCommit: Bool, addReference: Bool) {
        self.automaticallyCommit = automaticallyCommit
        self.addReference = addReference
    }
}

package struct RepositoryCherryPickRequest: Hashable, Sendable {
    package let items: [RepositoryCherryPickItem]
    package let options: RepositoryCherryPickOptions

    package init(items: [RepositoryCherryPickItem], options: RepositoryCherryPickOptions) {
        self.items = items
        self.options = options
    }
}

package enum RepositoryRebaseTodoAction: Hashable, Sendable {
    case pick
    case reword(String)
    case edit
    case squash
    case fixup
    case drop
}

package struct RepositoryRebaseTodoItem: Hashable, Sendable {
    package let commitID: ObjectID
    package let subject: String
    package let action: RepositoryRebaseTodoAction

    package init(commitID: ObjectID, subject: String, action: RepositoryRebaseTodoAction) {
        self.commitID = commitID
        self.subject = subject
        self.action = action
    }
}

package struct RepositoryRebaseRequest: Hashable, Sendable {
    package let upstream: String
    package let autoStash: Bool
    package let rebaseMerges: Bool
    package let updateRefs: Bool?
    package let ignoreDate: Bool
    package let committerDateIsAuthorDate: Bool
    package let onto: String?
    package let from: String?
    package let branch: String?

    package init(
        upstream: String,
        autoStash: Bool,
        rebaseMerges: Bool = false,
        updateRefs: Bool? = nil,
        ignoreDate: Bool = false,
        committerDateIsAuthorDate: Bool = false,
        onto: String? = nil,
        from: String? = nil,
        branch: String? = nil
    ) {
        self.upstream = upstream
        self.autoStash = autoStash
        self.rebaseMerges = rebaseMerges
        self.updateRefs = updateRefs
        self.ignoreDate = ignoreDate
        self.committerDateIsAuthorDate = committerDateIsAuthorDate
        self.onto = onto
        self.from = from
        self.branch = branch
    }
}

package struct RepositoryInteractiveRebaseRequest: Hashable, Sendable {
    package let upstream: String
    package let items: [RepositoryRebaseTodoItem]
    package let autoStash: Bool
    package let autoSquash: Bool
    package let rebaseMerges: Bool
    package let updateRefs: Bool?
    package let onto: String?
    package let from: String?
    package let branch: String?
    package let nativeTodo: String?

    package init(
        upstream: String,
        items: [RepositoryRebaseTodoItem],
        autoStash: Bool,
        autoSquash: Bool = false,
        rebaseMerges: Bool = false,
        updateRefs: Bool? = nil,
        onto: String? = nil,
        from: String? = nil,
        branch: String? = nil,
        nativeTodo: String? = nil
    ) {
        self.upstream = upstream
        self.items = items
        self.autoStash = autoStash
        self.autoSquash = autoSquash
        self.rebaseMerges = rebaseMerges
        self.updateRefs = updateRefs
        self.onto = onto
        self.from = from
        self.branch = branch
        self.nativeTodo = nativeTodo
    }
}

package struct RepositoryInteractiveRebaseTodoRequest: Hashable, Sendable {
    package let upstream: String
    package let autoStash: Bool
    package let autoSquash: Bool
    package let rebaseMerges: Bool
    package let updateRefs: Bool?
    package let onto: String?
    package let from: String?
    package let branch: String?

    package init(
        upstream: String,
        autoStash: Bool,
        autoSquash: Bool,
        rebaseMerges: Bool,
        updateRefs: Bool?,
        onto: String?,
        from: String?,
        branch: String?
    ) {
        self.upstream = upstream
        self.autoStash = autoStash
        self.autoSquash = autoSquash
        self.rebaseMerges = rebaseMerges
        self.updateRefs = updateRefs
        self.onto = onto
        self.from = from
        self.branch = branch
    }
}

package enum RepositoryRebasePatchStatus: String, Hashable, Sendable {
    case applied = "Applied"
    case applying = "Applying…"
    case pending = ""
    case skipped = "Skipped"
}

package struct RepositoryRebasePatch: Hashable, Sendable {
    package let action: String
    package let revisionToken: String
    package let subject: String
    package let author: String
    package let date: String
    package let status: RepositoryRebasePatchStatus
}

package struct RepositoryRebaseState: Hashable, Sendable {
    package let inProgress: Bool
    package let hasConflicts: Bool
    package let currentBranch: String?
    package let currentCommitID: ObjectID?
    package let patches: [RepositoryRebasePatch]
    package let canEditTodo: Bool
    package let hasAutoStash: Bool

    package init(
        inProgress: Bool,
        hasConflicts: Bool,
        currentBranch: String?,
        currentCommitID: ObjectID?,
        patches: [RepositoryRebasePatch],
        canEditTodo: Bool,
        hasAutoStash: Bool
    ) {
        self.inProgress = inProgress
        self.hasConflicts = hasConflicts
        self.currentBranch = currentBranch
        self.currentCommitID = currentCommitID
        self.patches = patches
        self.canEditTodo = canEditTodo
        self.hasAutoStash = hasAutoStash
    }
}

package struct RepositoryRebaseConfiguration: Hashable, Sendable {
    package let autoSquash: Bool
    package let updateRefs: Bool
    package let supportsUpdateRefs: Bool
    package let isDirty: Bool
}

package struct RepositoryMergeToolConfiguration: Hashable, Sendable {
    package let name: String
    package let usesGUISetting: Bool
    package let availableTools: [String]
    package let trustExitCode: Bool

    package init(
        name: String,
        usesGUISetting: Bool,
        availableTools: [String] = [],
        trustExitCode: Bool = false
    ) {
        self.name = name
        self.usesGUISetting = usesGUISetting
        self.availableTools = availableTools
        self.trustExitCode = trustExitCode
    }
}

package enum RepositoryConflictSide: Int, CaseIterable, Hashable, Sendable {
    case base = 1
    case local = 2
    case remote = 3
}

package struct RepositoryConflictVersion: Hashable, Sendable {
    package let objectID: ObjectID
    package let mode: String
    package let path: String
}

package enum RepositoryConflictKind: String, Hashable, Sendable {
    case bothModified
    case bothAdded
    case deletedLocally
    case deletedRemotely
    case unmerged
}

package struct RepositoryConflict: Hashable, Sendable {
    package let path: String
    package let base: RepositoryConflictVersion?
    package let local: RepositoryConflictVersion?
    package let remote: RepositoryConflictVersion?
    package let kind: RepositoryConflictKind

    package var isSubmodule: Bool {
        [base, local, remote].compactMap { $0 }.contains { $0.mode == "160000" }
    }

    package func version(for side: RepositoryConflictSide) -> RepositoryConflictVersion? {
        switch side {
        case .base: base
        case .local: local
        case .remote: remote
        }
    }
}

package struct RepositoryMutationState: Equatable, Sendable {
    package let currentBranch: String?
    package let headID: ObjectID?
    package let hasStagedChanges: Bool
    package let hasUnstagedChanges: Bool
    package let hasUntrackedFiles: Bool
    package let conflictedPaths: [String]
    package let mergeInProgress: Bool
    package let cherryPickInProgress: Bool
    package let revertInProgress: Bool
    package let rebaseInProgress: Bool

    package var isDirty: Bool {
        hasStagedChanges || hasUnstagedChanges || hasUntrackedFiles || !conflictedPaths.isEmpty
    }
}

package enum RepositoryMutationOutcome: Equatable, Sendable {
    case completed
    case conflicts([String])
    case paused(String)
}

package struct RepositoryMutationResult: Sendable {
    package let selectedCommitID: RevisionID?
    package let outcome: RepositoryMutationOutcome
    package let message: String

    package init(selectedCommitID: RevisionID?, outcome: RepositoryMutationOutcome, message: String) {
        self.selectedCommitID = selectedCommitID
        self.outcome = outcome
        self.message = message
    }
}

package enum RepositoryMutationError: LocalizedError, Sendable {
    case bareRepository
    case currentBranch(String)
    case invalidRevision(String)
    case invalidBranchName(String)
    case noPaths
    case hunkUnavailable
    case lineSelectionUnavailable
    case emptyCommitMessage
    case nothingStaged
    case invalidAuthor(String)
    case invalidCommitEncoding(String)
    case commitMessageNotRepresentable(String)
    case configuredTemplateMissing(String)
    case unresolvedConflicts([String])
    case invalidStash(String)
    case noStashes
    case noRevisions
    case invalidMainline(commitID: ObjectID, parent: Int?, parentCount: Int)
    case cherryPickNotInProgress
    case mergeNotInProgress
    case mergeToolNotConfigured
    case operationInProgress(String)
    case rebaseNotInProgress
    case emptyRebasePlan
    case invalidRebasePlan(String)
    case unavailable

    package var errorDescription: String? {
        switch self {
        case .bareRepository:
            "This operation is unavailable in a bare repository."
        case .currentBranch(let branch):
            "The branch ‘\(branch)’ is already checked out."
        case .invalidRevision(let revision):
            "The revision ‘\(revision)’ cannot be checked out."
        case .invalidBranchName(let name):
            "‘\(name)’ is not a valid local branch name."
        case .noPaths:
            "Select at least one file."
        case .hunkUnavailable:
            "The selected diff line is not part of an applicable hunk."
        case .lineSelectionUnavailable:
            "Select at least one added or removed diff line."
        case .emptyCommitMessage:
            "Please enter a commit message."
        case .nothingStaged:
            "There are no staged changes to commit."
        case .invalidAuthor(let author):
            "Author must use the format Name <email@example.com>; received ‘\(author)’."
        case .invalidCommitEncoding(let encoding):
            "The configured commit encoding ‘\(encoding)’ is not supported."
        case .commitMessageNotRepresentable(let encoding):
            "The commit message contains characters that cannot be represented using \(encoding)."
        case .configuredTemplateMissing(let path):
            "The configured commit template could not be found at \(path)."
        case .unresolvedConflicts(let paths):
            "Resolve and stage all conflicts before committing: \(paths.joined(separator: ", "))"
        case .invalidStash(let selector):
            "The stash ‘\(selector)’ no longer exists."
        case .noStashes:
            "There are no stashes to pop."
        case .noRevisions:
            "Select at least one real revision."
        case .invalidMainline(let commitID, let parent, let parentCount):
            if parentCount > 1 {
                "Cherry-picking merge \(commitID.shortString) requires a mainline parent from 1 through \(parentCount); received \(parent.map(String.init) ?? "none")."
            } else {
                "Revision \(commitID.shortString) is not a merge and cannot use a mainline parent."
            }
        case .cherryPickNotInProgress:
            "No cherry-pick is currently in progress."
        case .mergeNotInProgress:
            "No merge is currently in progress."
        case .mergeToolNotConfigured:
            "There is no merge tool configured. Configure merge.guitool or merge.tool in Git settings."
        case .operationInProgress(let operation):
            "Cannot start this operation while \(operation) is in progress."
        case .rebaseNotInProgress:
            "No rebase is currently in progress."
        case .emptyRebasePlan:
            "There are no commits to rebase onto the selected revision."
        case .invalidRebasePlan(let reason):
            "The interactive rebase plan is invalid: \(reason)"
        case .unavailable:
            "Repository mutation is currently unavailable."
        }
    }
}

package protocol RepositoryMutationStateDataSource: RepositoryBrowsingDataSource {
    func loadMutationState() async throws -> RepositoryMutationState
}

package protocol RepositoryStagingDataSource: RepositoryMutationStateDataSource {
    func stage(paths: [String]) async throws -> RepositoryMutationResult
    func unstage(paths: [String]) async throws -> RepositoryMutationResult
    func stageAll() async throws -> RepositoryMutationResult
    func unstageAll() async throws -> RepositoryMutationResult
    func applyHunk(_ selection: RepositoryHunkSelection) async throws -> RepositoryMutationResult
    func applyLines(_ selection: RepositoryLineSelection) async throws -> RepositoryMutationResult
    func resetChanges(_ request: RepositoryResetChangesRequest) async throws -> RepositoryMutationResult
}

package protocol RepositoryCommitDataSource: RepositoryStagingDataSource {
    func loadCommitState(historyLimit: Int, showOnlyMyMessages: Bool, rememberAmend: Bool) async throws -> RepositoryCommitState
    func saveCommitDraft(message: String, amend: Bool, rememberAmend: Bool, encoding: String?) async throws
    func commit(_ request: RepositoryCommitRequest) async throws -> RepositoryMutationResult
    func resetSoftToParent() async throws -> RepositoryMutationResult
}

package protocol RepositoryStashDataSource: RepositoryMutationStateDataSource {
    func createStash(_ request: RepositoryStashCreateRequest) async throws -> RepositoryMutationResult
    func applyStash(_ stash: Stash) async throws -> RepositoryMutationResult
    func popStash(_ stash: Stash?) async throws -> RepositoryMutationResult
    func dropStash(_ stash: Stash) async throws -> RepositoryMutationResult
}

package protocol RepositoryConflictDataSource: RepositoryMutationStateDataSource {
    func abortMerge() async throws -> RepositoryMutationResult
    func loadConflicts() async throws -> [RepositoryConflict]
    func loadConflictContent(
        path: String,
        side: RepositoryConflictSide,
        encoding: RepositoryTextEncoding
    ) async throws -> RepositoryFileContent?
    func conflictWorkingTreeURL(path: String) async throws -> URL
    func chooseConflictSide(paths: [String], side: RepositoryConflictSide) async throws -> RepositoryMutationResult
    func loadMergeToolConfiguration() async throws -> RepositoryMergeToolConfiguration?
    func runMergeTool(paths: [String], tool: String?) async throws -> RepositoryMutationResult
}

package extension RepositoryConflictDataSource {
    func runMergeTool(paths: [String]) async throws -> RepositoryMutationResult {
        try await runMergeTool(paths: paths, tool: nil)
    }
}

package protocol RepositoryConflictResolutionDataSource: RepositoryCommitDataSource, RepositoryConflictDataSource {}

package protocol RepositoryCherryPickDataSource: RepositoryConflictResolutionDataSource {
    func cherryPick(_ request: RepositoryCherryPickRequest) async throws -> RepositoryMutationResult
    func continueCherryPick() async throws -> RepositoryMutationResult
    func abortCherryPick() async throws -> RepositoryMutationResult
}

package protocol RepositoryRebaseDataSource: RepositoryConflictResolutionDataSource {
    func loadInteractiveRebasePlan(upstream: String) async throws -> [RepositoryRebaseTodoItem]
    func loadNativeInteractiveRebaseTodo(_ request: RepositoryInteractiveRebaseTodoRequest) async throws -> String
    func loadRebaseConfiguration() async throws -> RepositoryRebaseConfiguration
    func loadRebaseState() async throws -> RepositoryRebaseState
    func rebase(_ request: RepositoryRebaseRequest) async throws -> RepositoryMutationResult
    func interactiveRebase(_ request: RepositoryInteractiveRebaseRequest) async throws -> RepositoryMutationResult
    func editRebaseTodo(_ items: [RepositoryRebaseTodoItem]) async throws -> RepositoryRebaseState
    func loadRebaseTodoText() async throws -> String
    func editRebaseTodoText(_ todo: String) async throws -> RepositoryRebaseState
    func continueRebase() async throws -> RepositoryMutationResult
    func skipRebase() async throws -> RepositoryMutationResult
    func abortRebase() async throws -> RepositoryMutationResult
}

package protocol RepositoryCommitWorkflowDataSource:
    RepositoryCheckoutBranchDataSource,
    RepositoryConflictResolutionDataSource,
    RepositoryStashDataSource {}

package protocol RepositoryStashWorkflowDataSource:
    RepositoryStashDataSource,
    RepositoryConflictResolutionDataSource {}

package protocol RepositoryBrowserMutationDataSource:
    RepositoryCommitWorkflowDataSource,
    RepositoryCherryPickDataSource,
    RepositoryRebaseDataSource {}

extension GitRepositoryModule: RepositoryBrowserMutationDataSource, RepositoryStashWorkflowDataSource {
    package func loadMutationState() async throws -> RepositoryMutationState {
        guard let repository = resolvedRepository else {
            throw RepositoryMutationError.unavailable
        }
        if repository.isBare { throw RepositoryMutationError.bareRepository }
        return try await mutationState(in: repository)
    }

    package func checkout(_ request: RepositoryCheckoutRequest) async throws -> RepositoryMutationResult {
        guard let repository = resolvedRepository else {
            throw RepositoryMutationError.unavailable
        }
        if repository.isBare { throw RepositoryMutationError.bareRepository }

        let before = try await mutationState(in: repository)
        var createdStash = false
        var shouldReapplyStash = false

        if case .stash(let includeUntracked, let reapply) = request.localChanges, before.isDirty {
            var stashArguments = ["stash", "push"]
            if includeUntracked { stashArguments.append("--include-untracked") }
            stashArguments += ["--message", "GitExtensionsMac automatic checkout stash"]
            _ = try await checkedMutation(stashArguments, in: repository)
            createdStash = true
            shouldReapplyStash = reapply
        }

        let checkoutArguments = try await checkoutArguments(for: request, state: before, repository: repository)
        do {
            _ = try await checkedMutation(checkoutArguments, in: repository)
        } catch {
            throw error
        }

        if request.updateSubmodulesAfterCheckout,
           before.headID != (try await mutationState(in: repository)).headID {
            _ = try await checkedMutation(["submodule", "update", "--init", "--recursive"], in: repository)
        }

        var outcome: RepositoryMutationOutcome = .completed
        var message = "Checkout completed."
        if createdStash, shouldReapplyStash {
            let pop = try await rawMutation(["stash", "pop"], in: repository)
            if !pop.succeeded {
                let state = try await mutationState(in: repository)
                if !state.conflictedPaths.isEmpty {
                    outcome = .conflicts(state.conflictedPaths)
                    message = pop.standardErrorString.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    throw commandError(from: pop)
                }
            }
        }

        let selectedID = try await mutationState(in: repository).headID
        return RepositoryMutationResult(
            selectedCommitID: selectedID.map(RevisionID.object),
            outcome: outcome,
            message: message
        )
    }

    package func stage(paths: [String]) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let paths = normalizedPaths(paths)
        guard !paths.isEmpty else { throw RepositoryMutationError.noPaths }
        var applicablePaths: [String] = []
        for path in paths {
            let worktreeURL = repository.rootURL.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: worktreeURL.path) {
                applicablePaths.append(path)
                continue
            }
            let tracked = try await rawMutation(["ls-files", "--error-unmatch", "--", path], in: repository)
            if tracked.succeeded { applicablePaths.append(path) }
        }
        guard !applicablePaths.isEmpty else { throw RepositoryMutationError.noPaths }
        _ = try await checkedMutation(["add", "--all", "--"] + applicablePaths, in: repository)
        return try await refreshedMutationResult(message: "Staged \(applicablePaths.count) path(s).", selectedCommitID: .workingDirectory)
    }

    package func unstage(paths: [String]) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let paths = normalizedPaths(paths)
        guard !paths.isEmpty else { throw RepositoryMutationError.noPaths }
        let state = try await mutationState(in: repository)
        if state.headID == nil {
            _ = try await checkedMutation(["rm", "--cached", "-r", "--ignore-unmatch", "--"] + paths, in: repository)
        } else {
            _ = try await checkedMutation(["reset", "--quiet", "HEAD", "--"] + paths, in: repository)
        }
        return try await refreshedMutationResult(message: "Unstaged \(paths.count) path(s).", selectedCommitID: .index)
    }

    package func stageAll() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        _ = try await checkedMutation(["add", "--all", "--"], in: repository)
        return try await refreshedMutationResult(message: "Staged all changes.", selectedCommitID: .workingDirectory)
    }

    package func unstageAll() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        if state.headID == nil {
            _ = try await checkedMutation(["rm", "--cached", "-r", "--ignore-unmatch", "--", "."], in: repository)
        } else {
            _ = try await checkedMutation(["reset", "--mixed", "--quiet", "HEAD"], in: repository)
        }
        return try await refreshedMutationResult(message: "Unstaged all changes.", selectedCommitID: .index)
    }

    package func applyHunk(_ selection: RepositoryHunkSelection) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        guard let patch = GitHunkPatchBuilder.patch(from: selection.diff, containing: selection.lineID) else {
            throw RepositoryMutationError.hunkUnavailable
        }
        var arguments = ["apply", "--cached", "--index", "--whitespace=nowarn"]
        if selection.direction == .unstage { arguments.append("--reverse") }
        let result = try await git.run(
            GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: true),
            in: repository.rootURL,
            standardInput: patch,
            environment: [:]
        )
        guard result.succeeded else { throw commandError(from: result) }
        let verb = selection.direction == .stage ? "Staged" : "Unstaged"
        let selectedID: RevisionID = selection.direction == .stage ? .workingDirectory : .index
        return try await refreshedMutationResult(message: "\(verb) selected hunk in \(selection.file.path).", selectedCommitID: selectedID)
    }

    package func applyLines(_ selection: RepositoryLineSelection) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        guard let patch = GitSelectedLinePatchBuilder.patch(
            from: selection.diff,
            selecting: selection.lineIDs,
            direction: selection.direction,
            isNewFile: selection.file.changeType == .added,
            isRenamedFile: selection.file.changeType == .renamed
        ) else {
            throw RepositoryMutationError.lineSelectionUnavailable
        }
        var arguments = ["apply", "--cached", "--index", "--whitespace=nowarn"]
        if selection.direction == .unstage { arguments.append("--reverse") }
        let result = try await git.run(
            GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: true),
            in: repository.rootURL,
            standardInput: patch,
            environment: [:]
        )
        guard result.succeeded else { throw commandError(from: result) }
        let verb = selection.direction == .stage ? "Staged" : "Unstaged"
        let selectedID: RevisionID = selection.direction == .stage ? .workingDirectory : .index
        return try await refreshedMutationResult(
            message: "\(verb) \(selection.lineIDs.count) selected line(s) in \(selection.file.path).",
            selectedCommitID: selectedID
        )
    }

    package func loadCommitState(
        historyLimit: Int,
        showOnlyMyMessages: Bool,
        rememberAmend: Bool
    ) async throws -> RepositoryCommitState {
        let repository = try mutationRepository()
        let mutationState = try await mutationState(in: repository)
        let encodingName = await commitEncodingName(in: repository)
        var messageLoadError: String?
        let encoding: String.Encoding
        do {
            encoding = try GitCommitMessageFormatter.encoding(named: encodingName)
        } catch {
            encoding = .utf8
            messageLoadError = error.localizedDescription
        }
        let mergeURL = repository.gitDirectoryURL.appendingPathComponent("MERGE_MSG")
        let draftURL = repository.gitDirectoryURL.appendingPathComponent("COMMITMESSAGE")
        let amendURL = repository.gitDirectoryURL.appendingPathComponent("GitExtensions.amend")
        let isMerge = FileManager.default.fileExists(atPath: mergeURL.path)

        var loadedTemplate: String?
        var message = ""
        let messageURL = isMerge ? mergeURL : draftURL
        if FileManager.default.fileExists(atPath: messageURL.path) {
            do {
                message = try readCommitText(at: messageURL, encoding: encoding, encodingName: encodingName)
            } catch {
                messageLoadError = error.localizedDescription
            }
        } else if !isMerge {
            let configured = try await rawMutation(["config", "--get", "commit.template"], in: repository)
            if configured.succeeded {
                let configuredPath = configured.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !configuredPath.isEmpty {
                    let expanded = NSString(string: configuredPath).expandingTildeInPath
                    let templateURL = URL(fileURLWithPath: expanded, relativeTo: configuredPath.hasPrefix("/") ? nil : repository.rootURL).standardizedFileURL
                    if !FileManager.default.fileExists(atPath: templateURL.path) {
                        messageLoadError = RepositoryMutationError.configuredTemplateMissing(templateURL.path).localizedDescription
                    } else {
                        do {
                            let template = try readCommitText(at: templateURL, encoding: encoding, encodingName: encodingName)
                            loadedTemplate = template
                            message = template
                        } catch {
                            messageLoadError = error.localizedDescription
                        }
                    }
                }
            }
        }

        async let nameResult = rawMutation(["config", "--get", "user.name"], in: repository)
        async let emailResult = rawMutation(["config", "--get", "user.email"], in: repository)
        let name = try await nameResult.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = try await emailResult.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        let committer = name.isEmpty && email.isEmpty ? "Not configured" : "\(name) <\(email)>"

        var logArguments = ["log", "-\(max(1, historyLimit))", "--format=%B%x00"]
        if showOnlyMyMessages, !name.isEmpty, !email.isEmpty {
            logArguments += ["--author=^\(NSRegularExpression.escapedPattern(for: name)) <\(NSRegularExpression.escapedPattern(for: email))>$"]
        }
        let log = try await rawMutation(logArguments, in: repository)
        let messages = log.succeeded
            ? log.standardOutputString.split(separator: "\0", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            : []
        let rememberedAmend = rememberAmend
            && FileManager.default.fileExists(atPath: amendURL.path)
            && ((try? String(contentsOf: amendURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true")

        return RepositoryCommitState(
            mutationState: mutationState,
            message: message,
            loadedTemplate: loadedTemplate,
            commitEncoding: encodingName,
            previousMessages: Array(messages.prefix(max(1, historyLimit))),
            committer: committer,
            isMergeCommit: isMerge,
            rememberedAmend: rememberedAmend,
            messageLoadError: messageLoadError
        )
    }

    package func saveCommitDraft(
        message: String,
        amend: Bool,
        rememberAmend: Bool,
        encoding: String?
    ) async throws {
        let repository = try mutationRepository()
        let configuredEncoding = encoding?.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodingName: String
        if let configuredEncoding, !configuredEncoding.isEmpty {
            encodingName = configuredEncoding
        } else {
            encodingName = await commitEncodingName(in: repository)
        }
        let stringEncoding = try GitCommitMessageFormatter.encoding(named: encodingName)
        guard let data = message.data(using: stringEncoding, allowLossyConversion: false) else {
            throw RepositoryMutationError.commitMessageNotRepresentable(encodingName)
        }
        let mergeURL = repository.gitDirectoryURL.appendingPathComponent("MERGE_MSG")
        let destination = FileManager.default.fileExists(atPath: mergeURL.path)
            ? mergeURL
            : repository.gitDirectoryURL.appendingPathComponent("COMMITMESSAGE")
        try data.write(to: destination, options: .atomic)
        let amendURL = repository.gitDirectoryURL.appendingPathComponent("GitExtensions.amend")
        if rememberAmend, amend {
            try Data("True".utf8).write(to: amendURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: amendURL.path) {
            try FileManager.default.removeItem(at: amendURL)
        }
    }

    package func commit(_ request: RepositoryCommitRequest) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        guard !request.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryMutationError.emptyCommitMessage
        }

        var state = try await mutationState(in: repository)
        guard state.conflictedPaths.isEmpty else {
            throw RepositoryMutationError.unresolvedConflicts(state.conflictedPaths)
        }
        if request.stageAllBeforeCommit {
            _ = try await checkedMutation(["add", "--all", "--"], in: repository)
            state = try await mutationState(in: repository)
        }

        let isAmend = request.mode != .normal
        let allowsEmptyTree = request.allowEmpty || isAmend
        guard state.hasStagedChanges || allowsEmptyTree else {
            throw RepositoryMutationError.nothingStaged
        }

        let author = request.author?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
        if let author, !author.isEmpty,
           author.range(of: #"^.+\s<[^<>]+>$"#, options: .regularExpression) == nil {
            throw RepositoryMutationError.invalidAuthor(author)
        }
        let configuredEncoding = request.messageEncoding?.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodingName: String
        if let configuredEncoding, !configuredEncoding.isEmpty {
            encodingName = configuredEncoding
        } else {
            encodingName = await commitEncodingName(in: repository)
        }
        let messageEncoding = try GitCommitMessageFormatter.encoding(named: encodingName)
        let formattedMessage = GitCommitMessageFormatter.format(
            request.message,
            usingTemplate: request.usingTemplate,
            ensureSecondLineEmpty: request.ensureSecondLineEmpty
        )
        guard !formattedMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryMutationError.emptyCommitMessage
        }
        guard let messageData = formattedMessage.data(using: messageEncoding, allowLossyConversion: false) else {
            throw RepositoryMutationError.commitMessageNotRepresentable(encodingName)
        }
        let isMerge = FileManager.default.fileExists(atPath: repository.gitDirectoryURL.appendingPathComponent("MERGE_MSG").path)
        let messageURL = repository.gitDirectoryURL.appendingPathComponent(isMerge ? "MERGE_MSG" : "COMMITMESSAGE")
        try messageData.write(to: messageURL, options: .atomic)

        let arguments = GitCommitCommandBuilder.arguments(
            request: request,
            messageFile: messageURL.path,
            hasStagedChanges: state.hasStagedChanges,
            normalizedAuthor: author
        )
        let result = try await git.run(
            GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: true),
            in: repository.rootURL,
            standardInput: nil,
            environment: [:]
        )
        guard result.succeeded else { throw commandError(from: result) }

        for name in ["COMMITMESSAGE", "GitExtensions.amend"] {
            let url = repository.gitDirectoryURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let headID = try await mutationState(in: repository).headID
        let verb = isAmend ? "Amended" : "Created"
        return RepositoryMutationResult(
            selectedCommitID: headID.map(RevisionID.object),
            outcome: .completed,
            message: "\(verb) commit \(headID?.shortString ?? "")."
        )
    }

    package func resetChanges(_ request: RepositoryResetChangesRequest) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        switch request.scope {
        case .worktree:
            _ = try await checkedMutation(["checkout", "--", "."], in: repository)
        case .all:
            _ = try await checkedMutation(["reset", "--hard"], in: repository)
        }
        if request.deleteUntracked {
            _ = try await checkedMutation(["clean", "-d", "-f"], in: repository)
        }
        return try await refreshedMutationResult(message: "Reset repository changes.", selectedCommitID: .workingDirectory)
    }

    package func resetSoftToParent() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        _ = try await checkedMutation(["reset", "--soft", "HEAD~1"], in: repository)
        return try await refreshedMutationResult(message: "Soft-reset HEAD to its parent.", selectedCommitID: .index)
    }

    package func createBranch(named name: String) async throws -> RepositoryMutationResult {
        try await createBranch(RepositoryCreateBranchRequest(
            name: name,
            sourceRevision: nil,
            checkoutAfterCreation: true,
            mode: .normal
        ))
    }

    package func createStash(_ request: RepositoryStashCreateRequest) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let beforeRef = try await rawMutation(["rev-parse", "--verify", "--quiet", "refs/stash"], in: repository)
            .standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)

        var seenPaths = Set<String>()
        let selectedPaths = request.selectedPaths.compactMap { path -> String? in
            guard !path.isEmpty, seenPaths.insert(path).inserted else { return nil }
            return path
        }
        let message = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = ["stash"]
        if request.stagedOnly {
            arguments.append("--staged")
        } else if selectedPaths.isEmpty {
            arguments.append("save")
            if request.includeUntracked { arguments.append("-u") }
            if request.keepIndex { arguments.append("--keep-index") }
            if !message.isEmpty { arguments.append(message) }
        } else {
            arguments.append("push")
            if request.includeUntracked { arguments.append("-u") }
            if request.keepIndex { arguments.append("--keep-index") }
            if !message.isEmpty { arguments += ["-m", message] }
            arguments.append("--")
            arguments.append(contentsOf: selectedPaths)
        }

        let command = try await rawMutation(arguments, in: repository)
        if !command.succeeded {
            let state = try await mutationState(in: repository)
            if !state.conflictedPaths.isEmpty {
                return try await stashConflictResult(
                    command: command,
                    message: "Creating the stash left conflicts.",
                    repository: repository
                )
            }
            throw commandError(from: command)
        }

        let afterRef = try await rawMutation(["rev-parse", "--verify", "--quiet", "refs/stash"], in: repository)
            .standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        let created = !afterRef.isEmpty && afterRef != beforeRef
        return RepositoryMutationResult(
            selectedCommitID: nil,
            outcome: .completed,
            message: created ? "Created stash." : "No local changes to save."
        )
    }

    package func applyStash(_ stash: Stash) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        try await validate(stash: stash, repository: repository)
        let command = try await rawMutation(["stash", "apply", stash.selector], in: repository)
        if !command.succeeded {
            let state = try await mutationState(in: repository)
            if !state.conflictedPaths.isEmpty {
                return try await stashConflictResult(
                    command: command,
                    message: "Applied \(stash.selector) with conflicts.",
                    repository: repository,
                    selectedCommitID: .object(stash.commitID)
                )
            }
            throw commandError(from: command)
        }
        return try await refreshedMutationResult(message: "Applied \(stash.selector).", selectedCommitID: .object(stash.commitID))
    }

    package func popStash(_ stash: Stash?) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        if let stash { try await validate(stash: stash, repository: repository) }
        if stash == nil {
            let exists = try await rawMutation(["rev-parse", "--verify", "--quiet", "refs/stash"], in: repository)
            guard exists.succeeded else { throw RepositoryMutationError.noStashes }
        }
        var arguments = ["stash", "pop"]
        if let stash { arguments.append(stash.selector) }
        let command = try await rawMutation(arguments, in: repository)
        if !command.succeeded {
            let state = try await mutationState(in: repository)
            if !state.conflictedPaths.isEmpty {
                return try await stashConflictResult(
                    command: command,
                    message: "Popped \(stash?.selector ?? "latest stash") with conflicts; the stash was kept.",
                    repository: repository,
                    selectedCommitID: stash.map { .object($0.commitID) }
                )
            }
            throw commandError(from: command)
        }
        let selectedID = try await mutationState(in: repository).headID
        return RepositoryMutationResult(
            selectedCommitID: selectedID.map(RevisionID.object),
            outcome: .completed,
            message: "Popped \(stash?.selector ?? "latest stash")."
        )
    }

    package func dropStash(_ stash: Stash) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        try await validate(stash: stash, repository: repository)
        _ = try await checkedMutation(["stash", "drop", stash.selector], in: repository)
        let refreshedStashes = try await loadRepositoryState().navigation.stashes
        let headID = try await mutationState(in: repository).headID
        let droppedIndex = stashIndex(stash.selector)
        let adjacentStash = droppedIndex.flatMap { index -> Stash? in
            guard !refreshedStashes.isEmpty else { return nil }
            return refreshedStashes[min(index, refreshedStashes.count - 1)]
        }
        return RepositoryMutationResult(
            selectedCommitID: (adjacentStash?.commitID ?? headID).map(RevisionID.object),
            outcome: .completed,
            message: "Dropped \(stash.selector)."
        )
    }

    package func cherryPick(_ request: RepositoryCherryPickRequest) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        guard !request.items.isEmpty else { throw RepositoryMutationError.noRevisions }
        let state = try await mutationState(in: repository)
        if state.cherryPickInProgress { throw RepositoryMutationError.operationInProgress("a cherry-pick") }
        if state.rebaseInProgress { throw RepositoryMutationError.operationInProgress("a rebase") }
        guard state.conflictedPaths.isEmpty else {
            throw RepositoryMutationError.unresolvedConflicts(state.conflictedPaths)
        }
        try await validateCherryPickItems(request.items, repository: repository)
        pendingCherryPickItems = []
        pendingCherryPickOptions = request.options
        return try await runCherryPickItems(request.items, options: request.options, repository: repository)
    }

    package func continueCherryPick() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        guard state.cherryPickInProgress else { throw RepositoryMutationError.cherryPickNotInProgress }
        guard state.conflictedPaths.isEmpty else {
            throw RepositoryMutationError.unresolvedConflicts(state.conflictedPaths)
        }
        let continued = try await git.run(
            GitCommand(arguments: ["cherry-pick", "--continue"], accessesRemote: false, changesRepositoryState: true),
            in: repository.rootURL,
            standardInput: nil,
            environment: ["GIT_EDITOR": "true"]
        )
        guard continued.succeeded else { throw commandError(from: continued) }

        let remaining = pendingCherryPickItems
        let options = pendingCherryPickOptions ?? RepositoryCherryPickOptions(automaticallyCommit: true, addReference: false)
        pendingCherryPickItems = []
        if !remaining.isEmpty {
            return try await runCherryPickItems(remaining, options: options, repository: repository)
        }
        pendingCherryPickOptions = nil
        let headID = try await mutationState(in: repository).headID
        return RepositoryMutationResult(
            selectedCommitID: headID.map(RevisionID.object),
            outcome: .completed,
            message: "Cherry-pick continued."
        )
    }

    package func abortCherryPick() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        guard state.cherryPickInProgress else { throw RepositoryMutationError.cherryPickNotInProgress }
        _ = try await checkedMutation(["cherry-pick", "--abort"], in: repository)
        pendingCherryPickItems = []
        pendingCherryPickOptions = nil
        let headID = try await mutationState(in: repository).headID
        return RepositoryMutationResult(
            selectedCommitID: headID.map(RevisionID.object),
            outcome: .completed,
            message: "Cherry-pick aborted."
        )
    }

    package func abortMerge() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        guard FileManager.default.fileExists(atPath: repository.gitDirectoryURL.appendingPathComponent("MERGE_HEAD").path) else {
            throw RepositoryMutationError.mergeNotInProgress
        }
        _ = try await checkedMutation(["merge", "--abort"], in: repository)
        let headID = try await mutationState(in: repository).headID
        return RepositoryMutationResult(
            selectedCommitID: headID.map(RevisionID.object),
            outcome: .completed,
            message: "Merge aborted."
        )
    }

    package func loadConflicts() async throws -> [RepositoryConflict] {
        let repository = try mutationRepository()
        let result = try await git.run(
            GitCommand(
                arguments: ["ls-files", "-z", "--unmerged"],
                accessesRemote: false,
                changesRepositoryState: false
            ),
            in: repository.rootURL
        )
        guard result.succeeded else { throw commandError(from: result) }

        struct Stages {
            var base: RepositoryConflictVersion?
            var local: RepositoryConflictVersion?
            var remote: RepositoryConflictVersion?
        }
        var values: [String: Stages] = [:]
        for rawRecord in result.standardOutput.split(separator: 0, omittingEmptySubsequences: true) {
            guard let tab = rawRecord.firstIndex(of: 0x09) else { continue }
            let header = String(decoding: rawRecord[..<tab], as: UTF8.self)
                .split(separator: " ", omittingEmptySubsequences: true)
            let path = String(decoding: rawRecord[rawRecord.index(after: tab)...], as: UTF8.self)
            guard header.count == 3,
                  let objectID = try? ObjectID.parse(String(header[1])),
                  let stageValue = Int(header[2]),
                  let side = RepositoryConflictSide(rawValue: stageValue)
            else { continue }
            let version = RepositoryConflictVersion(
                objectID: objectID,
                mode: String(header[0]),
                path: path
            )
            var stages = values[path] ?? Stages()
            switch side {
            case .base: stages.base = version
            case .local: stages.local = version
            case .remote: stages.remote = version
            }
            values[path] = stages
        }

        return values.keys.sorted().map { path in
            let stages = values[path] ?? Stages()
            let kind: RepositoryConflictKind = switch (stages.base != nil, stages.local != nil, stages.remote != nil) {
            case (true, true, true): .bothModified
            case (false, true, true): .bothAdded
            case (true, false, true): .deletedLocally
            case (true, true, false): .deletedRemotely
            default: .unmerged
            }
            return RepositoryConflict(
                path: path,
                base: stages.base,
                local: stages.local,
                remote: stages.remote,
                kind: kind
            )
        }
    }

    package func loadConflictContent(
        path: String,
        side: RepositoryConflictSide,
        encoding: RepositoryTextEncoding
    ) async throws -> RepositoryFileContent? {
        let repository = try mutationRepository()
        guard let conflict = try await loadConflicts().first(where: { $0.path == path }),
              let version = conflict.version(for: side) else { return nil }
        if version.mode == "160000" {
            let text = "Submodule commit \(version.objectID.string)\n"
            return RepositoryFileContent(
                path: path,
                kind: .text,
                text: text,
                data: Data(text.utf8),
                encoding: .utf8
            )
        }
        let result = try await git.run(
            GitCommand(
                arguments: ["show", ":\(side.rawValue):\(path)"],
                accessesRemote: false,
                changesRepositoryState: false
            ),
            in: repository.rootURL
        )
        guard result.succeeded else { throw commandError(from: result) }
        return FileContentDecoder.decode(result.standardOutput, path: path, requestedEncoding: encoding)
    }

    package func conflictWorkingTreeURL(path: String) async throws -> URL {
        let repository = try mutationRepository()
        return repository.rootURL.appendingPathComponent(path)
    }

    package func chooseConflictSide(
        paths: [String],
        side: RepositoryConflictSide
    ) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let selectedPaths = normalizedPaths(paths)
        guard !selectedPaths.isEmpty else { throw RepositoryMutationError.noPaths }
        let conflicts = Dictionary(uniqueKeysWithValues: try await loadConflicts().map { ($0.path, $0) })
        guard selectedPaths.allSatisfy({ conflicts[$0] != nil }) else {
            throw RepositoryMutationError.unresolvedConflicts(conflicts.keys.sorted())
        }

        for path in selectedPaths {
            guard let conflict = conflicts[path] else { continue }
            if conflict.version(for: side) == nil {
                _ = try await checkedMutation(["rm", "--", path], in: repository)
            } else {
                _ = try await checkedMutation(
                    ["checkout-index", "-f", "--stage=\(side.rawValue)", "--", path],
                    in: repository
                )
                _ = try await checkedMutation(["add", "--", path], in: repository)
            }
        }
        return try await refreshedMutationResult(
            message: "Resolved \(selectedPaths.count) conflict(s).",
            selectedCommitID: .workingDirectory
        )
    }

    package func loadMergeToolConfiguration() async throws -> RepositoryMergeToolConfiguration? {
        let repository = try mutationRepository()
        let gui = try await conflictRead(["config", "--get", "merge.guitool"], in: repository)
        let guiName = gui.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        let standard = try await conflictRead(["config", "--get", "merge.tool"], in: repository)
        let standardName = standard.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesGUISetting = gui.succeeded && !guiName.isEmpty
        let selectedName = usesGUISetting ? guiName : standardName
        guard !selectedName.isEmpty else { return nil }

        let configured = try await conflictRead(
            ["config", "--name-only", "--get-regexp", #"^mergetool\..*\.(cmd|path)$"#],
            in: repository
        )
        var names = Set(configured.standardOutputString.split(whereSeparator: \Character.isNewline).compactMap { line -> String? in
            let components = line.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count >= 3, components[0] == "mergetool" else { return nil }
            return String(components[1])
        })
        names.insert(selectedName)
        let trust = try await conflictRead(
            ["config", "--bool", "--get", "mergetool.\(selectedName).trustExitCode"],
            in: repository
        )
        return RepositoryMergeToolConfiguration(
            name: selectedName,
            usesGUISetting: usesGUISetting,
            availableTools: names.sorted(),
            trustExitCode: trust.succeeded && trust.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        )
    }

    package func runMergeTool(paths: [String], tool: String? = nil) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let paths = normalizedPaths(paths)
        let state = try await mutationState(in: repository)
        let conflicts = Set(state.conflictedPaths)
        guard paths.allSatisfy(conflicts.contains) else {
            throw RepositoryMutationError.unresolvedConflicts(state.conflictedPaths)
        }
        guard let configuration = try await loadMergeToolConfiguration() else {
            throw RepositoryMutationError.mergeToolNotConfigured
        }
        var arguments = ["mergetool"]
        if configuration.usesGUISetting { arguments.append("--gui") }
        if let tool, !tool.isEmpty { arguments.append("--tool=\(tool)") }
        arguments.append("--no-prompt")
        if !paths.isEmpty { arguments += ["--"] + paths }
        _ = try await checkedMutation(arguments, in: repository)
        return try await refreshedMutationResult(
            message: paths.isEmpty
                ? "Merge tool completed."
                : "Merge tool completed for \(paths.count) path(s).",
            selectedCommitID: .workingDirectory
        )
    }

    package func loadInteractiveRebasePlan(upstream: String) async throws -> [RepositoryRebaseTodoItem] {
        let repository = try mutationRepository()
        let resolvedUpstream = try await validateRevision(upstream, repository: repository)
        let output = try await checkedMutation([
            "log", "--reverse", "--topo-order", "--no-merges",
            "--format=%H%x00%s", "\(resolvedUpstream.string)..HEAD"
        ], in: repository).standardOutputString
        return output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2,
                  let commitID = try? ObjectID.parse(String(fields[0]))
            else { return nil }
            return RepositoryRebaseTodoItem(
                commitID: commitID,
                subject: String(fields[1]),
                action: .pick
            )
        }
    }

    package func loadNativeInteractiveRebaseTodo(_ request: RepositoryInteractiveRebaseTodoRequest) async throws -> String {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        try validateCanStartRebase(state)
        let upstream = try await validateRevision(request.upstream, repository: repository)
        let arguments = try await rebaseArguments(
            upstream: upstream,
            interactive: true,
            autoSquash: request.autoSquash,
            autoStash: request.autoStash,
            rebaseMerges: request.rebaseMerges,
            updateRefs: request.updateRefs,
            ignoreDate: false,
            committerDateIsAuthorDate: false,
            onto: request.onto,
            from: request.from,
            branch: request.branch,
            repository: repository
        )
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitExtensionsMac-RebaseTodo-\(UUID().uuidString)", isDirectory: true)
        let editor = temporaryDirectory.appendingPathComponent("capture-todo.sh")
        let capture = temporaryDirectory.appendingPathComponent("git-rebase-todo")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let script = "#!/bin/sh\n/bin/cp \"$1\" \"$GIT_EXTENSIONS_MAC_TODO_CAPTURE\"\nexit 197\n"
        try Data(script.utf8).write(to: editor, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: editor.path)
        let result = try await git.run(
            GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: true),
            in: repository.rootURL,
            standardInput: nil,
            environment: [
                "GIT_SEQUENCE_EDITOR": editor.path,
                "GIT_EDITOR": "true",
                "GIT_EXTENSIONS_MAC_TODO_CAPTURE": capture.path
            ]
        )
        let after = try await mutationState(in: repository)
        if after.rebaseInProgress {
            _ = try await rawMutation(["rebase", "--abort"], in: repository)
        }
        guard let data = FileManager.default.contents(atPath: capture.path),
              let todo = String(data: data, encoding: .utf8),
              !todo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw commandError(from: result)
        }
        return todo
    }

    package func loadRebaseConfiguration() async throws -> RepositoryRebaseConfiguration {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        async let autoSquashResult = rawMutation(["config", "--bool", "--get", "rebase.autosquash"], in: repository)
        async let updateRefsResult = rawMutation(["config", "--bool", "--get", "rebase.updateRefs"], in: repository)
        async let versionResult = rawMutation(["version"], in: repository)
        let (autoSquash, updateRefs, version) = try await (autoSquashResult, updateRefsResult, versionResult)
        return RepositoryRebaseConfiguration(
            autoSquash: configuredBoolean(autoSquash),
            updateRefs: configuredBoolean(updateRefs),
            supportsUpdateRefs: gitVersionSupportsUpdateRefs(version.standardOutputString),
            isDirty: state.isDirty
        )
    }

    package func loadRebaseState() async throws -> RepositoryRebaseState {
        let repository = try mutationRepository()
        let mutation = try await mutationState(in: repository)
        let rebaseDirectory = rebaseDirectoryURL(repository)
        guard mutation.rebaseInProgress, let rebaseDirectory else {
            return RepositoryRebaseState(
                inProgress: false,
                hasConflicts: false,
                currentBranch: mutation.currentBranch,
                currentCommitID: nil,
                patches: [],
                canEditTodo: false,
                hasAutoStash: false
            )
        }

        let stopped = readRebaseFile("stopped-sha", directory: rebaseDirectory)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stoppedObjectID = stopped.flatMap { try? ObjectID.parse($0) }
        let done = parseRebaseTodo(readRebaseFile("done", directory: rebaseDirectory) ?? "")
        let todo = parseRebaseTodo(readRebaseFile("git-rebase-todo", directory: rebaseDirectory) ?? "")
        var patches = done.map { item in
            let isCurrent = stopped.map { item.revisionToken.hasPrefix($0) || $0.hasPrefix(item.revisionToken) } ?? false
            return RepositoryRebasePatch(
                action: item.action,
                revisionToken: item.revisionToken,
                subject: item.subject,
                author: "",
                date: "",
                status: isCurrent ? .applying : .applied
            )
        }
        patches.append(contentsOf: todo.map { item in
            let isCurrent = stopped.map { item.revisionToken.hasPrefix($0) || $0.hasPrefix(item.revisionToken) } ?? false
            return RepositoryRebasePatch(
                action: item.action,
                revisionToken: item.revisionToken,
                subject: item.subject,
                author: "",
                date: "",
                status: isCurrent ? .applying : .pending
            )
        })
        if patches.isEmpty {
            patches = parseApplyRebasePatches(directory: rebaseDirectory)
        }
        if let stopped, !patches.contains(where: { $0.status == .applying }) {
            patches.append(RepositoryRebasePatch(action: "pick", revisionToken: stopped, subject: "", author: "", date: "", status: .applying))
        }
        for index in patches.indices {
            let metadata = try await rawMutation(
                ["show", "-s", "--format=%an%x00%aI%x00%B", patches[index].revisionToken],
                in: repository
            )
            guard metadata.succeeded else { continue }
            let fields = metadata.standardOutputString.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let subject = patches[index].subject.isEmpty
                ? String(fields[2]).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                : patches[index].subject
            patches[index] = RepositoryRebasePatch(
                action: patches[index].action,
                revisionToken: patches[index].revisionToken,
                subject: subject,
                author: String(fields[0]),
                date: String(fields[1]),
                status: patches[index].status
            )
        }
        let recordedBranch = readRebaseFile("head-name", directory: rebaseDirectory)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "refs/heads/", with: "")
        return RepositoryRebaseState(
            inProgress: true,
            hasConflicts: !mutation.conflictedPaths.isEmpty,
            currentBranch: mutation.currentBranch ?? (recordedBranch?.isEmpty == false ? recordedBranch : nil),
            currentCommitID: stoppedObjectID,
            patches: patches,
            canEditTodo: FileManager.default.fileExists(atPath: rebaseDirectory.appendingPathComponent("git-rebase-todo").path),
            hasAutoStash: FileManager.default.fileExists(atPath: rebaseDirectory.appendingPathComponent("autostash").path)
        )
    }

    package func rebase(_ request: RepositoryRebaseRequest) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        try validateCanStartRebase(state)
        let upstream = try await validateRevision(request.upstream, repository: repository)
        pendingRebaseActions = [:]
        let arguments = try await rebaseArguments(
            upstream: upstream,
            interactive: false,
            autoSquash: false,
            autoStash: request.autoStash,
            rebaseMerges: request.rebaseMerges,
            updateRefs: request.updateRefs,
            ignoreDate: request.ignoreDate,
            committerDateIsAuthorDate: request.committerDateIsAuthorDate,
            onto: request.onto,
            from: request.from,
            branch: request.branch,
            repository: repository
        )
        let command = try await rawMutation(arguments, in: repository)
        return try await resolveRebaseExecution(
            command,
            repository: repository,
            completionMessage: "Rebase completed."
        )
    }

    package func interactiveRebase(_ request: RepositoryInteractiveRebaseRequest) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        try validateCanStartRebase(state)
        let upstream = try await validateRevision(request.upstream, repository: repository)
        let todo: String
        if let nativeTodo = request.nativeTodo {
            let prepared = prepareNativeRebaseTodo(nativeTodo)
            guard !prepared.todo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RepositoryMutationError.emptyRebasePlan
            }
            pendingRebaseActions = prepared.actions
            todo = prepared.todo
        } else {
            let expected = try await loadInteractiveRebasePlan(upstream: upstream.string)
            let effectiveItems = request.autoSquash ? autosquashed(request.items) : request.items
            try validateInteractivePlan(effectiveItems, expected: expected)
            pendingRebaseActions = Dictionary(uniqueKeysWithValues: effectiveItems.map { ($0.commitID.string, $0.action) })
            todo = effectiveItems.map { item in
                "\(rebaseTodoCommand(item.action)) \(item.commitID.string) \(sanitizeTodoSubject(item.subject))"
            }.joined(separator: "\n") + "\n"
        }
        let arguments = try await rebaseArguments(
            upstream: upstream,
            interactive: true,
            autoSquash: request.autoSquash,
            autoStash: request.autoStash,
            rebaseMerges: request.rebaseMerges,
            updateRefs: request.updateRefs,
            ignoreDate: false,
            committerDateIsAuthorDate: false,
            onto: request.onto,
            from: request.from,
            branch: request.branch,
            repository: repository
        )
        let command = try await git.run(
            GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: true),
            in: repository.rootURL,
            standardInput: Data(todo.utf8),
            environment: [
                "GIT_SEQUENCE_EDITOR": "/usr/bin/tee",
                "GIT_EDITOR": "true"
            ]
        )
        return try await resolveRebaseExecution(
            command,
            repository: repository,
            completionMessage: "Interactive rebase completed."
        )
    }

    package func editRebaseTodo(_ items: [RepositoryRebaseTodoItem]) async throws -> RepositoryRebaseState {
        let repository = try mutationRepository()
        let state = try await loadRebaseState()
        guard state.inProgress, state.canEditTodo else { throw RepositoryMutationError.rebaseNotInProgress }
        let pendingIDs = Set(state.patches.filter { $0.status == .pending }.map(\.revisionToken))
        guard Set(items.map { $0.commitID.string }) == pendingIDs, items.count == pendingIDs.count else {
            throw RepositoryMutationError.invalidRebasePlan("the edited todo must contain every pending commit exactly once")
        }
        try validateInteractivePlan(items, expected: items.map {
            RepositoryRebaseTodoItem(commitID: $0.commitID, subject: $0.subject, action: .pick)
        })
        pendingRebaseActions.merge(Dictionary(uniqueKeysWithValues: items.map { ($0.commitID.string, $0.action) })) { _, new in new }
        let todo = items.map { "\(rebaseTodoCommand($0.action)) \($0.commitID.string) \(sanitizeTodoSubject($0.subject))" }.joined(separator: "\n") + "\n"
        let result = try await git.run(
            GitCommand(arguments: ["rebase", "--edit-todo"], accessesRemote: false, changesRepositoryState: true),
            in: repository.rootURL,
            standardInput: Data(todo.utf8),
            environment: ["GIT_SEQUENCE_EDITOR": "/usr/bin/tee"]
        )
        guard result.succeeded else { throw commandError(from: result) }
        return try await loadRebaseState()
    }

    package func loadRebaseTodoText() async throws -> String {
        let repository = try mutationRepository()
        let state = try await loadRebaseState()
        guard state.inProgress, state.canEditTodo,
              let directory = rebaseDirectoryURL(repository),
              let todo = readRebaseFile("git-rebase-todo", directory: directory)
        else { throw RepositoryMutationError.rebaseNotInProgress }
        return todo
    }

    package func editRebaseTodoText(_ todo: String) async throws -> RepositoryRebaseState {
        let repository = try mutationRepository()
        _ = try await loadRebaseTodoText()
        let prepared = prepareNativeRebaseTodo(todo)
        guard !prepared.todo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryMutationError.emptyRebasePlan
        }
        pendingRebaseActions.merge(prepared.actions) { _, new in new }
        let result = try await git.run(
            GitCommand(arguments: ["rebase", "--edit-todo"], accessesRemote: false, changesRepositoryState: true),
            in: repository.rootURL,
            standardInput: Data(prepared.todo.utf8),
            environment: ["GIT_SEQUENCE_EDITOR": "/usr/bin/tee"]
        )
        guard result.succeeded else { throw commandError(from: result) }
        return try await loadRebaseState()
    }

    package func continueRebase() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        guard state.rebaseInProgress else { throw RepositoryMutationError.rebaseNotInProgress }
        guard state.conflictedPaths.isEmpty else {
            throw RepositoryMutationError.unresolvedConflicts(state.conflictedPaths)
        }
        let command = try await git.run(
            GitCommand(arguments: ["rebase", "--continue"], accessesRemote: false, changesRepositoryState: true),
            in: repository.rootURL,
            standardInput: nil,
            environment: ["GIT_EDITOR": "true"]
        )
        return try await resolveRebaseExecution(
            command,
            repository: repository,
            completionMessage: "Rebase continued."
        )
    }

    package func skipRebase() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        guard state.rebaseInProgress else { throw RepositoryMutationError.rebaseNotInProgress }
        let command = try await git.run(
            GitCommand(arguments: ["rebase", "--skip"], accessesRemote: false, changesRepositoryState: true),
            in: repository.rootURL,
            standardInput: nil,
            environment: ["GIT_EDITOR": "true"]
        )
        return try await resolveRebaseExecution(
            command,
            repository: repository,
            completionMessage: "Skipped the current patch."
        )
    }

    package func abortRebase() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        guard state.rebaseInProgress else { throw RepositoryMutationError.rebaseNotInProgress }
        _ = try await checkedMutation(["rebase", "--abort"], in: repository)
        pendingRebaseActions = [:]
        let headID = try await mutationState(in: repository).headID
        return RepositoryMutationResult(
            selectedCommitID: headID.map(RevisionID.object),
            outcome: .completed,
            message: "Rebase aborted."
        )
    }

    private func checkoutArguments(
        for request: RepositoryCheckoutRequest,
        state: RepositoryMutationState,
        repository: ResolvedGitRepository
    ) async throws -> [String] {
        var arguments = ["checkout"]
        switch request.localChanges {
        case .merge:
            arguments.append("--merge")
        case .force:
            arguments.append("--force")
        case .keep, .stash:
            break
        }

        switch request.target {
        case .localBranch(let name):
            arguments.append(name)

        case .revision(let objectID):
            guard !objectID.isEmpty, !objectID.hasPrefix("$") else {
                throw RepositoryMutationError.invalidRevision(objectID)
            }
            arguments.append(objectID)

        case .remoteBranch(let remote, let branch, let mode):
            let remoteRef = "\(remote)/\(branch)"
            switch mode {
            case .detached:
                arguments.append(remoteRef)
            case .createTracking(let localBranch):
                try await validateBranchName(localBranch, repository: repository)
                arguments += ["-b", localBranch, "--track", remoteRef]
            case .resetTracking(let localBranch):
                try await validateBranchName(localBranch, repository: repository)
                arguments += ["-B", localBranch, remoteRef]
            }
        }
        return arguments
    }

    private func validateBranchName(_ name: String, repository: ResolvedGitRepository) async throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryMutationError.invalidBranchName(name)
        }
        let result = try await rawMutation(["check-ref-format", "--branch", name], in: repository)
        guard result.succeeded else { throw RepositoryMutationError.invalidBranchName(name) }
    }

    private func validate(stash: Stash, repository: ResolvedGitRepository) async throws {
        let result = try await rawMutation(
            ["rev-parse", "--verify", "--quiet", "\(stash.selector)^{commit}"],
            in: repository
        )
        let resolved = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, (try? ObjectID.parse(resolved)) == stash.commitID else {
            throw RepositoryMutationError.invalidStash(stash.selector)
        }
    }

    private func validateCherryPickItems(
        _ items: [RepositoryCherryPickItem],
        repository: ResolvedGitRepository
    ) async throws {
        for item in items {
            let resolved = try await rawMutation(
                ["rev-parse", "--verify", "--quiet", "\(item.commitID.string)^{commit}"],
                in: repository
            )
            guard resolved.succeeded,
                  (try? ObjectID.parse(resolved.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines))) == item.commitID
            else { throw RepositoryMutationError.invalidRevision(item.commitID.string) }

            let parents = try await checkedMutation(["rev-list", "--parents", "-n", "1", item.commitID.string], in: repository)
                .standardOutputString.split(whereSeparator: \.isWhitespace)
            let parentCount = max(0, parents.count - 1)
            if parentCount > 1 {
                guard let mainline = item.mainlineParent, (1...parentCount).contains(mainline) else {
                    throw RepositoryMutationError.invalidMainline(
                        commitID: item.commitID,
                        parent: item.mainlineParent,
                        parentCount: parentCount
                    )
                }
            } else if item.mainlineParent != nil {
                throw RepositoryMutationError.invalidMainline(
                    commitID: item.commitID,
                    parent: item.mainlineParent,
                    parentCount: parentCount
                )
            }
        }
    }

    private func validateCanStartRebase(_ state: RepositoryMutationState) throws {
        if state.rebaseInProgress { throw RepositoryMutationError.operationInProgress("a rebase") }
        if state.cherryPickInProgress { throw RepositoryMutationError.operationInProgress("a cherry-pick") }
        guard state.conflictedPaths.isEmpty else {
            throw RepositoryMutationError.unresolvedConflicts(state.conflictedPaths)
        }
    }

    private struct ParsedRebaseTodo {
        let action: String
        let revisionToken: String
        let subject: String
    }

    private func rebaseDirectoryURL(_ repository: ResolvedGitRepository) -> URL? {
        for name in ["rebase-merge", "rebase-apply", "rebase"] {
            let candidate = repository.gitDirectoryURL.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func readRebaseFile(_ name: String, directory: URL) -> String? {
        try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    private func parseRebaseTodo(_ contents: String) -> [ParsedRebaseTodo] {
        let commentCharacter = "#"
        return contents.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix(commentCharacter) else { return nil }
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { return nil }
            let action = String(fields[0])
            guard ["pick", "p", "reword", "r", "edit", "e", "squash", "s", "fixup", "f", "drop", "d"].contains(action) else {
                return nil
            }
            return ParsedRebaseTodo(
                action: action,
                revisionToken: String(fields[1]),
                subject: fields.count > 2 ? String(fields[2]) : ""
            )
        }
    }

    private func parseApplyRebasePatches(directory: URL) -> [RepositoryRebasePatch] {
        let next = Int(readRebaseFile("next", directory: directory)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> (Int, RepositoryRebasePatch)? in
            guard let number = Int(name) else { return nil }
            let contents = readRebaseFile(name, directory: directory) ?? ""
            var headers: [String: String] = [:]
            var currentKey: String?
            for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
                let value = String(rawLine).trimmingCharacters(in: .newlines)
                if value.isEmpty { break }
                if value.first?.isWhitespace == true, let currentKey {
                    headers[currentKey, default: ""] += value.trimmingCharacters(in: .whitespacesAndNewlines)
                    continue
                }
                guard let colon = value.firstIndex(of: ":") else { continue }
                let key = String(value[..<colon]).lowercased()
                guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { continue }
                currentKey = key
                headers[key] = String(value[value.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let decodedAuthor = decodeMIMEHeader(headers["from"] ?? "")
            let author = decodedAuthor.split(separator: "<", maxSplits: 1).first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let date = decodeMIMEHeader(headers["date"] ?? "")
            let subject = decodeMIMEHeader(headers["subject"] ?? "")
            let status: RepositoryRebasePatchStatus = number < next ? .applied : (number == next ? .applying : .pending)
            return (number, RepositoryRebasePatch(action: "pick", revisionToken: "", subject: subject, author: author, date: date, status: status))
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    private func decodeMIMEHeader(_ value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#) else { return value }
        let source = value as NSString
        let matches = expression.matches(in: value, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return value }
        var decoded = value
        for match in matches.reversed() {
            guard match.numberOfRanges == 4,
                  let full = Range(match.range(at: 0), in: value),
                  let charsetRange = Range(match.range(at: 1), in: value),
                  let encodingRange = Range(match.range(at: 2), in: value),
                  let payloadRange = Range(match.range(at: 3), in: value)
            else { continue }
            let charset = String(value[charsetRange])
            let encoding = value[encodingRange].lowercased()
            let payload = String(value[payloadRange])
            let data = encoding == "b" ? Data(base64Encoded: payload) : decodeQuotedPrintableWord(payload)
            guard let data, let replacement = decode(data: data, charset: charset) else { continue }
            decoded.replaceSubrange(full, with: replacement)
        }
        return decoded
    }

    private func decodeQuotedPrintableWord(_ payload: String) -> Data? {
        let bytes = Array(payload.utf8)
        var output: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 95 {
                output.append(32); index += 1
            } else if bytes[index] == 61, index + 2 < bytes.count,
                      let high = hexadecimal(bytes[index + 1]), let low = hexadecimal(bytes[index + 2]) {
                output.append((high << 4) | low); index += 3
            } else {
                output.append(bytes[index]); index += 1
            }
        }
        return Data(output)
    }

    private func hexadecimal(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    private func decode(data: Data, charset: String) -> String? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        if cfEncoding != kCFStringEncodingInvalidId {
            let raw = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            if let decoded = String(data: data, encoding: String.Encoding(rawValue: raw)) { return decoded }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private func configuredBoolean(_ result: GitCommandResult) -> Bool {
        guard result.succeeded else { return false }
        return ["true", "yes", "on", "1"].contains(result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private func gitVersionSupportsUpdateRefs(_ output: String) -> Bool {
        let components = output.split(whereSeparator: { !($0.isNumber || $0 == ".") })
            .first(where: { $0.contains(".") })?
            .split(separator: ".")
            .compactMap { Int($0) } ?? []
        guard components.count >= 2 else { return false }
        return components[0] > 2 || (components[0] == 2 && components[1] >= 38)
    }

    private func rebaseArguments(
        upstream: ObjectID,
        interactive: Bool,
        autoSquash: Bool,
        autoStash: Bool,
        rebaseMerges: Bool,
        updateRefs: Bool?,
        ignoreDate: Bool,
        committerDateIsAuthorDate: Bool,
        onto: String?,
        from: String?,
        branch: String?,
        repository: ResolvedGitRepository
    ) async throws -> [String] {
        guard !(ignoreDate && committerDateIsAuthorDate) else {
            throw RepositoryMutationError.invalidRebasePlan("the date options are mutually exclusive")
        }
        guard (onto == nil) == (from == nil) else {
            throw RepositoryMutationError.invalidRebasePlan("From and Onto must both be supplied for a specific range")
        }
        var arguments = ["rebase"]
        if ignoreDate { arguments.append("--ignore-date") }
        else if committerDateIsAuthorDate { arguments.append("--committer-date-is-author-date") }
        else {
            if interactive {
                arguments.append("--interactive")
                arguments.append(autoSquash ? "--autosquash" : "--no-autosquash")
            }
            if rebaseMerges { arguments.append("--rebase-merges") }
        }
        if let updateRefs { arguments.append(updateRefs ? "--update-refs" : "--no-update-refs") }
        if autoStash { arguments.append("--autostash") }
        if let onto, let from {
            let resolvedOnto = try await validateRevision(onto, repository: repository)
            let resolvedFrom = try await validateRevision(from, repository: repository)
            let resolvedBranch = try await validateRevision(branch ?? "HEAD", repository: repository)
            arguments.append(contentsOf: ["--onto", resolvedOnto.string, resolvedFrom.string, resolvedBranch.string])
        } else {
            arguments.append(upstream.string)
        }
        return arguments
    }

    private func validateRevision(
        _ revision: String,
        repository: ResolvedGitRepository
    ) async throws -> ObjectID {
        guard !revision.isEmpty, !revision.hasPrefix("$") else {
            throw RepositoryMutationError.invalidRevision(revision)
        }
        let result = try await rawMutation(
            ["rev-parse", "--verify", "--quiet", "\(revision)^{commit}"],
            in: repository
        )
        let resolved = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, let objectID = try? ObjectID.parse(resolved) else {
            throw RepositoryMutationError.invalidRevision(revision)
        }
        return objectID
    }

    private func validateInteractivePlan(
        _ items: [RepositoryRebaseTodoItem],
        expected: [RepositoryRebaseTodoItem]
    ) throws {
        guard !items.isEmpty else { throw RepositoryMutationError.emptyRebasePlan }
        let itemIDs = items.map(\.commitID)
        guard Set(itemIDs).count == itemIDs.count else {
            throw RepositoryMutationError.invalidRebasePlan("a commit appears more than once")
        }
        guard Set(itemIDs) == Set(expected.map(\.commitID)), itemIDs.count == expected.count else {
            throw RepositoryMutationError.invalidRebasePlan("the plan does not contain exactly the commits selected by Git")
        }
        var hasPreviousCommit = false
        for item in items {
            switch item.action {
            case .squash, .fixup:
                guard hasPreviousCommit else {
                    throw RepositoryMutationError.invalidRebasePlan("squash and fixup require a preceding non-dropped commit")
                }
                hasPreviousCommit = true
            case .reword(let message):
                guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw RepositoryMutationError.invalidRebasePlan("a reword action has an empty commit message")
                }
                hasPreviousCommit = true
            case .drop:
                break
            case .pick, .edit:
                hasPreviousCommit = true
            }
        }
    }

    private func rebaseTodoCommand(_ action: RepositoryRebaseTodoAction) -> String {
        switch action {
        case .pick: "pick"
        case .reword: "edit"
        case .edit: "edit"
        case .squash: "squash"
        case .fixup: "fixup"
        case .drop: "drop"
        }
    }

    private func sanitizeTodoSubject(_ subject: String) -> String {
        subject.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private func autosquashed(_ items: [RepositoryRebaseTodoItem]) -> [RepositoryRebaseTodoItem] {
        var result = items
        var index = 0
        while index < result.count {
            let item = result[index]
            let marker: (prefix: String, action: RepositoryRebaseTodoAction)?
            if item.subject.hasPrefix("fixup! ") { marker = ("fixup! ", .fixup) }
            else if item.subject.hasPrefix("squash! ") { marker = ("squash! ", .squash) }
            else { marker = nil }
            guard let marker, case .pick = item.action else { index += 1; continue }
            let target = String(item.subject.dropFirst(marker.prefix.count))
            let targetIndex = result[..<index].lastIndex {
                $0.commitID.string.hasPrefix(target) || $0.subject == target
            }
            guard let targetIndex else { index += 1; continue }
            result.remove(at: index)
            let insertion = result.index(after: targetIndex)
            result.insert(
                RepositoryRebaseTodoItem(commitID: item.commitID, subject: item.subject, action: marker.action),
                at: insertion
            )
            index = max(index, insertion + 1)
        }
        return result
    }

    private func resolveRebaseExecution(
        _ command: GitCommandResult,
        repository: ResolvedGitRepository,
        completionMessage: String
    ) async throws -> RepositoryMutationResult {
        let state = try await mutationState(in: repository)
        if !state.conflictedPaths.isEmpty {
            let output = command.standardErrorString.isEmpty ? command.standardOutputString : command.standardErrorString
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return RepositoryMutationResult(
                selectedCommitID: (try await currentRebaseHead(repository: repository)).map(RevisionID.object),
                outcome: .conflicts(state.conflictedPaths),
                message: detail.isEmpty ? "Rebase stopped with conflicts." : "Rebase stopped with conflicts. \(detail)"
            )
        }

        if state.rebaseInProgress {
            guard let stoppedCommit = try await currentRebaseHead(repository: repository) else {
                if !command.succeeded { throw commandError(from: command) }
                let headID = state.headID
                return RepositoryMutationResult(
                    selectedCommitID: headID.map(RevisionID.object),
                    outcome: .paused("Rebase is waiting for user input."),
                    message: "Rebase is waiting for user input."
                )
            }
            let stoppedAction = pendingRebaseActions.first {
                $0.key.hasPrefix(stoppedCommit.string) || stoppedCommit.string.hasPrefix($0.key)
            }?.value
            if case .reword(let message) = stoppedAction {
                var messageData = Data(message.utf8)
                if messageData.last != 10 { messageData.append(10) }
                let amend = try await git.run(
                    GitCommand(arguments: ["commit", "--amend", "--file=-"], accessesRemote: false, changesRepositoryState: true),
                    in: repository.rootURL,
                    standardInput: messageData,
                    environment: [:]
                )
                guard amend.succeeded else { throw commandError(from: amend) }
                let continued = try await git.run(
                    GitCommand(arguments: ["rebase", "--continue"], accessesRemote: false, changesRepositoryState: true),
                    in: repository.rootURL,
                    standardInput: nil,
                    environment: ["GIT_EDITOR": "true"]
                )
                return try await resolveRebaseExecution(
                    continued,
                    repository: repository,
                    completionMessage: completionMessage
                )
            }
            if !command.succeeded { throw commandError(from: command) }
            let subjectResult = try await git.run(
                GitCommand(
                    arguments: ["show", "-s", "--format=%s", stoppedCommit.string],
                    accessesRemote: false,
                    changesRepositoryState: false
                ),
                in: repository.rootURL
            )
            guard subjectResult.succeeded else { throw commandError(from: subjectResult) }
            let subject = subjectResult.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
            return RepositoryMutationResult(
                selectedCommitID: state.headID.map(RevisionID.object),
                outcome: .paused("Edit \(subject), amend it if needed, then continue or abort."),
                message: "Rebase paused for edit at \(subject)."
            )
        }

        guard command.succeeded else { throw commandError(from: command) }
        pendingRebaseActions = [:]
        let output = (command.standardOutputString + "\n" + command.standardErrorString)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = output.localizedCaseInsensitiveContains("up to date")
            ? "Current branch is up to date. Nothing to rebase."
            : completionMessage
        return RepositoryMutationResult(
            selectedCommitID: state.headID.map(RevisionID.object),
            outcome: .completed,
            message: message
        )
    }

    private func currentRebaseHead(repository: ResolvedGitRepository) async throws -> ObjectID? {
        let result = try await rawMutation(["rev-parse", "--verify", "--quiet", "REBASE_HEAD"], in: repository)
        guard result.succeeded else { return nil }
        let value = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        return try ObjectID.parseIfPresent(value)
    }

    private func prepareNativeRebaseTodo(_ todo: String) -> (todo: String, actions: [String: RepositoryRebaseTodoAction]) {
        var actions: [String: RepositoryRebaseTodoAction] = [:]
        let hadTrailingNewline = todo.hasSuffix("\n")
        let lines = todo.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            let line = String(raw)
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return line }
            let fields = trimmed.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { return line }
            let command = String(fields[0])
            let commitID = String(fields[1])
            let subject = fields.count > 2 ? String(fields[2]) : ""
            switch command {
            case "reword", "r":
                let message = subject.trimmingCharacters(in: .whitespacesAndNewlines)
                actions[commitID] = .reword(message)
                return "\(leading)edit \(commitID) \(subject)"
            case "edit", "e": actions[commitID] = .edit
            case "squash", "s": actions[commitID] = .squash
            case "fixup", "f": actions[commitID] = .fixup
            case "drop", "d": actions[commitID] = .drop
            case "pick", "p": actions[commitID] = .pick
            default: break
            }
            return line
        }
        var prepared = lines.joined(separator: "\n")
        if hadTrailingNewline, !prepared.hasSuffix("\n") { prepared.append("\n") }
        return (prepared, actions)
    }

    private func runCherryPickItems(
        _ items: [RepositoryCherryPickItem],
        options: RepositoryCherryPickOptions,
        repository: ResolvedGitRepository
    ) async throws -> RepositoryMutationResult {
        for (index, item) in items.enumerated() {
            var arguments = ["cherry-pick"]
            if !options.automaticallyCommit { arguments.append("--no-commit") }
            if options.addReference { arguments.append("-x") }
            if let mainline = item.mainlineParent { arguments += ["--mainline", String(mainline)] }
            arguments.append(item.commitID.string)

            let command = try await rawMutation(arguments, in: repository)
            if !command.succeeded {
                let state = try await mutationState(in: repository)
                if !state.conflictedPaths.isEmpty {
                    pendingCherryPickItems = Array(items.dropFirst(index + 1))
                    pendingCherryPickOptions = options
                    return try await cherryPickConflictResult(
                        command: command,
                        commitID: item.commitID,
                        repository: repository
                    )
                }
                pendingCherryPickItems = []
                pendingCherryPickOptions = nil
                throw commandError(from: command)
            }
        }

        pendingCherryPickItems = []
        pendingCherryPickOptions = nil
        let selectedID: RevisionID? = options.automaticallyCommit
            ? try await mutationState(in: repository).headID.map(RevisionID.object)
            : .index
        return RepositoryMutationResult(
            selectedCommitID: selectedID,
            outcome: .completed,
            message: "Cherry-picked \(items.count) commit(s)."
        )
    }

    private func cherryPickConflictResult(
        command: GitCommandResult,
        commitID: ObjectID,
        repository: ResolvedGitRepository
    ) async throws -> RepositoryMutationResult {
        let state = try await mutationState(in: repository)
        let output = command.standardErrorString.isEmpty ? command.standardOutputString : command.standardErrorString
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = "Cherry-pick stopped at \(commitID.shortString) with conflicts."
        return RepositoryMutationResult(
            selectedCommitID: .object(commitID),
            outcome: .conflicts(state.conflictedPaths),
            message: detail.isEmpty ? message : "\(message) \(detail)"
        )
    }

    private func stashConflictResult(
        command: GitCommandResult,
        message: String,
        repository: ResolvedGitRepository,
        selectedCommitID: RevisionID? = nil
    ) async throws -> RepositoryMutationResult {
        let state = try await mutationState(in: repository)
        let output = command.standardErrorString.isEmpty
            ? command.standardOutputString
            : command.standardErrorString
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return RepositoryMutationResult(
            selectedCommitID: selectedCommitID,
            outcome: .conflicts(state.conflictedPaths),
            message: detail.isEmpty ? message : "\(message) \(detail)"
        )
    }

    private func stashIndex(_ selector: String) -> Int? {
        guard let open = selector.range(of: "@{"),
              let close = selector[open.upperBound...].firstIndex(of: "}")
        else { return nil }
        return Int(selector[open.upperBound..<close])
    }

    package func mutationRepository() throws -> ResolvedGitRepository {
        guard let repository = resolvedRepository else { throw RepositoryMutationError.unavailable }
        if repository.isBare { throw RepositoryMutationError.bareRepository }
        return repository
    }

    private func normalizedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    package func commitEncodingName(in repository: ResolvedGitRepository) async -> String {
        guard let result = try? await rawMutation(["config", "--get", "i18n.commitEncoding"], in: repository),
              result.succeeded else { return "UTF-8" }
        let value = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "UTF-8" : value
    }

    private func readCommitText(at url: URL, encoding: String.Encoding, encodingName: String) throws -> String {
        let data = try Data(contentsOf: url)
        guard let value = String(data: data, encoding: encoding) else {
            throw RepositoryMutationError.commitMessageNotRepresentable(encodingName)
        }
        return value
    }

    package func refreshedMutationResult(message: String, selectedCommitID: RevisionID?) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        let outcome: RepositoryMutationOutcome = state.conflictedPaths.isEmpty
            ? .completed
            : .conflicts(state.conflictedPaths)
        return RepositoryMutationResult(
            selectedCommitID: selectedCommitID,
            outcome: outcome,
            message: message
        )
    }

    package func mutationState(in repository: ResolvedGitRepository) async throws -> RepositoryMutationState {
        async let branchResult = checkedMutation(["branch", "--show-current"], in: repository)
        async let headResult = rawMutation(["rev-parse", "--verify", "HEAD"], in: repository)
        async let statusResult = checkedMutation(
            ["--no-optional-locks", "status", "--porcelain=2", "-z", "--untracked-files=all"],
            in: repository
        )
        let branch = try await branchResult.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = try await headResult
        let records = try GitOutputParser.parsePorcelainV2(try await statusResult.standardOutput)
        return RepositoryMutationState(
            currentBranch: branch.isEmpty ? nil : branch,
            headID: head.succeeded
                ? try ObjectID.parse(head.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines))
                : nil,
            hasStagedChanges: records.contains { $0.indexStatus != "." && $0.indexStatus != " " },
            hasUnstagedChanges: records.contains { !$0.isUntracked && $0.worktreeStatus != "." && $0.worktreeStatus != " " },
            hasUntrackedFiles: records.contains { $0.isUntracked },
            conflictedPaths: records.filter(\.isConflict).map(\.path).sorted(),
            mergeInProgress: FileManager.default.fileExists(
                atPath: repository.gitDirectoryURL.appendingPathComponent("MERGE_HEAD").path
            ),
            cherryPickInProgress: FileManager.default.fileExists(
                atPath: repository.gitDirectoryURL.appendingPathComponent("CHERRY_PICK_HEAD").path
            ),
            revertInProgress: FileManager.default.fileExists(
                atPath: repository.gitDirectoryURL.appendingPathComponent("REVERT_HEAD").path
            ),
            rebaseInProgress: FileManager.default.fileExists(
                atPath: repository.gitDirectoryURL.appendingPathComponent("rebase-merge").path
            ) || FileManager.default.fileExists(
                atPath: repository.gitDirectoryURL.appendingPathComponent("rebase-apply").path
            )
        )
    }

    package func checkedMutation(_ arguments: [String], in repository: ResolvedGitRepository) async throws -> GitCommandResult {
        let result = try await rawMutation(arguments, in: repository)
        guard result.succeeded else { throw commandError(from: result) }
        return result
    }

    package func rawMutation(_ arguments: [String], in repository: ResolvedGitRepository) async throws -> GitCommandResult {
        try await git.run(
            GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: true),
            in: repository.rootURL
        )
    }

    private func conflictRead(_ arguments: [String], in repository: ResolvedGitRepository) async throws -> GitCommandResult {
        try await git.run(
            GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: false),
            in: repository.rootURL
        )
    }

    package func commandError(from result: GitCommandResult) -> GitError {
        let standardOutput = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        let standardError = result.standardErrorString.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail: String
        if !standardOutput.isEmpty, !standardError.isEmpty {
            detail = "stdout:\n\(standardOutput)\n\nstderr:\n\(standardError)"
        } else {
            detail = standardError.isEmpty ? standardOutput : standardError
        }
        return GitError.commandFailed(
            arguments: result.arguments,
            status: result.exitStatus,
            stderr: detail
        )
    }
}

enum GitCommitCommandBuilder {
    static func arguments(
        request: RepositoryCommitRequest,
        messageFile: String,
        hasStagedChanges: Bool,
        normalizedAuthor: String? = nil
    ) -> [String] {
        let isAmend = request.mode != .normal
        var arguments = ["commit"]
        if isAmend { arguments.append("--amend") }
        if request.noVerify { arguments.append("--no-verify") }
        if request.signOff { arguments.append("--signoff") }
        let author = normalizedAuthor ?? request.author?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
        if let author, !author.isEmpty { arguments += ["--author", author] }
        switch request.gpgSigning {
        case .gitDefault:
            break
        case .doNotSign:
            arguments.append("--no-gpg-sign")
        case .signDefault:
            arguments.append("--gpg-sign")
        case .signSpecificKey(let key):
            arguments.append("--gpg-sign=\(key.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        arguments += ["-F", messageFile]
        if request.mode == .amendMessageOnly {
            arguments += ["--only", "--allow-empty"]
        } else if request.allowEmpty || (isAmend && !hasStagedChanges) {
            arguments.append("--allow-empty")
        }
        if request.resetAuthor, isAmend { arguments.append("--reset-author") }
        return arguments
    }
}

enum GitCommitMessageFormatter {
    static func format(
        _ message: String,
        usingTemplate: Bool,
        ensureSecondLineEmpty: Bool
    ) -> String {
        guard !message.isEmpty else { return "" }
        var result: [String] = []
        var logicalLine = 1
        for line in message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if usingTemplate, line.hasPrefix("#") { continue }
            if ensureSecondLineEmpty, logicalLine == 2, !line.isEmpty { result.append("") }
            result.append(line)
            logicalLine += 1
        }
        return result.joined(separator: "\n") + "\n"
    }

    static func encoding(named name: String) throws -> String.Encoding {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(normalized as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else {
            throw RepositoryMutationError.invalidCommitEncoding(name)
        }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }
}

enum GitHunkPatchBuilder {
    static func patch(from diff: FileDiff, containing lineID: String) -> Data? {
        guard let selectedIndex = diff.lines.firstIndex(where: { $0.id == lineID }) else { return nil }
        let hunkIndexes = diff.lines.indices.filter { diff.lines[$0].kind == .hunk }
        guard !hunkIndexes.isEmpty else { return nil }
        let hunkStart = hunkIndexes.last(where: { $0 <= selectedIndex }) ?? hunkIndexes[0]
        let hunkEnd = hunkIndexes.first(where: { $0 > hunkStart }) ?? diff.lines.endIndex
        let headerEnd = hunkIndexes[0]
        let selectedLines = Array(diff.lines[..<headerEnd]) + Array(diff.lines[hunkStart..<hunkEnd])
        var text = selectedLines.map(serialize).joined(separator: "\n")
        while text.hasSuffix("\n\n") { text.removeLast() }
        if !text.hasSuffix("\n") { text.append("\n") }
        return Data(text.utf8)
    }

    private static func serialize(_ line: DiffLine) -> String {
        switch line.kind {
        case .addition: "+" + line.text
        case .deletion: "-" + line.text
        case .context: " " + line.text
        case .header, .hunk: line.text
        }
    }
}

enum GitSelectedLinePatchBuilder {
    private struct HunkRange {
        let start: Int
        let end: Int
    }

    static func patch(
        from diff: FileDiff,
        selecting lineIDs: Set<String>,
        direction: RepositoryHunkDirection,
        isNewFile: Bool = false,
        isRenamedFile: Bool = false
    ) -> Data? {
        let selectedChangedIDs = Set(diff.lines.filter {
            lineIDs.contains($0.id) && ($0.kind == .addition || $0.kind == .deletion)
        }.map(\.id))
        guard !selectedChangedIDs.isEmpty,
              let firstHunk = diff.lines.firstIndex(where: { $0.kind == .hunk }) else { return nil }

        let hunkStarts = diff.lines.indices.filter { diff.lines[$0].kind == .hunk }
        let ranges = hunkStarts.enumerated().map { offset, start in
            HunkRange(start: start, end: offset + 1 < hunkStarts.count ? hunkStarts[offset + 1] : diff.lines.endIndex)
        }
        var output = Array(diff.lines[..<firstHunk]).map(serialize)
        if direction == .unstage, isNewFile {
            output = correctedNewFileHeader(output)
        } else if direction == .unstage, isRenamedFile {
            output = correctedRenamedFileHeader(output)
        }
        var emittedHunk = false

        for range in ranges {
            let body = Array(diff.lines[(range.start + 1)..<range.end])
            guard body.contains(where: { selectedChangedIDs.contains($0.id) }) else { continue }
            guard let startLine = parseOldStart(diff.lines[range.start].text) else { continue }
            var rewritten: [String] = []
            var oldCount = 0
            var newCount = 0
            var previousPatchLine: DiffLine?

            for line in body {
                switch line.kind {
                case .context:
                    rewritten.append(" " + line.text)
                    oldCount += 1
                    newCount += 1
                    previousPatchLine = line
                case .deletion:
                    if selectedChangedIDs.contains(line.id) {
                        rewritten.append("-" + line.text)
                        oldCount += 1
                    } else if direction == .stage {
                        rewritten.append(" " + line.text)
                        oldCount += 1
                        newCount += 1
                    }
                    previousPatchLine = line
                case .addition:
                    if selectedChangedIDs.contains(line.id) {
                        rewritten.append("+" + line.text)
                        newCount += 1
                    } else if direction == .unstage {
                        rewritten.append(" " + line.text)
                        oldCount += 1
                        newCount += 1
                    }
                    previousPatchLine = line
                case .header:
                    if line.text.hasPrefix("\\ No newline at end of file"),
                       shouldEmitNoNewlineMarker(
                           after: previousPatchLine,
                           direction: direction,
                           selectedChangedIDs: selectedChangedIDs
                       ) {
                        rewritten.append(line.text)
                    }
                case .hunk:
                    break
                }
            }
            guard rewritten.contains(where: { $0.hasPrefix("+") || $0.hasPrefix("-") }) else { continue }
            output.append("@@ -\(startLine),\(oldCount) +\(startLine),\(newCount) @@")
            output.append(contentsOf: rewritten)
            emittedHunk = true
        }

        guard emittedHunk else { return nil }
        var text = output.joined(separator: "\n")
        if !text.hasSuffix("\n") { text.append("\n") }
        return Data(text.utf8)
    }

    private static func parseOldStart(_ header: String) -> Int? {
        let fields = header.split(separator: " ")
        guard fields.count >= 2 else { return nil }
        return Int(fields[1].dropFirst().split(separator: ",", maxSplits: 1)[0])
    }

    private static func correctedNewFileHeader(_ lines: [String]) -> [String] {
        guard let newPath = lines.first(where: { $0.hasPrefix("+++ ") }).map({ String($0.dropFirst(4)) }),
              newPath != "/dev/null" else { return lines }
        return lines.compactMap { line in
            if line.hasPrefix("new file mode ") { return nil }
            if line.hasPrefix("--- ") {
                let oldPath = newPath.hasPrefix("\"b/")
                    ? "\"a/" + newPath.dropFirst(3)
                    : newPath.replacingOccurrences(of: "b/", with: "a/", options: .anchored)
                return "--- \(oldPath)"
            }
            return line
        }
    }

    private static func correctedRenamedFileHeader(_ lines: [String]) -> [String] {
        guard let newPath = lines.first(where: { $0.hasPrefix("+++ ") }).map({ String($0.dropFirst(4)) }),
              newPath != "/dev/null" else { return lines }
        let oldPath = newPath.hasPrefix("\"b/")
            ? "\"a/" + newPath.dropFirst(3)
            : newPath.replacingOccurrences(of: "b/", with: "a/", options: .anchored)
        return lines.compactMap { line in
            if line.hasPrefix("similarity index ")
                || line.hasPrefix("rename from ")
                || line.hasPrefix("rename to ") {
                return nil
            }
            if line.hasPrefix("diff --git ") { return "diff --git \(oldPath) \(newPath)" }
            if line.hasPrefix("--- ") { return "--- \(oldPath)" }
            return line
        }
    }

    private static func shouldEmitNoNewlineMarker(
        after line: DiffLine?,
        direction: RepositoryHunkDirection,
        selectedChangedIDs: Set<String>
    ) -> Bool {
        guard let line else { return false }
        switch line.kind {
        case .context:
            return true
        case .deletion:
            return direction == .stage || selectedChangedIDs.contains(line.id)
        case .addition:
            return direction == .unstage || selectedChangedIDs.contains(line.id)
        case .header, .hunk:
            return false
        }
    }

    private static func serialize(_ line: DiffLine) -> String {
        switch line.kind {
        case .addition: "+" + line.text
        case .deletion: "-" + line.text
        case .context: " " + line.text
        case .header, .hunk: line.text
        }
    }
}
