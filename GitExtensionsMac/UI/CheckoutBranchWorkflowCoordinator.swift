import GitExtensionsCore
import GitCommands
import AppKit

@MainActor
final class CheckoutBranchWorkflowCoordinator {
    private let source: any RepositoryCheckoutBranchDataSource
    private let stashSource: (any RepositoryStashDataSource)?
    private let pullSource: (any RepositoryPullingDataSource)?
    private weak var owner: NSWindow?
    private var context: RepositoryBranchContext
    private let revisions: [Commit]
    private let onRepositoryChanged: (RevisionID?) -> Void
    private let onStatus: (String) -> Void
    private let onConflicts: () -> Void
    private let onMerge: (String) -> Void
    private let onRebase: (Commit) -> Void
    private var task: Task<Void, Never>?

    init(
        source: any RepositoryCheckoutBranchDataSource,
        stashSource: (any RepositoryStashDataSource)?,
        pullSource: (any RepositoryPullingDataSource)?,
        context: RepositoryBranchContext,
        revisions: [Commit],
        owner: NSWindow,
        onRepositoryChanged: @escaping (RevisionID?) -> Void,
        onStatus: @escaping (String) -> Void,
        onConflicts: @escaping () -> Void,
        onMerge: @escaping (String) -> Void,
        onRebase: @escaping (Commit) -> Void
    ) {
        self.source = source
        self.stashSource = stashSource
        self.pullSource = pullSource
        self.context = context
        self.revisions = revisions
        self.owner = owner
        self.onRepositoryChanged = onRepositoryChanged
        self.onStatus = onStatus
        self.onConflicts = onConflicts
        self.onMerge = onMerge
        self.onRebase = onRebase
    }

    deinit { task?.cancel() }

    func checkout(_ target: CheckoutDialogTarget, confirmDirectCheckout: Bool = false) {
        switch target {
        case .revision(let commit): checkoutRevision(commit)
        case .local, .remote: checkoutBranch(initialTarget: target, confirmDirectCheckout: confirmDirectCheckout)
        }
    }

    func checkoutBranch(initialTarget: CheckoutDialogTarget?, confirmDirectCheckout: Bool = false) {
        guard !context.repository.isBare, let owner else { return }
        let startingContext = context
        let previousSelection = startingContext.headID.map(RevisionID.object)
        replaceTask { [weak self, weak owner] in
            guard let self, let owner else { return }
            do {
                onStatus("Checking repository state…")
                let state = try await source.loadMutationState()
                guard !Task.isCancelled else { return }
                if confirmDirectCheckout,
                   AppSettingsStore.shared.checkoutBranchPreferences.confirmDirectCheckout,
                   let initialTarget {
                    let targetName: String = switch initialTarget {
                    case .local(let branch): branch.name
                    case .remote(let branch): branch.remoteName.map { "\($0)/\(branch.name)" } ?? branch.name
                    case .revision(let commit): commit.shortID
                    }
                    guard await confirmCheckout(targetName, owner: owner) else {
                        onStatus("Checkout cancelled")
                        return
                    }
                }

                let preferences = AppSettingsStore.shared.checkoutBranchPreferences
                let effectiveDirty = state.isDirty || !preferences.checkForUncommittedChanges
                let draft: CheckoutBranchDialogResult?
                if case .local(let branch) = initialTarget,
                   !preferences.alwaysShowDialog,
                   (!effectiveDirty || preferences.useDefaultLocalChangesAction) {
                    draft = CheckoutBranchDialogResult(
                        request: RepositoryCheckoutRequest(
                            target: .localBranch(branch.name),
                            localChanges: effectiveDirty
                                ? checkoutAction(preferences.localChangesAction, preferences: preferences)
                                : .keep
                        ),
                        needsAutoPopPrompt: effectiveDirty
                            && preferences.localChangesAction == .stash
                            && preferences.autoPopStash == .ask
                    )
                } else {
                    draft = await CheckoutBranchDialogs.checkoutBranch(
                        source: source,
                        context: startingContext,
                        revisions: revisions,
                        state: state,
                        initialTarget: initialTarget,
                        updateSubmodules: false,
                        owner: owner
                    )
                }
                guard let draft else { onStatus("Checkout cancelled"); return }
                guard await confirmRemoteResetIfNeeded(draft.request, context: startingContext, owner: owner) else {
                    onStatus("Checkout cancelled")
                    return
                }

                onStatus("Checking out…")
                var result = try await source.checkout(draft.request)
                guard !Task.isCancelled else { return }
                await publish(selected: result.selectedCommitID)
                result = try await updateSubmodulesIfRequested(result, previousContext: startingContext, owner: owner)

                if draft.needsAutoPopPrompt,
                   case .stash = draft.request.localChanges,
                   await shouldPopAutomaticStash(owner: owner),
                   let stashSource {
                    onStatus("Reapplying stashed changes…")
                    result = try await stashSource.popStash(nil)
                    await publish(selected: result.selectedCommitID)
                }
                present(result)
            } catch is CancellationError {
                return
            } catch {
                await refreshAfterFailure(previousSelection: previousSelection)
                onStatus(error.localizedDescription)
                await showError(error, title: "Checkout failed", owner: owner)
            }
        }
    }

    func checkoutRevision(_ commit: Commit) {
        guard !context.repository.isBare, !commit.isArtificial, let owner else { return }
        let startingContext = context
        let previousSelection = startingContext.headID.map(RevisionID.object)
        replaceTask { [weak self, weak owner] in
            guard let self, let owner else { return }
            guard let request = await CheckoutBranchDialogs.checkoutRevision(
                commit: commit,
                revisions: revisions,
                source: source,
                updateSubmodules: false,
                owner: owner
            ) else { onStatus("Checkout cancelled"); return }
            do {
                onStatus("Checking out \(commit.shortID)…")
                var result = try await source.checkout(request)
                guard !Task.isCancelled else { return }
                await publish(selected: result.selectedCommitID)
                result = try await updateSubmodulesIfRequested(result, previousContext: startingContext, owner: owner)
                present(result)
            } catch is CancellationError {
                return
            } catch {
                await refreshAfterFailure(previousSelection: previousSelection)
                onStatus(error.localizedDescription)
                await showError(error, title: "Checkout failed", owner: owner)
            }
        }
    }

    func createBranch(
        sourceRevision: Commit?,
        suggestedPrefix: String? = nil,
        checkoutAfterCreation: Bool? = nil,
        userCanChangeRevision: Bool = true,
        couldBeOrphan: Bool = true
    ) {
        guard !context.repository.isBare, sourceRevision?.isArtificial != true, let owner else { return }
        let startingContext = context
        let previousSelection = startingContext.headID.map(RevisionID.object)
        replaceTask { [weak self, weak owner] in
            guard let self, let owner else { return }
            do {
                let state = try await source.loadMutationState()
                guard let request = await CheckoutBranchDialogs.createBranch(
                    source: source,
                    context: startingContext,
                    revisions: revisions,
                    sourceRevision: sourceRevision,
                    suggestedPrefix: suggestedPrefix,
                    isUnbornRepository: state.headID == nil,
                    updateSubmodules: false,
                    checkoutAfterCreation: checkoutAfterCreation,
                    userCanChangeRevision: userCanChangeRevision,
                    couldBeOrphan: couldBeOrphan,
                    owner: owner
                ) else { onStatus("Create branch cancelled"); return }
                onStatus("Creating branch…")
                var result = try await source.createBranch(request)
                guard !Task.isCancelled else { return }
                await publish(selected: result.selectedCommitID ?? previousSelection)
                if request.checkoutAfterCreation {
                    result = try await updateSubmodulesIfRequested(result, previousContext: startingContext, owner: owner)
                }
                onStatus(result.message)
            } catch is CancellationError {
                return
            } catch {
                await refreshAfterFailure(previousSelection: previousSelection)
                onStatus(error.localizedDescription)
                await showError(error, title: "Create branch failed", owner: owner)
            }
        }
    }

    func deleteBranches(initiallySelected: [String]) {
        guard !context.repository.isBare, let owner else { return }
        let startingContext = context
        let previousSelection = startingContext.headID.map(RevisionID.object)
        replaceTask { [weak self, weak owner] in
            guard let self, let owner else { return }
            guard let names = await CheckoutBranchDialogs.deleteBranches(
                availableBranches: startingContext.branches,
                initiallySelected: initiallySelected,
                owner: owner
            ) else { onStatus("Delete branch cancelled"); return }
            do {
                var candidates = try await source.branchDeletionCandidates(names: names)
                if let current = candidates.first(where: \.isCurrent) {
                    throw RepositoryMutationError.currentBranch(current.name)
                }
                if let main = candidates.first(where: { $0.worktreePath != nil && $0.isMainWorktree }),
                   let path = main.worktreePath {
                    await showInformation(
                        "The branch ‘\(main.name)’ cannot be deleted because it is checked out in the main worktree at:\n\(path)",
                        title: "Delete Branches",
                        owner: owner
                    )
                    candidates.removeAll { $0.worktreePath != nil && $0.isMainWorktree }
                }
                let linked = candidates.filter { $0.worktreePath != nil && !$0.isMainWorktree }
                let removeLinkedWorktrees = linked.isEmpty
                    ? false
                    : await confirmLinkedWorktreeDeletion(linked, owner: owner)
                if !linked.isEmpty, !removeLinkedWorktrees {
                    let linkedNames = Set(linked.map(\.name))
                    candidates.removeAll { linkedNames.contains($0.name) }
                }
                guard !candidates.isEmpty else { onStatus("No branches were deleted"); return }
                let unmerged = candidates.filter { !$0.isMergedIntoHEAD }.map(\.name)
                let allowUnmerged: Bool
                if unmerged.isEmpty || AppSettingsStore.shared.checkoutBranchPreferences.dontConfirmDeleteUnmerged {
                    allowUnmerged = true
                } else {
                    allowUnmerged = await confirmUnmergedBranchDeletion(unmerged, owner: owner)
                }
                guard allowUnmerged else { onStatus("Delete branch cancelled"); return }
                onStatus("Deleting branch…")
                let result = try await source.deleteBranches(RepositoryDeleteBranchesRequest(
                    names: candidates.map(\.name),
                    allowUnmerged: allowUnmerged,
                    removeLinkedWorktrees: removeLinkedWorktrees
                ))
                guard !Task.isCancelled else { return }
                await publish(selected: previousSelection)
                onStatus(result.message)
            } catch is CancellationError {
                return
            } catch {
                await refreshAfterFailure(previousSelection: previousSelection)
                onStatus(error.localizedDescription)
                await showError(error, title: "Delete branch failed", owner: owner)
            }
        }
    }

    func renameBranch(_ name: String) {
        guard let owner else { return }
        let startingContext = context
        let previousSelection = startingContext.headID.map(RevisionID.object)
        replaceTask { [weak self, weak owner] in
            guard let self, let owner else { return }
            let names = Set(startingContext.branches.filter { !$0.isRemote }.map(\.name))
            guard let request = await CheckoutBranchDialogs.renameBranch(
                name: name,
                existingNames: names,
                source: source,
                owner: owner
            ) else { onStatus("Rename branch cancelled"); return }
            do {
                onStatus("Renaming branch…")
                let result = try await source.renameBranch(request)
                guard !Task.isCancelled else { return }
                await publish(selected: previousSelection)
                onStatus(result.message)
            } catch is CancellationError {
                return
            } catch {
                await refreshAfterFailure(previousSelection: previousSelection)
                onStatus(error.localizedDescription)
                await showError(error, title: "Rename branch failed", owner: owner)
            }
        }
    }

    func fetchRemoteBranch(_ branch: Branch, then followUp: CheckoutBranchFetchFollowUp) {
        guard let pullSource, let remote = branch.remoteName, let owner else { return }
        let previousSelection = context.headID.map(RevisionID.object)
        replaceTask { [weak self, weak owner] in
            guard let self, let owner else { return }
            do {
                onStatus("Fetching \(remote)/\(branch.name)…")
                let result = try await pullSource.performPull(RepositoryPullRequest(
                    source: .remote(remote),
                    mode: .fetch,
                    remoteBranch: branch.name
                )) { _ in }
                guard !Task.isCancelled else { return }
                await publish(selected: previousSelection)
                guard result.outcome == .completed else {
                    onStatus(result.message)
                    await showInformation(result.message, title: "Fetch failed", owner: owner)
                    return
                }
                onStatus(result.message)
                let refreshedContext = try await source.loadRepositoryState().branchContext
                context = refreshedContext
                let refreshed = refreshedContext.remotes
                    .first(where: { $0.name == remote })?
                    .branches.first(where: { $0.name == branch.name }) ?? branch
                switch followUp {
                case .none: break
                case .checkout: checkout(.remote(refreshed), confirmDirectCheckout: true)
                case .create:
                    createBranch(
                        sourceRevision: revisions.first { $0.id == .object(refreshed.commitID) }
                            ?? RevisionCommitBuilder.placeholderRevision(id: refreshed.commitID)
                    )
                case .merge:
                    onMerge("\(remote)/\(refreshed.name)")
                case .rebase:
                    onRebase(
                        revisions.first { $0.id == .object(refreshed.commitID) }
                            ?? RevisionCommitBuilder.placeholderRevision(id: refreshed.commitID)
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                onStatus(error.localizedDescription)
                await showError(error, title: "Fetch failed", owner: owner)
            }
        }
    }

    private func replaceTask(_ operation: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { @MainActor in await operation() }
    }

    private func publish(selected: RevisionID?) async {
        if let refreshed = try? await source.loadRepositoryState().branchContext, !Task.isCancelled {
            context = refreshed
        }
        onRepositoryChanged(selected)
    }

    private func refreshAfterFailure(previousSelection: RevisionID?) async {
        guard let refreshed = try? await source.loadRepositoryState().branchContext, !Task.isCancelled else { return }
        context = refreshed
        onRepositoryChanged(previousSelection)
    }

    private func checkoutAction(
        _ preference: CheckoutLocalChangesPreference,
        preferences: CheckoutBranchPreferences
    ) -> CheckoutLocalChangesAction {
        switch preference {
        case .keep: .keep
        case .merge: .merge
        case .force: .force
        case .stash:
            .stash(
                includeUntracked: AppSettingsStore.shared.pullPreferences.includeUntrackedInAutoStash,
                reapply: preferences.autoPopStash == .always
            )
        }
    }

    private func present(_ result: RepositoryMutationResult) {
        switch result.outcome {
        case .completed: onStatus(result.message)
        case .conflicts(let paths):
            onStatus("Checkout completed with conflicts in \(paths.count) path(s)")
            onConflicts()
        case .paused(let reason): onStatus(reason)
        }
    }

    private func confirmRemoteResetIfNeeded(
        _ request: RepositoryCheckoutRequest,
        context: RepositoryBranchContext,
        owner: NSWindow
    ) async -> Bool {
        guard case .remoteBranch(let remote, let branch, let mode) = request.target,
              case .resetTracking(let localName) = mode,
              let local = context.branches.first(where: { !$0.isRemote && $0.name == localName }),
              let remoteBranch = context.remotes
                  .first(where: { $0.name == remote })?
                  .branches.first(where: { $0.name == branch }),
              (try? await source.isAncestor(local.commitID, of: remoteBranch.commitID)) == false else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset branch"
        alert.informativeText = "Resetting ‘\(localName)’ to ‘\(remote)/\(branch)’ is not a fast-forward and can discard commits. Continue?"
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        return await response(alert, owner: owner) == .alertFirstButtonReturn
    }

    private func updateSubmodulesIfRequested(
        _ result: RepositoryMutationResult,
        previousContext: RepositoryBranchContext,
        owner: NSWindow
    ) async throws -> RepositoryMutationResult {
        let previousHEAD = previousContext.headID
        let refreshedContext = try await source.loadRepositoryState().branchContext
        context = refreshedContext
        let currentHEAD = refreshedContext.headID
        guard previousHEAD != currentHEAD,
              await shouldUpdateSubmodules(context: refreshedContext, owner: owner) else { return result }
        let updated = try await source.updateSubmodulesAfterCheckout()
        await publish(selected: updated.selectedCommitID ?? result.selectedCommitID)
        return RepositoryMutationResult(
            selectedCommitID: updated.selectedCommitID ?? result.selectedCommitID,
            outcome: updated.outcome,
            message: result.message + " Updated submodules."
        )
    }

    private func confirmCheckout(_ name: String, owner: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Checkout branch"
        alert.informativeText = "Checkout ‘\(name)’?"
        alert.addButton(withTitle: "Checkout")
        alert.addButton(withTitle: "Cancel")
        return await response(alert, owner: owner) == .alertFirstButtonReturn
    }

    private func shouldPopAutomaticStash(owner: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Apply stashed changes"
        alert.informativeText = "Apply the automatically stashed changes again?"
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Keep stash")
        let remember = NSButton(checkboxWithTitle: "Remember my answer", target: nil, action: nil)
        alert.accessoryView = remember
        let apply = await response(alert, owner: owner) == .alertFirstButtonReturn
        if remember.state == .on {
            var preferences = AppSettingsStore.shared.checkoutBranchPreferences
            preferences.autoPopStash = apply ? .always : .never
            AppSettingsStore.shared.saveCheckoutBranchPreferences(preferences)
        }
        return apply
    }

    private func shouldUpdateSubmodules(context: RepositoryBranchContext, owner: NSWindow) async -> Bool {
        guard !context.submodules.isEmpty else { return false }
        if let value = AppSettingsStore.shared.checkoutBranchPreferences.updateSubmodulesOnCheckout { return value }
        let alert = NSAlert()
        alert.messageText = "Update submodules"
        alert.informativeText = "Update and initialize submodules after checkout?"
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Not now")
        let remember = NSButton(checkboxWithTitle: "Remember my answer", target: nil, action: nil)
        alert.accessoryView = remember
        let update = await response(alert, owner: owner) == .alertFirstButtonReturn
        if remember.state == .on {
            var preferences = AppSettingsStore.shared.checkoutBranchPreferences
            preferences.updateSubmodulesOnCheckout = update
            AppSettingsStore.shared.saveCheckoutBranchPreferences(preferences)
        }
        return update
    }

    private func confirmLinkedWorktreeDeletion(
        _ candidates: [RepositoryBranchDeletionCandidate],
        owner: NSWindow
    ) async -> Bool {
        let detail = candidates.compactMap { candidate in
            candidate.worktreePath.map { "\(candidate.name): \($0)" }
        }.joined(separator: "\n")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete linked worktree and branch?"
        alert.informativeText = "The selected branch is checked out in another worktree. Delete that worktree and the branch?\n\n\(detail)"
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete Worktree and Branch")
        return await response(alert, owner: owner) == .alertSecondButtonReturn
    }

    private func confirmUnmergedBranchDeletion(_ names: [String], owner: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete unmerged branches?"
        alert.informativeText = "The selected branches have not been merged into HEAD. Proceed?\n\n\(names.joined(separator: "\n"))\n\nThe commits may still be recoverable from the reflog."
        alert.addButton(withTitle: "No")
        alert.addButton(withTitle: "Yes")
        let dontAsk = NSButton(checkboxWithTitle: "Do not ask again", target: nil, action: nil)
        alert.accessoryView = dontAsk
        let confirmed = await response(alert, owner: owner) == .alertSecondButtonReturn
        if confirmed, dontAsk.state == .on {
            var preferences = AppSettingsStore.shared.checkoutBranchPreferences
            preferences.dontConfirmDeleteUnmerged = true
            AppSettingsStore.shared.saveCheckoutBranchPreferences(preferences)
        }
        return confirmed
    }

    private func showError(_ error: Error, title: String, owner: NSWindow) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        _ = await response(alert, owner: owner)
    }

    private func showInformation(_ message: String, title: String, owner: NSWindow) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = await response(alert, owner: owner)
    }

    private func response(_ alert: NSAlert, owner: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: owner) { continuation.resume(returning: $0) }
        }
    }
}

enum CheckoutBranchFetchFollowUp {
    case none
    case checkout
    case create
    case merge
    case rebase
}
