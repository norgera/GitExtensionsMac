import CoreFoundation
import Foundation

enum CheckoutLocalChangesAction: Hashable, Sendable {
    case keep
    case merge
    case stash(includeUntracked: Bool, reapply: Bool)
    case force
}

enum RemoteCheckoutMode: Hashable, Sendable {
    case createTracking(localBranch: String)
    case resetTracking(localBranch: String)
    case detached
}

enum RepositoryCheckoutTarget: Hashable, Sendable {
    case localBranch(String)
    case remoteBranch(remote: String, branch: String, mode: RemoteCheckoutMode)
    case revision(String)
}

struct RepositoryCheckoutRequest: Hashable, Sendable {
    let target: RepositoryCheckoutTarget
    let localChanges: CheckoutLocalChangesAction
}

enum RepositoryHunkDirection: Hashable, Sendable {
    case stage
    case unstage
}

struct RepositoryHunkSelection: Hashable, Sendable {
    let file: ChangedFile
    let diff: FileDiff
    let lineID: String
    let direction: RepositoryHunkDirection
}

struct RepositoryLineSelection: Hashable, Sendable {
    let file: ChangedFile
    let diff: FileDiff
    let lineIDs: Set<String>
    let direction: RepositoryHunkDirection
}

enum RepositoryCommitMode: Hashable, Sendable {
    case normal
    case amend
    case amendMessageOnly
}

enum RepositoryCommitGPGSigning: Hashable, Sendable {
    case gitDefault
    case doNotSign
    case signDefault
    case signSpecificKey(String)
}

struct RepositoryCommitRequest: Hashable, Sendable {
    let message: String
    let mode: RepositoryCommitMode
    let stageAllBeforeCommit: Bool
    let allowEmpty: Bool
    let signOff: Bool
    let author: String?
    let resetAuthor: Bool
    let noVerify: Bool
    let gpgSigning: RepositoryCommitGPGSigning
    let messageEncoding: String?
    let usingTemplate: Bool
    let ensureSecondLineEmpty: Bool

    init(
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

struct RepositoryCommitState: Sendable {
    let mutationState: RepositoryMutationState
    let message: String
    let loadedTemplate: String?
    let commitEncoding: String
    let previousMessages: [String]
    let committer: String
    let isMergeCommit: Bool
    let rememberedAmend: Bool
    let messageLoadError: String?
}

enum RepositoryResetChangesScope: Hashable, Sendable {
    case worktree
    case all
}

struct RepositoryResetChangesRequest: Hashable, Sendable {
    let scope: RepositoryResetChangesScope
    let deleteUntracked: Bool
}

struct RepositoryStashCreateRequest: Hashable, Sendable {
    let message: String
    let includeUntracked: Bool
    let keepIndex: Bool
    let stagedOnly: Bool
}

struct RepositoryCherryPickItem: Hashable, Sendable {
    let commitID: String
    let mainlineParent: Int?
}

struct RepositoryCherryPickOptions: Hashable, Sendable {
    let automaticallyCommit: Bool
    let addReference: Bool
}

struct RepositoryCherryPickRequest: Hashable, Sendable {
    let items: [RepositoryCherryPickItem]
    let options: RepositoryCherryPickOptions
}

enum RepositoryRebaseTodoAction: Hashable, Sendable {
    case pick
    case reword(String)
    case edit
    case squash
    case fixup
    case drop
}

struct RepositoryRebaseTodoItem: Hashable, Sendable {
    let commitID: String
    let subject: String
    let action: RepositoryRebaseTodoAction
}

struct RepositoryRebaseRequest: Hashable, Sendable {
    let upstream: String
    let autoStash: Bool
}

struct RepositoryInteractiveRebaseRequest: Hashable, Sendable {
    let upstream: String
    let items: [RepositoryRebaseTodoItem]
    let autoStash: Bool
}

struct RepositoryMutationState: Equatable, Sendable {
    let currentBranch: String?
    let headID: String?
    let hasStagedChanges: Bool
    let hasUnstagedChanges: Bool
    let hasUntrackedFiles: Bool
    let conflictedPaths: [String]
    let cherryPickInProgress: Bool
    let rebaseInProgress: Bool

    var isDirty: Bool {
        hasStagedChanges || hasUnstagedChanges || hasUntrackedFiles || !conflictedPaths.isEmpty
    }
}

enum RepositoryMutationOutcome: Equatable, Sendable {
    case completed
    case conflicts([String])
    case paused(String)
}

struct RepositoryMutationResult: Sendable {
    let snapshot: RepositorySnapshot
    let selectedCommitID: String?
    let outcome: RepositoryMutationOutcome
    let message: String
}

enum RepositoryMutationError: LocalizedError, Sendable {
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
    case invalidMainline(commitID: String, parent: Int?, parentCount: Int)
    case cherryPickNotInProgress
    case mergeNotInProgress
    case operationInProgress(String)
    case rebaseNotInProgress
    case emptyRebasePlan
    case invalidRebasePlan(String)
    case unavailable

    var errorDescription: String? {
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
                "Cherry-picking merge \(commitID.prefix(8)) requires a mainline parent from 1 through \(parentCount); received \(parent.map(String.init) ?? "none")."
            } else {
                "Revision \(commitID.prefix(8)) is not a merge and cannot use a mainline parent."
            }
        case .cherryPickNotInProgress:
            "No cherry-pick is currently in progress."
        case .mergeNotInProgress:
            "No merge is currently in progress."
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

protocol RepositoryMutatingDataSource: RepositoryBrowsingDataSource {
    func loadMutationState() async throws -> RepositoryMutationState
    func checkout(_ request: RepositoryCheckoutRequest) async throws -> RepositoryMutationResult
    func stage(paths: [String]) async throws -> RepositoryMutationResult
    func unstage(paths: [String]) async throws -> RepositoryMutationResult
    func stageAll() async throws -> RepositoryMutationResult
    func unstageAll() async throws -> RepositoryMutationResult
    func applyHunk(_ selection: RepositoryHunkSelection) async throws -> RepositoryMutationResult
    func applyLines(_ selection: RepositoryLineSelection) async throws -> RepositoryMutationResult
    func loadCommitState(historyLimit: Int, showOnlyMyMessages: Bool, rememberAmend: Bool) async throws -> RepositoryCommitState
    func saveCommitDraft(message: String, amend: Bool, rememberAmend: Bool, encoding: String?) async throws
    func commit(_ request: RepositoryCommitRequest) async throws -> RepositoryMutationResult
    func resetChanges(_ request: RepositoryResetChangesRequest) async throws -> RepositoryMutationResult
    func resetSoftToParent() async throws -> RepositoryMutationResult
    func createBranch(named name: String) async throws -> RepositoryMutationResult
    func createStash(_ request: RepositoryStashCreateRequest) async throws -> RepositoryMutationResult
    func applyStash(_ stash: Stash) async throws -> RepositoryMutationResult
    func popStash(_ stash: Stash?) async throws -> RepositoryMutationResult
    func dropStash(_ stash: Stash) async throws -> RepositoryMutationResult
    func cherryPick(_ request: RepositoryCherryPickRequest) async throws -> RepositoryMutationResult
    func continueCherryPick() async throws -> RepositoryMutationResult
    func abortCherryPick() async throws -> RepositoryMutationResult
    func abortMerge() async throws -> RepositoryMutationResult
    func loadInteractiveRebasePlan(upstream: String) async throws -> [RepositoryRebaseTodoItem]
    func rebase(_ request: RepositoryRebaseRequest) async throws -> RepositoryMutationResult
    func interactiveRebase(_ request: RepositoryInteractiveRebaseRequest) async throws -> RepositoryMutationResult
    func continueRebase() async throws -> RepositoryMutationResult
    func skipRebase() async throws -> RepositoryMutationResult
    func abortRebase() async throws -> RepositoryMutationResult
}

extension GitRepositoryBrowsingDataSource: RepositoryMutatingDataSource {
    func loadMutationState() async throws -> RepositoryMutationState {
        guard let repository = resolvedRepository else {
            throw RepositoryMutationError.unavailable
        }
        if repository.isBare { throw RepositoryMutationError.bareRepository }
        return try await mutationState(in: repository)
    }

    func checkout(_ request: RepositoryCheckoutRequest) async throws -> RepositoryMutationResult {
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

        let snapshot = try await loadSnapshot()
        let selectedID = snapshot.commits.first(where: \.isHEAD)?.id
            ?? snapshot.commits.first(where: { !$0.isArtificial })?.id
        return RepositoryMutationResult(
            snapshot: snapshot,
            selectedCommitID: selectedID,
            outcome: outcome,
            message: message
        )
    }

    func stage(paths: [String]) async throws -> RepositoryMutationResult {
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
        return try await refreshedMutationResult(message: "Staged \(applicablePaths.count) path(s).", selectedCommitID: "$working-directory")
    }

    func unstage(paths: [String]) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let paths = normalizedPaths(paths)
        guard !paths.isEmpty else { throw RepositoryMutationError.noPaths }
        let state = try await mutationState(in: repository)
        if state.headID == nil {
            _ = try await checkedMutation(["rm", "--cached", "-r", "--ignore-unmatch", "--"] + paths, in: repository)
        } else {
            _ = try await checkedMutation(["reset", "--quiet", "HEAD", "--"] + paths, in: repository)
        }
        return try await refreshedMutationResult(message: "Unstaged \(paths.count) path(s).", selectedCommitID: "$index")
    }

    func stageAll() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        _ = try await checkedMutation(["add", "--all", "--"], in: repository)
        return try await refreshedMutationResult(message: "Staged all changes.", selectedCommitID: "$working-directory")
    }

    func unstageAll() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        if state.headID == nil {
            _ = try await checkedMutation(["rm", "--cached", "-r", "--ignore-unmatch", "--", "."], in: repository)
        } else {
            _ = try await checkedMutation(["reset", "--mixed", "--quiet", "HEAD"], in: repository)
        }
        return try await refreshedMutationResult(message: "Unstaged all changes.", selectedCommitID: "$index")
    }

    func applyHunk(_ selection: RepositoryHunkSelection) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        guard let patch = GitHunkPatchBuilder.patch(from: selection.diff, containing: selection.lineID) else {
            throw RepositoryMutationError.hunkUnavailable
        }
        var arguments = ["apply", "--cached", "--index", "--whitespace=nowarn"]
        if selection.direction == .unstage { arguments.append("--reverse") }
        let result = try await git.run(
            arguments: arguments,
            in: repository.rootURL,
            standardInput: patch,
            environment: [:]
        )
        guard result.succeeded else { throw commandError(from: result) }
        let verb = selection.direction == .stage ? "Staged" : "Unstaged"
        let selectedID = selection.direction == .stage ? "$working-directory" : "$index"
        return try await refreshedMutationResult(message: "\(verb) selected hunk in \(selection.file.path).", selectedCommitID: selectedID)
    }

    func applyLines(_ selection: RepositoryLineSelection) async throws -> RepositoryMutationResult {
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
            arguments: arguments,
            in: repository.rootURL,
            standardInput: patch,
            environment: [:]
        )
        guard result.succeeded else { throw commandError(from: result) }
        let verb = selection.direction == .stage ? "Staged" : "Unstaged"
        let selectedID = selection.direction == .stage ? "$working-directory" : "$index"
        return try await refreshedMutationResult(
            message: "\(verb) \(selection.lineIDs.count) selected line(s) in \(selection.file.path).",
            selectedCommitID: selectedID
        )
    }

    func loadCommitState(
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

    func saveCommitDraft(
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

    func commit(_ request: RepositoryCommitRequest) async throws -> RepositoryMutationResult {
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
            arguments: arguments,
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

        let snapshot = try await loadSnapshot()
        let headID = snapshot.commits.first(where: \.isHEAD)?.id
            ?? snapshot.commits.first(where: { !$0.isArtificial })?.id
        let verb = isAmend ? "Amended" : "Created"
        return RepositoryMutationResult(
            snapshot: snapshot,
            selectedCommitID: headID,
            outcome: .completed,
            message: "\(verb) commit \(headID.map { String($0.prefix(8)) } ?? "")."
        )
    }

    func resetChanges(_ request: RepositoryResetChangesRequest) async throws -> RepositoryMutationResult {
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
        return try await refreshedMutationResult(message: "Reset repository changes.", selectedCommitID: "$working-directory")
    }

    func resetSoftToParent() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        _ = try await checkedMutation(["reset", "--soft", "HEAD~1"], in: repository)
        return try await refreshedMutationResult(message: "Soft-reset HEAD to its parent.", selectedCommitID: "$index")
    }

    func createBranch(named name: String) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RepositoryMutationError.invalidBranchName(name) }
        let valid = try await rawMutation(["check-ref-format", "--branch", name], in: repository)
        guard valid.succeeded else { throw RepositoryMutationError.invalidBranchName(name) }
        _ = try await checkedMutation(["checkout", "-b", name], in: repository)
        return try await refreshedMutationResult(message: "Created and checked out \(name).", selectedCommitID: nil)
    }

    func createStash(_ request: RepositoryStashCreateRequest) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let beforeRef = try await rawMutation(["rev-parse", "--verify", "--quiet", "refs/stash"], in: repository)
            .standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)

        var arguments = ["stash"]
        if request.stagedOnly {
            arguments.append("--staged")
        } else {
            arguments.append("push")
            if request.includeUntracked { arguments.append("--include-untracked") }
            if request.keepIndex { arguments.append("--keep-index") }
            let message = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { arguments += ["--message", message] }
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
        let snapshot = try await loadSnapshot()
        let created = !afterRef.isEmpty && afterRef != beforeRef
        return RepositoryMutationResult(
            snapshot: snapshot,
            selectedCommitID: nil,
            outcome: .completed,
            message: created ? "Created stash." : "No local changes to save."
        )
    }

    func applyStash(_ stash: Stash) async throws -> RepositoryMutationResult {
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
                    selectedCommitID: stash.commitID
                )
            }
            throw commandError(from: command)
        }
        return try await refreshedMutationResult(message: "Applied \(stash.selector).", selectedCommitID: stash.commitID)
    }

    func popStash(_ stash: Stash?) async throws -> RepositoryMutationResult {
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
                    selectedCommitID: stash?.commitID
                )
            }
            throw commandError(from: command)
        }
        let snapshot = try await loadSnapshot()
        let selectedID = snapshot.commits.first(where: \.isHEAD)?.id
        return RepositoryMutationResult(
            snapshot: snapshot,
            selectedCommitID: selectedID,
            outcome: .completed,
            message: "Popped \(stash?.selector ?? "latest stash")."
        )
    }

    func dropStash(_ stash: Stash) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        try await validate(stash: stash, repository: repository)
        _ = try await checkedMutation(["stash", "drop", stash.selector], in: repository)
        let snapshot = try await loadSnapshot()
        let droppedIndex = stashIndex(stash.selector)
        let adjacentStash = droppedIndex.flatMap { index -> Stash? in
            guard !snapshot.stashes.isEmpty else { return nil }
            return snapshot.stashes[min(index, snapshot.stashes.count - 1)]
        }
        return RepositoryMutationResult(
            snapshot: snapshot,
            selectedCommitID: adjacentStash?.commitID ?? snapshot.commits.first(where: \.isHEAD)?.id,
            outcome: .completed,
            message: "Dropped \(stash.selector)."
        )
    }

    func cherryPick(_ request: RepositoryCherryPickRequest) async throws -> RepositoryMutationResult {
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

    func continueCherryPick() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        guard state.cherryPickInProgress else { throw RepositoryMutationError.cherryPickNotInProgress }
        guard state.conflictedPaths.isEmpty else {
            throw RepositoryMutationError.unresolvedConflicts(state.conflictedPaths)
        }
        let continued = try await git.run(
            arguments: ["cherry-pick", "--continue"],
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
        let snapshot = try await loadSnapshot()
        return RepositoryMutationResult(
            snapshot: snapshot,
            selectedCommitID: snapshot.commits.first(where: \.isHEAD)?.id,
            outcome: .completed,
            message: "Cherry-pick continued."
        )
    }

    func abortCherryPick() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        guard state.cherryPickInProgress else { throw RepositoryMutationError.cherryPickNotInProgress }
        _ = try await checkedMutation(["cherry-pick", "--abort"], in: repository)
        pendingCherryPickItems = []
        pendingCherryPickOptions = nil
        let snapshot = try await loadSnapshot()
        return RepositoryMutationResult(
            snapshot: snapshot,
            selectedCommitID: snapshot.commits.first(where: \.isHEAD)?.id,
            outcome: .completed,
            message: "Cherry-pick aborted."
        )
    }

    func abortMerge() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        guard FileManager.default.fileExists(atPath: repository.gitDirectoryURL.appendingPathComponent("MERGE_HEAD").path) else {
            throw RepositoryMutationError.mergeNotInProgress
        }
        _ = try await checkedMutation(["merge", "--abort"], in: repository)
        let snapshot = try await loadSnapshot()
        return RepositoryMutationResult(
            snapshot: snapshot,
            selectedCommitID: snapshot.commits.first(where: \.isHEAD)?.id,
            outcome: .completed,
            message: "Merge aborted."
        )
    }

    func loadInteractiveRebasePlan(upstream: String) async throws -> [RepositoryRebaseTodoItem] {
        let repository = try mutationRepository()
        let resolvedUpstream = try await validateRevision(upstream, repository: repository)
        let output = try await checkedMutation([
            "log", "--reverse", "--topo-order", "--no-merges",
            "--format=%H%x00%s", "\(resolvedUpstream)..HEAD"
        ], in: repository).standardOutputString
        return output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { return nil }
            return RepositoryRebaseTodoItem(
                commitID: String(fields[0]),
                subject: String(fields[1]),
                action: .pick
            )
        }
    }

    func rebase(_ request: RepositoryRebaseRequest) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        try validateCanStartRebase(state)
        let upstream = try await validateRevision(request.upstream, repository: repository)
        pendingRebaseActions = [:]
        var arguments = ["rebase"]
        if request.autoStash { arguments.append("--autostash") }
        arguments.append(upstream)
        let command = try await rawMutation(arguments, in: repository)
        return try await resolveRebaseExecution(
            command,
            repository: repository,
            completionMessage: "Rebase completed."
        )
    }

    func interactiveRebase(_ request: RepositoryInteractiveRebaseRequest) async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        try validateCanStartRebase(state)
        let upstream = try await validateRevision(request.upstream, repository: repository)
        let expected = try await loadInteractiveRebasePlan(upstream: upstream)
        try validateInteractivePlan(request.items, expected: expected)

        pendingRebaseActions = Dictionary(uniqueKeysWithValues: request.items.map { ($0.commitID, $0.action) })
        let todo = request.items.map { item in
            "\(rebaseTodoCommand(item.action)) \(item.commitID) \(sanitizeTodoSubject(item.subject))"
        }.joined(separator: "\n") + "\n"
        var arguments = ["rebase", "--interactive", "--no-autosquash"]
        if request.autoStash { arguments.append("--autostash") }
        arguments.append(upstream)
        let command = try await git.run(
            arguments: arguments,
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

    func continueRebase() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        guard state.rebaseInProgress else { throw RepositoryMutationError.rebaseNotInProgress }
        guard state.conflictedPaths.isEmpty else {
            throw RepositoryMutationError.unresolvedConflicts(state.conflictedPaths)
        }
        let command = try await git.run(
            arguments: ["rebase", "--continue"],
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

    func skipRebase() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        guard state.rebaseInProgress else { throw RepositoryMutationError.rebaseNotInProgress }
        let command = try await git.run(
            arguments: ["rebase", "--skip"],
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

    func abortRebase() async throws -> RepositoryMutationResult {
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        guard state.rebaseInProgress else { throw RepositoryMutationError.rebaseNotInProgress }
        _ = try await checkedMutation(["rebase", "--abort"], in: repository)
        pendingRebaseActions = [:]
        let snapshot = try await loadSnapshot()
        return RepositoryMutationResult(
            snapshot: snapshot,
            selectedCommitID: snapshot.commits.first(where: \.isHEAD)?.id,
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
            if state.currentBranch == name { throw RepositoryMutationError.currentBranch(name) }
            arguments.append(name)

        case .revision(let objectID):
            guard !objectID.isEmpty, !objectID.hasPrefix("$") else {
                throw RepositoryMutationError.invalidRevision(objectID)
            }
            arguments += ["--detach", objectID]

        case .remoteBranch(let remote, let branch, let mode):
            let remoteRef = "\(remote)/\(branch)"
            switch mode {
            case .detached:
                arguments += ["--detach", remoteRef]
            case .createTracking(let localBranch):
                try await validateBranchName(localBranch, repository: repository)
                arguments += ["-b", localBranch, "--track", remoteRef]
            case .resetTracking(let localBranch):
                try await validateBranchName(localBranch, repository: repository)
                arguments += ["-B", localBranch, "--track", remoteRef]
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
        guard result.succeeded, resolved == stash.commitID else {
            throw RepositoryMutationError.invalidStash(stash.selector)
        }
    }

    private func validateCherryPickItems(
        _ items: [RepositoryCherryPickItem],
        repository: ResolvedGitRepository
    ) async throws {
        for item in items {
            guard !item.commitID.isEmpty, !item.commitID.hasPrefix("$") else {
                throw RepositoryMutationError.invalidRevision(item.commitID)
            }
            let resolved = try await rawMutation(
                ["rev-parse", "--verify", "--quiet", "\(item.commitID)^{commit}"],
                in: repository
            )
            guard resolved.succeeded,
                  resolved.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines) == item.commitID
            else { throw RepositoryMutationError.invalidRevision(item.commitID) }

            let parents = try await checkedMutation(["rev-list", "--parents", "-n", "1", item.commitID], in: repository)
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

    private func validateRevision(
        _ revision: String,
        repository: ResolvedGitRepository
    ) async throws -> String {
        guard !revision.isEmpty, !revision.hasPrefix("$") else {
            throw RepositoryMutationError.invalidRevision(revision)
        }
        let result = try await rawMutation(
            ["rev-parse", "--verify", "--quiet", "\(revision)^{commit}"],
            in: repository
        )
        let resolved = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !resolved.isEmpty else {
            throw RepositoryMutationError.invalidRevision(revision)
        }
        return resolved
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

    private func resolveRebaseExecution(
        _ command: GitCommandResult,
        repository: ResolvedGitRepository,
        completionMessage: String
    ) async throws -> RepositoryMutationResult {
        let state = try await mutationState(in: repository)
        if !state.conflictedPaths.isEmpty {
            let snapshot = try await loadSnapshot()
            let output = command.standardErrorString.isEmpty ? command.standardOutputString : command.standardErrorString
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return RepositoryMutationResult(
                snapshot: snapshot,
                selectedCommitID: try await currentRebaseHead(repository: repository),
                outcome: .conflicts(state.conflictedPaths),
                message: detail.isEmpty ? "Rebase stopped with conflicts." : "Rebase stopped with conflicts. \(detail)"
            )
        }

        if state.rebaseInProgress {
            guard let stoppedCommit = try await currentRebaseHead(repository: repository) else {
                if !command.succeeded { throw commandError(from: command) }
                let snapshot = try await loadSnapshot()
                return RepositoryMutationResult(
                    snapshot: snapshot,
                    selectedCommitID: snapshot.commits.first(where: \.isHEAD)?.id,
                    outcome: .paused("Rebase is waiting for user input."),
                    message: "Rebase is waiting for user input."
                )
            }
            if case .reword(let message) = pendingRebaseActions[stoppedCommit] {
                var messageData = Data(message.utf8)
                if messageData.last != 10 { messageData.append(10) }
                let amend = try await git.run(
                    arguments: ["commit", "--amend", "--file=-"],
                    in: repository.rootURL,
                    standardInput: messageData,
                    environment: [:]
                )
                guard amend.succeeded else { throw commandError(from: amend) }
                let continued = try await git.run(
                    arguments: ["rebase", "--continue"],
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
            let snapshot = try await loadSnapshot()
            let subject = snapshot.commits.first(where: { $0.id == stoppedCommit })?.subject ?? String(stoppedCommit.prefix(8))
            return RepositoryMutationResult(
                snapshot: snapshot,
                selectedCommitID: snapshot.commits.first(where: \.isHEAD)?.id,
                outcome: .paused("Edit \(subject), amend it if needed, then continue or abort."),
                message: "Rebase paused for edit at \(subject)."
            )
        }

        guard command.succeeded else { throw commandError(from: command) }
        pendingRebaseActions = [:]
        let snapshot = try await loadSnapshot()
        return RepositoryMutationResult(
            snapshot: snapshot,
            selectedCommitID: snapshot.commits.first(where: \.isHEAD)?.id,
            outcome: .completed,
            message: completionMessage
        )
    }

    private func currentRebaseHead(repository: ResolvedGitRepository) async throws -> String? {
        let result = try await rawMutation(["rev-parse", "--verify", "--quiet", "REBASE_HEAD"], in: repository)
        guard result.succeeded else { return nil }
        let value = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
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
            arguments.append(item.commitID)

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
        let snapshot = try await loadSnapshot()
        let selectedID = options.automaticallyCommit
            ? snapshot.commits.first(where: \.isHEAD)?.id
            : "$index"
        return RepositoryMutationResult(
            snapshot: snapshot,
            selectedCommitID: selectedID,
            outcome: .completed,
            message: "Cherry-picked \(items.count) commit(s)."
        )
    }

    private func cherryPickConflictResult(
        command: GitCommandResult,
        commitID: String,
        repository: ResolvedGitRepository
    ) async throws -> RepositoryMutationResult {
        let state = try await mutationState(in: repository)
        let snapshot = try await loadSnapshot()
        let output = command.standardErrorString.isEmpty ? command.standardOutputString : command.standardErrorString
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = "Cherry-pick stopped at \(commitID.prefix(8)) with conflicts."
        return RepositoryMutationResult(
            snapshot: snapshot,
            selectedCommitID: commitID,
            outcome: .conflicts(state.conflictedPaths),
            message: detail.isEmpty ? message : "\(message) \(detail)"
        )
    }

    private func stashConflictResult(
        command: GitCommandResult,
        message: String,
        repository: ResolvedGitRepository,
        selectedCommitID: String? = nil
    ) async throws -> RepositoryMutationResult {
        let state = try await mutationState(in: repository)
        let snapshot = try await loadSnapshot()
        let output = command.standardErrorString.isEmpty
            ? command.standardOutputString
            : command.standardErrorString
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return RepositoryMutationResult(
            snapshot: snapshot,
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

    private func mutationRepository() throws -> ResolvedGitRepository {
        guard let repository = resolvedRepository else { throw RepositoryMutationError.unavailable }
        if repository.isBare { throw RepositoryMutationError.bareRepository }
        return repository
    }

    private func normalizedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func commitEncodingName(in repository: ResolvedGitRepository) async -> String {
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

    private func refreshedMutationResult(message: String, selectedCommitID: String?) async throws -> RepositoryMutationResult {
        let snapshot = try await loadSnapshot()
        let repository = try mutationRepository()
        let state = try await mutationState(in: repository)
        let outcome: RepositoryMutationOutcome = state.conflictedPaths.isEmpty
            ? .completed
            : .conflicts(state.conflictedPaths)
        return RepositoryMutationResult(
            snapshot: snapshot,
            selectedCommitID: selectedCommitID,
            outcome: outcome,
            message: message
        )
    }

    func mutationState(in repository: ResolvedGitRepository) async throws -> RepositoryMutationState {
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
            headID: head.succeeded ? head.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            hasStagedChanges: records.contains { $0.indexStatus != "." && $0.indexStatus != " " },
            hasUnstagedChanges: records.contains { !$0.isUntracked && $0.worktreeStatus != "." && $0.worktreeStatus != " " },
            hasUntrackedFiles: records.contains { $0.isUntracked },
            conflictedPaths: records.filter(\.isConflict).map(\.path).sorted(),
            cherryPickInProgress: FileManager.default.fileExists(
                atPath: repository.gitDirectoryURL.appendingPathComponent("CHERRY_PICK_HEAD").path
            ),
            rebaseInProgress: FileManager.default.fileExists(
                atPath: repository.gitDirectoryURL.appendingPathComponent("rebase-merge").path
            ) || FileManager.default.fileExists(
                atPath: repository.gitDirectoryURL.appendingPathComponent("rebase-apply").path
            )
        )
    }

    private func checkedMutation(_ arguments: [String], in repository: ResolvedGitRepository) async throws -> GitCommandResult {
        let result = try await rawMutation(arguments, in: repository)
        guard result.succeeded else { throw commandError(from: result) }
        return result
    }

    private func rawMutation(_ arguments: [String], in repository: ResolvedGitRepository) async throws -> GitCommandResult {
        try await git.run(arguments: arguments, in: repository.rootURL)
    }

    private func commandError(from result: GitCommandResult) -> GitError {
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
