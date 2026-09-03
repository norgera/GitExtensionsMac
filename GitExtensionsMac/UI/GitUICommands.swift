import GitExtensionsCore
import GitCommands
import AppKit

@MainActor
final class GitUICommands {
    private let repositoryModule: any RepositoryBrowsingDataSource
    private weak var browser: RepositoryBrowserViewController?
    let repositoryChangedNotifier: RepositoryChangedNotifier
    private var remoteWindowController: NSWindowController?

    init(
        repositoryModule: any RepositoryBrowsingDataSource,
        browser: RepositoryBrowserViewController
    ) {
        self.repositoryModule = repositoryModule
        self.browser = browser
        repositoryChangedNotifier = RepositoryChangedNotifier {}
    }

    func perform(
        changesRepositoryState: Bool,
        action: @MainActor () async throws -> Bool
    ) async throws -> Bool {
        repositoryChangedNotifier.lock()
        defer { repositoryChangedNotifier.unlock(requestNotify: false) }
        let succeeded = try await action()
        if succeeded && changesRepositoryState {
            repositoryChangedNotifier.notify()
        }
        return succeeded
    }

    func notifyRepositoryChanged(preferredCommitID: RevisionID? = nil) {
        browser?.prepareNotifierRefresh(preferredCommitID: preferredCommitID)
        repositoryChangedNotifier.notify()
    }

    func startDifftool(commit: Commit, file: ChangedFile) {
        guard let browser else { return }
        browser.statusLabel.stringValue = "Opening \(file.path) with the configured difftool…"
        Task { @MainActor [weak browser, repositoryModule] in
            do {
                let customTool = AppSettingsStore.shared.preferences.externalDiffToolPath
                try await repositoryModule.openWithDifftool(
                    for: commit,
                    file: file,
                    customToolPath: customTool.isEmpty ? nil : customTool
                )
                browser?.statusLabel.stringValue = "Opened \(file.path) with difftool."
            } catch {
                browser?.statusLabel.stringValue = "Difftool failed: \(error.localizedDescription)"
            }
        }
    }

    func startCommit(
        initialMode: RepositoryCommitMode = .normal,
        specialKind: CommitWorkflowSpecialKind? = nil
    ) {
        guard let browser,
              let identity = browser.repositoryIdentity,
              !identity.currentRepository.isBare,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryCommitWorkflowDataSource else {
            browser?.showPlaceholderStatus("Commit is unavailable for mock data")
            return
        }

        if let existing = browser.commitWindowController {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let head = browser.revisions.first(where: \.isHEAD)
            ?? browser.revisions.first(where: { !$0.isArtificial })
        browser.commitWindowController = browser.presentCommitDialog(
            source: source,
            pushSource: repositoryModule as? any RepositoryPushingDataSource,
            initialMode: initialMode,
            specialKind: specialKind,
            head: head,
            draft: browser.commitDraft,
            owner: window,
            previousSelection: browser.selectedCommitID
        )
    }

    func startPull(action: PullActionPreference, immediately: Bool) {
        guard let browser, let context = browser.networkContext else { return }
        let effectiveAction = action == .openDialog ? AppSettingsStore.shared.pullPreferences.formAction : action
        let initialAction: NetworkDialogInitialAction = switch effectiveAction {
        case .rebase: .rebase
        case .fetch: .fetch
        case .fetchAll: .fetchAll
        case .fetchPruneAll: .fetchPruneAll
        case .merge, .openDialog: .merge
        }
        let isFetch = initialAction == .fetch || initialAction == .fetchAll || initialAction == .fetchPruneAll
        if let existing = browser.pullWindowController ?? browser.fetchWindowController {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard browser.view.window != nil,
              let source = repositoryModule as? any RepositoryPullingDataSource else { return }
        let controller = ApplicationShellDialogs.presentPullWindow(
            initialAction: initialAction,
            executeImmediately: immediately,
            context: context,
            source: source,
            onManageRemotes: { [weak self] remote, localBranch in
                self?.startRemoteManagement(selectedRemote: remote, selectedLocalBranch: localBranch)
            },
            onRepositoryChanged: { [weak self, weak browser] selected in
                self?.notifyRepositoryChanged(preferredCommitID: selected ?? browser?.selectedCommitID)
            },
            onClose: { [weak browser] in
                browser?.pullWindowController = nil
                browser?.fetchWindowController = nil
            }
        )
        if isFetch {
            browser.fetchWindowController = controller
        } else {
            browser.pullWindowController = controller
        }
    }

    func startFetchAll(prune: Bool) {
        startPull(action: prune ? .fetchPruneAll : .fetchAll, immediately: true)
    }

    func fetchRemote(named remote: String, prune: Bool) {
        guard let browser,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryPullingDataSource else { return }
        Task { @MainActor [weak self, weak browser, weak window] in
            guard let self, let browser, let window else { return }
            let processResult = await PullProcessDialog.run(
                request: RepositoryPullRequest(source: .remote(remote), mode: .fetch, prune: prune),
                source: source,
                parent: window
            )
            switch processResult {
            case .success(let result):
                notifyRepositoryChanged(preferredCommitID: result.selectedCommitID ?? browser.selectedCommitID)
                browser.statusLabel.stringValue = result.message
            case .failure(let error):
                browser.statusLabel.stringValue = error.localizedDescription
            case nil:
                break
            }
        }
    }

    func setRemote(named remote: String, disabled: Bool, fetchAfterEnabling: Bool) {
        guard let browser,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryRemoteManagingDataSource else { return }
        Task { @MainActor [weak self, weak browser, weak window] in
            guard let self, let browser, let window else { return }
            do {
                try await source.setRemote(named: remote, disabled: disabled)
                if fetchAfterEnabling,
                   let pullSource = repositoryModule as? any RepositoryPullingDataSource {
                    let result = await PullProcessDialog.run(
                        request: RepositoryPullRequest(source: .remote(remote), mode: .fetch),
                        source: pullSource,
                        parent: window
                    )
                    if case .success(let fetched) = result {
                        browser.statusLabel.stringValue = fetched.message
                    } else if case .failure(let error) = result {
                        browser.statusLabel.stringValue = error.localizedDescription
                    }
                }
                notifyRepositoryChanged(preferredCommitID: browser.selectedCommitID)
            } catch {
                browser.statusLabel.stringValue = error.localizedDescription
            }
        }
    }

    func startRemoteManagement(selectedRemote: String? = nil, selectedLocalBranch: String? = nil) {
        if let remoteWindowController {
            RemoteManagementDialog.focus(
                remoteWindowController,
                selectedRemote: selectedRemote,
                selectedLocalBranch: selectedLocalBranch
            )
            return
        }
        guard let browser,
              let source = repositoryModule as? any RepositoryRemoteManagingDataSource else {
            browser?.showPlaceholderStatus("Remote management is unavailable for this data source.")
            return
        }

        remoteWindowController = RemoteManagementDialog.present(
            source: source,
            selectedRemote: selectedRemote,
            selectedLocalBranch: selectedLocalBranch,
            onFetchRemote: { [weak self] remote, window in
                await self?.fetchAfterSavingRemote(named: remote, parent: window)
            },
            onRepositoryChanged: { [weak self, weak browser] in
                self?.notifyRepositoryChanged(preferredCommitID: browser?.selectedCommitID)
            },
            onClose: { [weak self] in
                self?.remoteWindowController = nil
            }
        )
    }

    private func fetchAfterSavingRemote(named remote: String, parent: NSWindow) async {
        guard let source = repositoryModule as? any RepositoryPullingDataSource else { return }
        let request = RepositoryPullRequest(source: .remote(remote), mode: .fetch)
        guard let processResult = await PullProcessDialog.run(
            request: request,
            source: source,
            parent: parent
        ) else { return }
        switch processResult {
        case .success(let result):
            browser?.statusLabel.stringValue = result.message
        case .failure(let error):
            browser?.statusLabel.stringValue = error.localizedDescription
        }
    }

    func startPush(
        immediately: Bool = false,
        initialBranch: String? = nil,
        forceWithLease: Bool = false
    ) {
        guard let browser,
              let context = browser.networkContext,
              browser.view.window != nil,
              let source = repositoryModule as? any RepositoryPushingDataSource else { return }

        if let existing = browser.pushWindowController {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        browser.pushWindowController = PushDialog.present(
            source: source,
            context: context,
            initialBranch: initialBranch,
            executeImmediately: immediately,
            initialForceWithLease: forceWithLease,
            onManageRemotes: { [weak self] remote, localBranch in
                self?.startRemoteManagement(selectedRemote: remote, selectedLocalBranch: localBranch)
            },
            onRepositoryChanged: { [weak self, weak browser] preferredCommitID in
                self?.notifyRepositoryChanged(preferredCommitID: preferredCommitID ?? browser?.selectedCommitID)
            },
            onClose: { [weak browser] in
                browser?.pushWindowController = nil
            }
        )
    }

    func startMergeBranches(initialTarget: String?) {
        guard let browser,
              let context = browser.mergeContext,
              !context.repository.isBare else {
            browser?.showPlaceholderStatus("Merge is unavailable for this repository")
            return
        }
        if let existing = browser.mergeWindowController {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let window = browser.view.window,
              let source = repositoryModule as? any RepositoryMergingDataSource else { return }
        browser.mergeWindowController = browser.presentMergeDialog(
            source: source,
            context: context,
            initialTarget: initialTarget,
            previousSelection: browser.selectedCommitID,
            owner: window
        )
    }

    func startCherryPick(_ selectedCommits: [Commit]) {
        guard let browser,
              browser.repositoryIdentity != nil,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryCherryPickDataSource else {
            browser?.showPlaceholderStatus("Cherry-pick is unavailable for mock data")
            return
        }

        let historyIndex = Dictionary(uniqueKeysWithValues: browser.revisions.enumerated().map { ($0.element.id, $0.offset) })
        let ordered = selectedCommits
            .filter { !$0.isArtificial }
            .sorted { (historyIndex[$0.id] ?? 0) > (historyIndex[$1.id] ?? 0) }
        guard !ordered.isEmpty else { return }

        browser.startCherryPickWorkflow(
            orderedRevisions: ordered,
            history: browser.revisions,
            mutationSource: source,
            window: window,
            previousSelection: browser.selectedCommitID
        )
    }

    func startRevert(_ selectedCommits: [Commit]) {
        guard let browser,
              browser.repositoryIdentity?.currentRepository.isBare == false,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryRevertingDataSource else {
            browser?.showPlaceholderStatus("Revert is unavailable for this repository")
            return
        }

        let history = browser.revisions
        let ordered = RevertWorkflowOrdering.ordered(selectedCommits, in: history)
        guard !ordered.isEmpty else { return }
        let previousSelection = browser.selectedCommitID

        Task { @MainActor [weak self, weak browser, weak window] in
            guard let self, let browser, let window else { return }
            var completedCount = 0
            var preferredCommitID = previousSelection

            for commit in ordered {
                guard let commitID = commit.objectID else { continue }
                guard let selection = await RevertDialog.present(
                    commit: commit,
                    history: history,
                    owner: window
                ) else {
                    browser.statusLabel.stringValue = completedCount == 0
                        ? "Revert cancelled."
                        : "Reverted \(completedCount) commit(s); remaining revisions were cancelled."
                    return
                }

                do {
                    browser.statusLabel.stringValue = "Reverting \(commit.shortID)…"
                    let result = try await source.revert(RepositoryRevertRequest(
                        commitID: commitID,
                        automaticallyCommit: selection.automaticallyCommit,
                        mainlineParent: selection.mainlineParent
                    ))
                    preferredCommitID = result.selectedCommitID ?? preferredCommitID
                    notifyRepositoryChanged(preferredCommitID: preferredCommitID)

                    switch result.outcome {
                    case .completed:
                        completedCount += 1
                        browser.statusLabel.stringValue = result.message
                    case .conflicts(let paths):
                        browser.statusLabel.stringValue = result.message
                        guard await MutationDialogs.confirmResolveRevertConflicts(paths: paths, window: window) else {
                            return
                        }
                        let resolution = await WorkflowManagementDialogs.resolveRevertConflicts(
                            source: source,
                            window: window
                        )
                        if resolution.repositoryChanged {
                            notifyRepositoryChanged(preferredCommitID: preferredCommitID)
                        }
                        switch resolution.sequencerAction {
                        case .continued:
                            completedCount += 1
                            browser.statusLabel.stringValue = "Revert continued."
                        case .aborted:
                            browser.statusLabel.stringValue = completedCount == 0
                                ? "Revert aborted."
                                : "Revert aborted after \(completedCount) completed commit(s)."
                            return
                        case .none:
                            browser.statusLabel.stringValue = "Revert remains paused. Resolve all conflicts, then Continue or Abort."
                            return
                        }
                    case .paused(let reason):
                        browser.statusLabel.stringValue = reason
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    browser.statusLabel.stringValue = error.localizedDescription
                    await MutationDialogs.showError(error, title: "Revert failed", window: window)
                    return
                }
            }
        }
    }

    func startBisect(_ selectedCommits: [Commit]) {
        guard let browser,
              browser.repositoryIdentity?.currentRepository.isBare == false,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryBisectingDataSource else {
            browser?.showPlaceholderStatus("Bisect is unavailable for this repository")
            return
        }
        let revisions = selectedCommits.filter { !$0.isArtificial && $0.objectID != nil }
        guard !revisions.isEmpty else { return }
        Task { @MainActor [weak self, weak browser, weak window] in
            guard let self, let browser, let window else { return }
            let result = await BisectDialog.present(
                source: source,
                selectedRevisions: revisions,
                owner: window,
                statusChanged: { [weak browser] in browser?.statusLabel.stringValue = $0 }
            )
            if result.repositoryChanged {
                notifyRepositoryChanged(
                    preferredCommitID: result.preferredCommitID ?? browser.selectedCommitID
                )
            }
        }
    }

    func markBisect(_ mark: RepositoryBisectMark, revision: Commit) {
        guard let browser,
              let window = browser.view.window,
              let objectID = revision.objectID,
              let source = repositoryModule as? any RepositoryBisectingDataSource else { return }
        Task { @MainActor [weak self, weak browser, weak window] in
            guard let self, let browser, let window else { return }
            do {
                let result = try await source.markBisect(mark, revisions: [objectID])
                notifyRepositoryChanged(preferredCommitID: result.selectedCommitID ?? browser.selectedCommitID)
                browser.statusLabel.stringValue = result.message
            } catch is CancellationError {
                return
            } catch {
                browser.statusLabel.stringValue = error.localizedDescription
                await MutationDialogs.showError(error, title: "Bisect failed", window: window)
            }
        }
    }

    func stopBisect() {
        guard let browser,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryBisectingDataSource else { return }
        Task { @MainActor [weak self, weak browser, weak window] in
            guard let self, let browser, let window else { return }
            do {
                let result = try await source.resetBisect()
                notifyRepositoryChanged(preferredCommitID: result.selectedCommitID ?? browser.selectedCommitID)
                browser.statusLabel.stringValue = result.message
            } catch is CancellationError {
                return
            } catch {
                browser.statusLabel.stringValue = error.localizedDescription
                await MutationDialogs.showError(error, title: "Stop bisect failed", window: window)
            }
        }
    }

    func startRebase(on target: Commit, interactive: Bool, showAdvancedOptions: Bool) {
        startRebase(
            on: target,
            interactive: interactive,
            initialActions: [:],
            advancedFrom: nil,
            showAdvancedOptions: showAdvancedOptions
        )
    }

    func startRebase(
        on target: Commit,
        interactive: Bool,
        initialActions: [ObjectID: RepositoryRebaseTodoAction] = [:],
        advancedFrom: String? = nil,
        showAdvancedOptions: Bool = false
    ) {
        guard let browser,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryRebaseDataSource else {
            browser?.showPlaceholderStatus("Rebase is unavailable for mock data")
            return
        }
        browser.startRebaseWorkflow(
            on: target,
            interactive: interactive,
            initialActions: initialActions,
            advancedFrom: advancedFrom,
            showAdvancedOptions: showAdvancedOptions,
            mutationSource: source,
            window: window,
            previousSelection: browser.selectedCommitID
        )
    }

    func startCheckoutBranch(initialTarget: CheckoutDialogTarget?, confirmDirectCheckout: Bool = false) {
        makeCheckoutWorkflowCoordinator()?.checkoutBranch(
            initialTarget: initialTarget,
            confirmDirectCheckout: confirmDirectCheckout
        )
    }

    func startCheckoutRevision(_ commit: Commit) {
        makeCheckoutWorkflowCoordinator()?.checkoutRevision(commit)
    }

    func startResetCurrentBranch(to target: Commit) {
        guard let browser,
              let owner = browser.view.window,
              let identity = browser.repositoryIdentity,
              !identity.currentRepository.isBare,
              let targetID = target.objectID,
              let source = repositoryModule as? any RepositoryResettingDataSource else {
            browser?.showPlaceholderStatus("Reset is unavailable for this repository")
            return
        }
        let currentBranch = browser.repositoryReferences?.branches.first(where: \.isCurrent)?.name
        Task { @MainActor [weak self, weak browser, weak owner] in
            guard let self, let browser, let owner else { return }
            guard let mode = await ResetDialogs.resetCurrentBranch(
                branchName: currentBranch,
                target: target,
                owner: owner
            ) else {
                browser.statusLabel.stringValue = "Reset cancelled"
                return
            }
            await Task.yield()
            if mode == .hard, !(await ResetDialogs.confirmHardReset(owner: owner)) {
                browser.statusLabel.stringValue = "Reset cancelled"
                return
            }
            do {
                let hasChangedTarget = identity.headID != targetID
                let hasSubmodules = !(browser.repositoryNavigation?.submodules.isEmpty ?? true)
                let updateSubmodules: Bool
                if hasChangedTarget, hasSubmodules {
                    if let preference = AppSettingsStore.shared.checkoutBranchPreferences.updateSubmodulesOnCheckout {
                        updateSubmodules = preference
                    } else if mode == .hard {
                        updateSubmodules = await ResetDialogs.confirmUpdateSubmodules(owner: owner)
                    } else {
                        updateSubmodules = false
                    }
                } else {
                    updateSubmodules = false
                }
                let result = try await source.resetCurrentBranch(RepositoryResetCurrentBranchRequest(
                    target: targetID,
                    mode: mode,
                    updateSubmodules: updateSubmodules
                ))
                notifyRepositoryChanged(preferredCommitID: result.selectedCommitID)
                browser.statusLabel.stringValue = result.message
                if case .completedWithSubmoduleUpdateFailure(let detail) = result.outcome {
                    await ResetDialogs.showError(
                        RepositoryResetFollowUpError(detail: detail),
                        title: "Reset completed; submodule update failed",
                        owner: owner
                    )
                }
            } catch {
                await ResetDialogs.showError(error, title: "Reset failed", owner: owner)
            }
        }
    }

    func startResetCurrentBranch(to targetID: ObjectID, label: String) {
        guard let browser else { return }
        let target = browser.revisions.first(where: { $0.objectID == targetID })
            ?? RevisionCommitBuilder.placeholderRevision(id: targetID, subject: label)
        startResetCurrentBranch(to: target)
    }

    func startResetAnotherBranch(to target: Commit) {
        guard let browser,
              let owner = browser.view.window,
              let identity = browser.repositoryIdentity,
              !identity.currentRepository.isBare,
              let targetID = target.objectID,
              let references = browser.repositoryReferences,
              let source = repositoryModule as? any RepositoryResettingDataSource else {
            browser?.showPlaceholderStatus("Reset is unavailable for this repository")
            return
        }
        let currentBranch = references.branches.first(where: \.isCurrent)?.name
        Task { @MainActor [weak self, weak browser, weak owner] in
            guard let self, let browser, let owner else { return }
            guard let value = await ResetDialogs.resetAnotherBranch(
                source: source,
                branches: references.branches,
                localReferences: references.references,
                currentBranchName: currentBranch,
                target: target,
                owner: owner
            ) else {
                browser.statusLabel.stringValue = "Reset cancelled"
                return
            }
            do {
                let result = try await source.resetAnotherBranch(RepositoryResetAnotherBranchRequest(
                    branch: value.branch.name,
                    target: targetID,
                    force: value.force
                ))
                notifyRepositoryChanged(preferredCommitID: result.selectedCommitID)
                browser.statusLabel.stringValue = result.message
                if value.checkoutAfterReset {
                    startCheckoutBranch(initialTarget: .local(value.branch))
                }
            } catch {
                await ResetDialogs.showError(error, title: "Reset branch failed", owner: owner)
            }
        }
    }

    func startResetChanges() {
        guard let browser,
              let owner = browser.view.window,
              let identity = browser.repositoryIdentity,
              !identity.currentRepository.isBare,
              let source = repositoryModule as? any RepositoryResettingDataSource else {
            browser?.showPlaceholderStatus("Reset changes is unavailable for this repository")
            return
        }
        Task { @MainActor [weak self, weak browser, weak owner] in
            guard let self, let browser, let owner else { return }
            do {
                let state = try await source.loadMutationState()
                let hasTracked = state.hasStagedChanges || state.hasUnstagedChanges || !state.conflictedPaths.isEmpty
                guard hasTracked || state.hasUntrackedFiles else {
                    browser.statusLabel.stringValue = "There are no changes to reset."
                    return
                }
                guard let deleteUntracked = await ResetDialogs.confirmResetChanges(
                    hasTrackedChanges: hasTracked,
                    hasUntrackedFiles: state.hasUntrackedFiles,
                    owner: owner
                ) else {
                    browser.statusLabel.stringValue = "Reset cancelled"
                    return
                }
                let result = try await source.resetChanges(RepositoryResetChangesRequest(
                    scope: .all,
                    deleteUntracked: deleteUntracked
                ))
                notifyRepositoryChanged(preferredCommitID: result.selectedCommitID)
                browser.statusLabel.stringValue = result.message
            } catch {
                await ResetDialogs.showError(error, title: "Reset changes failed", owner: owner)
            }
        }
    }

    func startCleanRepository(initialPath: String? = nil) {
        guard let browser,
              let owner = browser.view.window,
              let identity = browser.repositoryIdentity,
              !identity.currentRepository.isBare,
              let source = repositoryModule as? any RepositoryCleaningDataSource else {
            browser?.showPlaceholderStatus("Clean is unavailable for this repository")
            return
        }
        CleanDialog.present(
            source: source,
            repositoryURL: URL(fileURLWithPath: identity.currentRepository.path, isDirectory: true),
            initialPath: initialPath,
            owner: owner,
            repositoryChanged: { [weak self] in
                self?.notifyRepositoryChanged(preferredCommitID: .workingDirectory)
            },
            statusChanged: { [weak browser] status in
                browser?.statusLabel.stringValue = status
            }
        )
    }

    func checkout(_ target: CheckoutDialogTarget, confirmDirectCheckout: Bool = false) {
        makeCheckoutWorkflowCoordinator()?.checkout(
            target,
            confirmDirectCheckout: confirmDirectCheckout
        )
    }

    func fetchRemoteBranch(
        _ branch: Branch,
        then followUp: CheckoutBranchFetchFollowUp
    ) {
        makeCheckoutWorkflowCoordinator()?.fetchRemoteBranch(branch, then: followUp)
    }

    func createBranch(sourceRevision: Commit?, suggestedPrefix: String? = nil) {
        makeCheckoutWorkflowCoordinator()?.createBranch(
            sourceRevision: sourceRevision,
            suggestedPrefix: suggestedPrefix
        )
    }

    func deleteBranches(initiallySelected: [String]) {
        makeCheckoutWorkflowCoordinator()?.deleteBranches(initiallySelected: initiallySelected)
    }

    func renameBranch(_ name: String) {
        makeCheckoutWorkflowCoordinator()?.renameBranch(name)
    }

    func startCreateTag(initialTarget: ObjectID? = nil) {
        guard let browser,
              let window = browser.view.window,
              let identity = browser.repositoryIdentity,
              let source = repositoryModule as? any RepositoryTagManagingDataSource else {
            browser?.showPlaceholderStatus("Tag creation is unavailable for this data source")
            return
        }
        let remote = preferredTagRemote(browser: browser)
        let defaultTarget = initialTarget ?? identity.headID
        var initial = CreateTagDialogValue(target: defaultTarget?.string ?? "")
        Task { @MainActor [weak self, weak browser, weak window] in
            guard let self, let browser, let window else { return }
            while let value = await TagDialogs.createTag(
                initial: initial,
                revisions: browser.revisions,
                remote: remote,
                window: window
            ) {
                initial = value
                do {
                    let target = try await source.resolveTagTarget(value.target)
                    let result = try await source.createTag(RepositoryCreateTagRequest(
                        name: value.name,
                        target: target,
                        operation: value.operation,
                        message: value.message,
                        signingKey: value.signingKey,
                        force: value.force
                    ))
                    if value.pushToRemote, let remote,
                       let pushSource = repositoryModule as? any RepositoryPushingDataSource {
                        let processResult = await PushProcessDialog.run(
                            request: RepositoryPushRequest(destination: .remote(remote), operation: .tag(value.name)),
                            source: pushSource,
                            parent: window
                        )
                        self.notifyRepositoryChanged(preferredCommitID: result.selectedCommitID)
                        if case .success(let pushed)? = processResult {
                            browser.statusLabel.stringValue = pushed.message
                        } else if case .failure(let error)? = processResult {
                            await TagDialogs.showError(
                                error,
                                title: "Push tag failed",
                                window: window
                            )
                        }
                    } else {
                        self.notifyRepositoryChanged(preferredCommitID: result.selectedCommitID)
                        browser.statusLabel.stringValue = result.message
                    }
                    return
                } catch {
                    await TagDialogs.showError(error, title: "Create tag failed", window: window)
                }
            }
        }
    }

    func startDeleteTag(initialName: String? = nil) {
        guard let browser,
              let window = browser.view.window,
              let references = browser.repositoryReferences,
              let navigation = browser.repositoryNavigation,
              let source = repositoryModule as? any RepositoryTagManagingDataSource else {
            browser?.showPlaceholderStatus("Tag deletion is unavailable for this data source")
            return
        }
        guard !references.tags.isEmpty else {
            browser.showPlaceholderStatus("There are no tags to delete")
            return
        }
        let activeRemotes = navigation.remotes.filter { !$0.isDisabled }
        let preferredRemote = preferredTagRemote(browser: browser) ?? activeRemotes.first?.name ?? ""
        var initial = DeleteTagDialogValue(
            name: initialName ?? references.tags.first?.name ?? "",
            remote: preferredRemote
        )
        Task { @MainActor [weak self, weak browser, weak window] in
            guard let self, let browser, let window else { return }
            while let value = await TagDialogs.deleteTag(
                initial: initial,
                tags: references.tags,
                remotes: activeRemotes,
                window: window
            ) {
                initial = value
                do {
                    let result = try await source.deleteTag(named: value.name)
                    if value.deleteFromRemote,
                       !value.remote.isEmpty,
                       let pushSource = repositoryModule as? any RepositoryPushingDataSource {
                        let processResult = await PushProcessDialog.run(
                            request: RepositoryPushRequest(
                                destination: .remote(value.remote),
                                operation: .deleteTag(value.name)
                            ),
                            source: pushSource,
                            parent: window
                        )
                        self.notifyRepositoryChanged(preferredCommitID: browser.selectedCommitID)
                        if case .success(let pushed)? = processResult {
                            browser.statusLabel.stringValue = pushed.message
                        } else if case .failure(let error)? = processResult {
                            await TagDialogs.showError(
                                error,
                                title: "Delete remote tag failed",
                                window: window
                            )
                        }
                    } else {
                        self.notifyRepositoryChanged(preferredCommitID: browser.selectedCommitID)
                        browser.statusLabel.stringValue = result.message
                    }
                    return
                } catch {
                    await TagDialogs.showError(error, title: "Delete tag failed", window: window)
                }
            }
        }
    }

    private func preferredTagRemote(browser: RepositoryBrowserViewController) -> String? {
        guard let references = browser.repositoryReferences,
              let navigation = browser.repositoryNavigation else { return nil }
        let activeRemotes = navigation.remotes.filter { !$0.isDisabled }
        if let current = references.branches.first(where: \.isCurrent),
           let remote = current.remoteName,
           activeRemotes.contains(where: { $0.name == remote }) {
            return remote
        }
        if activeRemotes.contains(where: { $0.name == "origin" }) { return "origin" }
        return activeRemotes.first?.name
    }

    private func makeCheckoutWorkflowCoordinator() -> CheckoutBranchWorkflowCoordinator? {
        guard let browser,
              let context = browser.branchContext,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryCheckoutBranchDataSource else {
            return nil
        }
        let coordinator = CheckoutBranchWorkflowCoordinator(
            source: source,
            stashSource: repositoryModule as? any RepositoryStashDataSource,
            pullSource: repositoryModule as? any RepositoryPullingDataSource,
            context: context,
            revisions: browser.revisions,
            owner: window,
            onRepositoryChanged: { [weak self, weak browser] selectedCommitID in
                self?.notifyRepositoryChanged(preferredCommitID: selectedCommitID ?? browser?.selectedCommitID)
            },
            onStatus: { [weak browser] message in
                browser?.statusLabel.stringValue = message
            },
            onConflicts: { [weak self] in
                self?.startConflictResolution()
            },
            onMerge: { [weak self] target in
                self?.startMergeBranches(initialTarget: target)
            },
            onRebase: { [weak self] commit in
                self?.startRebase(on: commit, interactive: false)
            }
        )
        browser.checkoutBranchWorkflowCoordinator = coordinator
        return coordinator
    }

    func startConflictResolution(offerCommit: Bool = true) {
        guard let browser,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryConflictResolutionDataSource else {
            browser?.showPlaceholderStatus("Conflict resolver is unavailable for mock data")
            return
        }

        Task { @MainActor [weak browser] in
            guard let browser else { return }
            let refreshed = await WorkflowManagementDialogs.resolveConflicts(
                source: source,
                window: window,
                offerCommit: offerCommit
            )
            if refreshed {
                self.notifyRepositoryChanged(preferredCommitID: browser.selectedCommitID)
            }
        }
    }

    func startStashManagement(manageStashes: Bool = true, initialStash: String? = nil) {
        guard let browser,
              let context = browser.stashContext,
              let window = browser.view.window,
              let source = repositoryModule as? any RepositoryStashWorkflowDataSource else {
            browser?.showPlaceholderStatus("Stash manager is unavailable for mock data")
            return
        }

        Task { @MainActor [weak browser] in
            guard let browser else { return }
            let result = await WorkflowManagementDialogs.manageStashes(
                source: source,
                context: context,
                window: window,
                manageStashes: manageStashes,
                initialStash: initialStash,
                openWithDifftool: { [weak self] commit, file in
                    self?.startDifftool(commit: commit, file: file)
                }
            )
            if result.repositoryChanged {
                self.notifyRepositoryChanged(
                    preferredCommitID: result.selectedCommitID ?? browser.selectedCommitID
                )
            }
        }
    }

}
