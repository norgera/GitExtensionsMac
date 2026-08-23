import AppKit

enum CheckoutDialogTarget {
    case local(Branch)
    case remote(Branch)
    case revision(Commit)
}

struct CommitDialogDraft {
    let request: RepositoryCommitRequest
}

@MainActor
private final class RebaseOptionCoordinator: NSObject {
    let ignoreDate: NSButton
    let committerDate: NSButton
    let rebaseMerges: NSButton
    let specificRange: NSButton
    let from: NSTextField
    let branch: NSTextField

    init(ignoreDate: NSButton, committerDate: NSButton, rebaseMerges: NSButton, specificRange: NSButton, from: NSTextField, branch: NSTextField) {
        self.ignoreDate = ignoreDate; self.committerDate = committerDate; self.rebaseMerges = rebaseMerges
        self.specificRange = specificRange; self.from = from; self.branch = branch
        super.init()
        ignoreDate.target = self; ignoreDate.action = #selector(changed)
        committerDate.target = self; committerDate.action = #selector(changed)
        specificRange.target = self; specificRange.action = #selector(changed)
        changed()
    }

    @objc private func changed() {
        committerDate.isEnabled = ignoreDate.state != .on
        ignoreDate.isEnabled = committerDate.state != .on
        rebaseMerges.isEnabled = ignoreDate.state != .on && committerDate.state != .on
        let enabled = specificRange.state == .on
        from.isEnabled = enabled; branch.isEnabled = enabled
    }
}

@MainActor
enum MutationDialogs {
    static func checkoutRequest(
        target: CheckoutDialogTarget,
        state: RepositoryMutationState,
        localBranches: [Branch],
        window: NSWindow
    ) async -> RepositoryCheckoutRequest? {
        if case .local(let branch) = target, !state.isDirty {
            return RepositoryCheckoutRequest(target: .localBranch(branch.name), localChanges: .keep)
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Checkout")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false

        let targetName: String
        switch target {
        case .local(let branch):
            targetName = branch.name
            alert.messageText = "Checkout branch"
        case .remote(let branch):
            targetName = "\(branch.remoteName ?? "origin")/\(branch.name)"
            alert.messageText = "Checkout remote branch"
        case .revision(let commit):
            targetName = "\(commit.shortID): \(commit.subject)"
            alert.messageText = "Checkout revision"
            alert.informativeText = "HEAD will be detached at this revision."
        }
        stack.addArrangedSubview(label("Target: \(targetName)"))

        var remoteMode: NSPopUpButton?
        var localName: NSTextField?
        if case .remote(let branch) = target {
            let mode = NSPopUpButton()
            mode.addItems(withTitles: ["Create tracking local branch", "Checkout detached"])
            if localBranches.contains(where: { $0.name == branch.name }) {
                mode.insertItem(withTitle: "Reset existing local branch", at: 1)
            }
            mode.controlSize = .small
            stack.addArrangedSubview(labeledControl("Remote checkout:", mode))
            remoteMode = mode

            let field = NSTextField(string: branch.name)
            field.controlSize = .small
            field.placeholderString = "Local branch name"
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
            stack.addArrangedSubview(labeledControl("Local branch:", field))
            localName = field
        }

        var changesMode: NSPopUpButton?
        let includeUntracked = checkbox("Include untracked files in automatic stash", state: true)
        let reapplyStash = checkbox("Reapply the automatic stash after checkout", state: true)
        if state.isDirty {
            let mode = NSPopUpButton()
            mode.addItems(withTitles: [
                "Don’t change local modifications",
                "Merge local modifications",
                "Stash local modifications",
                "Discard local modifications (force)"
            ])
            mode.controlSize = .small
            stack.addArrangedSubview(labeledControl("Local changes:", mode))
            stack.addArrangedSubview(includeUntracked)
            stack.addArrangedSubview(reapplyStash)
            changesMode = mode
            if alert.informativeText.isEmpty {
                alert.informativeText = "The working directory contains local changes."
            }
        }

        let accessory = NSView()
        accessory.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            stack.topAnchor.constraint(equalTo: accessory.topAnchor),
            stack.bottomAnchor.constraint(equalTo: accessory.bottomAnchor),
            accessory.widthAnchor.constraint(greaterThanOrEqualToConstant: 390)
        ])
        alert.accessoryView = accessory

        let response = await begin(alert: alert, for: window)
        guard response == .alertFirstButtonReturn else { return nil }

        let localChanges: CheckoutLocalChangesAction
        switch changesMode?.indexOfSelectedItem ?? 0 {
        case 1: localChanges = .merge
        case 2: localChanges = .stash(includeUntracked: includeUntracked.state == .on, reapply: reapplyStash.state == .on)
        case 3: localChanges = .force
        default: localChanges = .keep
        }

        let checkoutTarget: RepositoryCheckoutTarget
        switch target {
        case .local(let branch):
            checkoutTarget = .localBranch(branch.name)
        case .revision(let commit):
            checkoutTarget = .revision(commit.id)
        case .remote(let branch):
            let remote = branch.remoteName ?? "origin"
            let modeTitle = remoteMode?.titleOfSelectedItem ?? "Create tracking local branch"
            if modeTitle == "Checkout detached" {
                checkoutTarget = .remoteBranch(remote: remote, branch: branch.name, mode: .detached)
            } else if modeTitle == "Reset existing local branch" {
                checkoutTarget = .remoteBranch(remote: remote, branch: branch.name, mode: .resetTracking(localBranch: localName?.stringValue ?? branch.name))
            } else {
                checkoutTarget = .remoteBranch(remote: remote, branch: branch.name, mode: .createTracking(localBranch: localName?.stringValue ?? branch.name))
            }
        }
        return RepositoryCheckoutRequest(target: checkoutTarget, localChanges: localChanges)
    }

    static func showError(_ error: Error, title: String, window: NSWindow) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        _ = await begin(alert: alert, for: window)
    }

    static func showInformation(_ message: String, title: String, window: NSWindow) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        _ = await begin(alert: alert, for: window)
    }

    static func commitRequest(
        initialMode: RepositoryCommitMode,
        state: RepositoryMutationState,
        head: Commit?,
        draft: CommitDialogDraft?,
        window: NSWindow
    ) async -> RepositoryCommitRequest? {
        let alert = NSAlert()
        alert.messageText = initialMode == .normal ? "Commit" : "Amend commit"
        alert.alertStyle = initialMode == .normal ? .informational : .warning
        alert.addButton(withTitle: initialMode == .normal ? "Commit" : "Amend")
        alert.addButton(withTitle: "Cancel")
        if state.currentBranch == nil {
            alert.informativeText = "HEAD is detached. The new commit will not belong to a branch unless you create or checkout one later."
        } else if initialMode != .normal {
            alert.informativeText = "Amending rewrites the current commit. Do not amend a commit that has already been published."
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false

        let mode = NSPopUpButton()
        mode.addItems(withTitles: ["Normal commit", "Amend", "Amend message only"])
        let initialIndex: Int = switch draft?.request.mode ?? initialMode {
        case .normal: 0
        case .amend: 1
        case .amendMessageOnly: 2
        }
        mode.selectItem(at: initialIndex)
        mode.controlSize = .small
        stack.addArrangedSubview(labeledControl("Mode:", mode))

        let messageView = NSTextView()
        messageView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        messageView.isRichText = false
        messageView.isAutomaticQuoteSubstitutionEnabled = false
        messageView.isAutomaticDashSubstitutionEnabled = false
        messageView.string = draft?.request.message ?? (initialMode == .normal ? "" : commitMessage(head))
        let messageScroll = NSScrollView()
        messageScroll.documentView = messageView
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .bezelBorder
        messageScroll.translatesAutoresizingMaskIntoConstraints = false
        messageScroll.widthAnchor.constraint(equalToConstant: 500).isActive = true
        messageScroll.heightAnchor.constraint(equalToConstant: 155).isActive = true
        stack.addArrangedSubview(label("Commit message:"))
        stack.addArrangedSubview(messageScroll)

        let stageAll = checkbox("Stage all unstaged and untracked changes before committing", state: draft?.request.stageAllBeforeCommit ?? false)
        let allowEmpty = checkbox("Allow empty commit", state: draft?.request.allowEmpty ?? false)
        let signOff = checkbox("Sign off", state: draft?.request.signOff ?? false)
        let resetAuthor = checkbox("Reset author while amending", state: draft?.request.resetAuthor ?? false)
        stack.addArrangedSubview(stageAll)
        stack.addArrangedSubview(allowEmpty)
        stack.addArrangedSubview(signOff)
        stack.addArrangedSubview(resetAuthor)

        let author = NSTextField(string: draft?.request.author ?? "")
        author.placeholderString = "Name <email@example.com>"
        author.controlSize = .small
        author.widthAnchor.constraint(equalToConstant: 315).isActive = true
        stack.addArrangedSubview(labeledControl("Author:", author))

        let stagedSummary = state.hasStagedChanges ? "Staged changes are ready to commit." : "No changes are currently staged."
        let summary = label(stagedSummary)
        summary.textColor = state.hasStagedChanges ? .secondaryLabelColor : .systemOrange
        stack.addArrangedSubview(summary)

        let accessory = NSView()
        accessory.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            stack.topAnchor.constraint(equalTo: accessory.topAnchor),
            stack.bottomAnchor.constraint(equalTo: accessory.bottomAnchor)
        ])
        alert.accessoryView = accessory
        window.makeFirstResponder(messageView)

        let response = await begin(alert: alert, for: window)
        guard response == .alertFirstButtonReturn else { return nil }
        let commitMode: RepositoryCommitMode = switch mode.indexOfSelectedItem {
        case 1: .amend
        case 2: .amendMessageOnly
        default: .normal
        }
        let authorText = author.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return RepositoryCommitRequest(
            message: messageView.string,
            mode: commitMode,
            stageAllBeforeCommit: stageAll.state == .on,
            allowEmpty: allowEmpty.state == .on,
            signOff: signOff.state == .on,
            author: authorText.isEmpty ? nil : authorText,
            resetAuthor: resetAuthor.state == .on
        )
    }

    static func stashCreateRequest(window: NSWindow) async -> RepositoryStashCreateRequest? {
        let alert = NSAlert()
        alert.messageText = "Create a stash"
        alert.informativeText = "Save working directory changes and return to a clean worktree."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Stash")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7

        let message = NSTextField(string: "")
        message.placeholderString = "Optional stash message"
        message.controlSize = .small
        message.widthAnchor.constraint(equalToConstant: 390).isActive = true
        stack.addArrangedSubview(labeledControl("Message:", message))
        let preferences = AppSettingsStore.shared.stashPreferences
        let includeUntracked = checkbox("Include untracked files", state: preferences.includeUntracked)
        let keepIndex = checkbox("Keep staged changes in the index", state: preferences.keepIndex)
        stack.addArrangedSubview(includeUntracked)
        stack.addArrangedSubview(keepIndex)

        let accessory = NSView()
        accessory.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            stack.topAnchor.constraint(equalTo: accessory.topAnchor),
            stack.bottomAnchor.constraint(equalTo: accessory.bottomAnchor)
        ])
        alert.accessoryView = accessory
        let response = await begin(alert: alert, for: window)
        guard response == .alertFirstButtonReturn else { return nil }
        AppSettingsStore.shared.saveStashPreferences(StashPreferences(
            keepIndex: keepIndex.state == .on,
            includeUntracked: includeUntracked.state == .on,
            dontConfirmDrop: preferences.dontConfirmDrop,
            showStashCount: preferences.showStashCount,
            showStashesInRepositoryTree: preferences.showStashesInRepositoryTree,
            windowWidth: preferences.windowWidth,
            windowHeight: preferences.windowHeight,
            dividerPosition: preferences.dividerPosition
        ))
        return RepositoryStashCreateRequest(
            message: message.stringValue,
            includeUntracked: includeUntracked.state == .on,
            keepIndex: keepIndex.state == .on,
            stagedOnly: false
        )
    }

    static func confirmDrop(stash: Stash, window: NSWindow) async -> Bool {
        var preferences = AppSettingsStore.shared.stashPreferences
        if preferences.dontConfirmDrop { return true }
        let alert = NSAlert()
        alert.messageText = "This action cannot be undone"
        alert.informativeText = "Are you sure you want to drop \(stash.selector): \(stash.subject)?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Drop")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't show again"
        let response = await begin(alert: alert, for: window)
        if response == .alertFirstButtonReturn, alert.suppressionButton?.state == .on {
            preferences.dontConfirmDrop = true
            AppSettingsStore.shared.saveStashPreferences(preferences)
        }
        return response == .alertFirstButtonReturn
    }

    static func confirmAbortCherryPick(window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Abort cherry-pick?"
        alert.informativeText = "Git will restore the state from before the current cherry-pick. Commits completed earlier in a multi-selection remain applied."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Abort")
        alert.addButton(withTitle: "Cancel")
        return await begin(alert: alert, for: window) == .alertFirstButtonReturn
    }

    static func confirmResolveCherryPickConflicts(paths: [String], window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Resolve merge conflicts?"
        alert.informativeText = paths.isEmpty
            ? "The cherry-pick stopped with conflicts."
            : "The cherry-pick stopped with conflicts in \(paths.count) path(s)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Resolve conflicts")
        alert.addButton(withTitle: "Later")
        return await begin(alert: alert, for: window) == .alertFirstButtonReturn
    }

    static func confirmResolveStashConflicts(paths: [String], window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Resolve merge conflicts?"
        alert.informativeText = "The stash operation left \(paths.count) unresolved path(s). Open the shared conflict resolver now?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Resolve conflicts")
        alert.addButton(withTitle: "Later")
        return await begin(alert: alert, for: window) == .alertFirstButtonReturn
    }

    static func confirmAbortMerge(window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Abort merge?"
        alert.informativeText = "Git will restore the working tree and index to their state before the current merge began."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Abort")
        alert.addButton(withTitle: "Cancel")
        return await begin(alert: alert, for: window) == .alertFirstButtonReturn
    }

    static func rebaseRequest(target: Commit, fromRevision: String? = nil, window: NSWindow) async -> RepositoryRebaseRequest? {
        let alert = NSAlert()
        alert.messageText = "Rebase current branch?"
        alert.informativeText = "Rebase the current branch on \(target.shortID): \(target.subject). This rewrites commit history."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Rebase")
        alert.addButton(withTitle: "Cancel")
        let autoStash = checkbox("Automatically stash and reapply local changes", state: AppSettingsStore.shared.preferences.autoStashDuringRebase)
        let rebaseMerges = checkbox("Preserve merges (--rebase-merges)", state: false)
        let updateRefs = checkbox("Update dependent refs", state: false)
        let ignoreDate = checkbox("Ignore date", state: false)
        let committerDate = checkbox("Committer date is author date", state: false)
        let specificRange = checkbox("Specific range", state: fromRevision != nil)
        let from = NSTextField(string: fromRevision ?? "")
        from.placeholderString = "From (exclusive)"
        from.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let branch = NSTextField(string: "HEAD")
        branch.placeholderString = "Branch / To"
        branch.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let range = NSStackView(views: [from, branch])
        range.orientation = .horizontal
        range.spacing = 6
        let stack = NSStackView(views: [autoStash, rebaseMerges, updateRefs, ignoreDate, committerDate, specificRange, range])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.widthAnchor.constraint(equalToConstant: 590).isActive = true
        let coordinator = RebaseOptionCoordinator(
            ignoreDate: ignoreDate,
            committerDate: committerDate,
            rebaseMerges: rebaseMerges,
            specificRange: specificRange,
            from: from,
            branch: branch
        )
        alert.accessoryView = stack
        guard await begin(alert: alert, for: window) == .alertFirstButtonReturn else { return nil }
        _ = coordinator
        let useRange = specificRange.state == .on
        return RepositoryRebaseRequest(
            upstream: target.id,
            autoStash: autoStash.state == .on,
            rebaseMerges: rebaseMerges.state == .on,
            updateRefs: updateRefs.state == .on ? true : nil,
            ignoreDate: ignoreDate.state == .on,
            committerDateIsAuthorDate: committerDate.state == .on,
            onto: useRange ? target.id : nil,
            from: useRange ? from.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            branch: useRange ? branch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        )
    }

    static func interactiveRebaseRequest(
        target: Commit,
        plan: [RepositoryRebaseTodoItem],
        initialActions: [String: RepositoryRebaseTodoAction] = [:],
        upstream: String? = nil,
        autoStashDefault: Bool? = nil,
        autoSquashDefault: Bool = false,
        rebaseMergesDefault: Bool = false,
        updateRefsDefault: Bool? = nil,
        onto: String? = nil,
        from: String? = nil,
        branch: String? = nil,
        showOptions: Bool = true,
        window: NSWindow
    ) async -> RepositoryInteractiveRebaseRequest? {
        guard !plan.isEmpty else { return nil }
        let alert = NSAlert()
        alert.messageText = "Interactive rebase"
        alert.informativeText = "Rebase on \(target.shortID): \(target.subject). Set Order to rearrange commits; squash and fixup combine with the previous retained row."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Start rebase")
        alert.addButton(withTitle: "Cancel")

        struct RowControl {
            let originalIndex: Int
            let item: RepositoryRebaseTodoItem
            let order: NSTextField
            let action: NSPopUpButton
            let message: NSTextField
        }
        var controls: [RowControl] = []
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        let orderHeader = label("Order")
        orderHeader.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let actionHeader = label("Action")
        actionHeader.widthAnchor.constraint(equalToConstant: 86).isActive = true
        header.addArrangedSubview(orderHeader)
        header.addArrangedSubview(actionHeader)
        header.addArrangedSubview(label("Revision / reword message"))
        stack.addArrangedSubview(header)

        for (index, item) in plan.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            let order = NSTextField(string: String(index + 1))
            order.controlSize = .small
            order.alignment = .right
            order.widthAnchor.constraint(equalToConstant: 42).isActive = true
            let action = NSPopUpButton()
            action.addItems(withTitles: ["pick", "reword", "edit", "squash", "fixup", "drop"])
            action.controlSize = .small
            action.widthAnchor.constraint(equalToConstant: 86).isActive = true
            let configuredAction = initialActions[item.commitID] ?? item.action
            action.selectItem(withTitle: rebaseActionTitle(configuredAction))
            let message = NSTextField(string: rebaseMessage(configuredAction, fallback: item.subject))
            message.controlSize = .small
            message.placeholderString = "\(String(item.commitID.prefix(8))): \(item.subject)"
            message.widthAnchor.constraint(equalToConstant: 390).isActive = true
            row.addArrangedSubview(order)
            row.addArrangedSubview(action)
            row.addArrangedSubview(message)
            stack.addArrangedSubview(row)
            controls.append(RowControl(originalIndex: index, item: item, order: order, action: action, message: message))
        }

        let autoStash = checkbox("Automatically stash and reapply local changes", state: autoStashDefault ?? AppSettingsStore.shared.preferences.autoStashDuringRebase)
        let autoSquash = checkbox("Autosquash", state: autoSquashDefault)
        let rebaseMerges = checkbox("Preserve merges (--rebase-merges)", state: rebaseMergesDefault)
        let updateRefs = checkbox("Update dependent refs", state: updateRefsDefault == true)
        if showOptions {
            stack.addArrangedSubview(autoStash)
            stack.addArrangedSubview(autoSquash)
            stack.addArrangedSubview(rebaseMerges)
            stack.addArrangedSubview(updateRefs)
        }
        let scroll = NSScrollView()
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 570).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: min(390, CGFloat(75 + plan.count * 29))).isActive = true
        alert.accessoryView = scroll

        guard await begin(alert: alert, for: window) == .alertFirstButtonReturn else { return nil }
        let ordered = controls.sorted { lhs, rhs in
            let left = Int(lhs.order.stringValue) ?? (lhs.originalIndex + 1)
            let right = Int(rhs.order.stringValue) ?? (rhs.originalIndex + 1)
            return left == right ? lhs.originalIndex < rhs.originalIndex : left < right
        }
        let items = ordered.map { control -> RepositoryRebaseTodoItem in
            let selected = control.action.titleOfSelectedItem ?? "pick"
            let action: RepositoryRebaseTodoAction
            switch selected {
            case "reword": action = .reword(control.message.stringValue)
            case "edit": action = .edit
            case "squash": action = .squash
            case "fixup": action = .fixup
            case "drop": action = .drop
            default: action = .pick
            }
            return RepositoryRebaseTodoItem(
                commitID: control.item.commitID,
                subject: control.item.subject,
                action: action
            )
        }
        return RepositoryInteractiveRebaseRequest(
            upstream: upstream ?? target.id,
            items: items,
            autoStash: autoStash.state == .on,
            autoSquash: autoSquash.state == .on,
            rebaseMerges: rebaseMerges.state == .on,
            updateRefs: showOptions ? (updateRefs.state == .on ? true : nil) : updateRefsDefault,
            onto: onto,
            from: from,
            branch: branch
        )
    }

    static func nativeInteractiveRebaseRequest(
        target: Commit,
        upstream: String,
        todo: String,
        initialActions: [String: RepositoryRebaseTodoAction],
        autoStash: Bool,
        autoSquash: Bool,
        rebaseMerges: Bool,
        updateRefs: Bool?,
        onto: String?,
        from: String?,
        branch: String?,
        window: NSWindow
    ) async -> RepositoryInteractiveRebaseRequest? {
        let prepared = todo.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            let line = String(raw)
            let fields = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { return line }
            let commitID = String(fields[1])
            guard let action = initialActions.first(where: { key, _ in
                key.hasPrefix(commitID) || commitID.hasPrefix(key)
            })?.value else { return line }
            let subject = fields.count > 2 ? String(fields[2]) : ""
            let command: String
            let rewrittenSubject: String
            switch action {
            case .pick: command = "pick"; rewrittenSubject = subject
            case .reword(let message): command = "reword"; rewrittenSubject = message
            case .edit: command = "edit"; rewrittenSubject = subject
            case .squash: command = "squash"; rewrittenSubject = subject
            case .fixup: command = "fixup"; rewrittenSubject = subject
            case .drop: command = "drop"; rewrittenSubject = subject
            }
            return "\(command) \(commitID) \(rewrittenSubject.replacingOccurrences(of: "\n", with: " "))"
        }.joined(separator: "\n")
        let (scroll, textView) = nativeRebaseTodoEditor(prepared)
        let alert = NSAlert()
        alert.messageText = "Interactive rebase"
        alert.informativeText = "Edit Git’s rebase todo for \(target.shortID): \(target.subject). Reorder lines or use pick, reword, edit, squash, fixup, and drop. For reword, replace the subject on that line with the new message."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Start rebase")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = scroll
        guard await begin(alert: alert, for: window) == .alertFirstButtonReturn else { return nil }
        return RepositoryInteractiveRebaseRequest(
            upstream: upstream,
            items: [],
            autoStash: autoStash,
            autoSquash: autoSquash,
            rebaseMerges: rebaseMerges,
            updateRefs: updateRefs,
            onto: onto,
            from: from,
            branch: branch,
            nativeTodo: textView.string
        )
    }

    static func editRebaseTodoRequest(
        patches: [RepositoryRebasePatch],
        window: NSWindow
    ) async -> [RepositoryRebaseTodoItem]? {
        let pending = patches.filter { $0.status == .pending }
        guard !pending.isEmpty else { return nil }
        struct Row {
            let index: Int
            let patch: RepositoryRebasePatch
            let order: NSTextField
            let action: NSPopUpButton
            let message: NSTextField
        }
        var rows: [Row] = []
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        for (index, patch) in pending.enumerated() {
            let rowView = NSStackView()
            rowView.orientation = .horizontal
            rowView.spacing = 6
            let order = NSTextField(string: String(index + 1))
            order.widthAnchor.constraint(equalToConstant: 38).isActive = true
            let action = NSPopUpButton()
            action.addItems(withTitles: ["pick", "reword", "edit", "squash", "fixup", "drop"])
            action.selectItem(withTitle: patch.action)
            action.widthAnchor.constraint(equalToConstant: 86).isActive = true
            let message = NSTextField(string: patch.subject)
            message.widthAnchor.constraint(equalToConstant: 390).isActive = true
            rowView.addArrangedSubview(order)
            rowView.addArrangedSubview(action)
            rowView.addArrangedSubview(message)
            stack.addArrangedSubview(rowView)
            rows.append(Row(index: index, patch: patch, order: order, action: action, message: message))
        }
        let scroll = NSScrollView()
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 540).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: min(360, CGFloat(45 + pending.count * 30))).isActive = true
        let alert = NSAlert()
        alert.messageText = "Edit rebase todo"
        alert.informativeText = "Reorder or change the remaining commits. Squash and fixup require a preceding retained commit."
        alert.addButton(withTitle: "Save todo")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = scroll
        guard await begin(alert: alert, for: window) == .alertFirstButtonReturn else { return nil }
        return rows.sorted {
            (Int($0.order.stringValue) ?? $0.index + 1, $0.index) <
            (Int($1.order.stringValue) ?? $1.index + 1, $1.index)
        }.map { row in
            let action: RepositoryRebaseTodoAction = switch row.action.titleOfSelectedItem {
            case "reword": .reword(row.message.stringValue)
            case "edit": .edit
            case "squash": .squash
            case "fixup": .fixup
            case "drop": .drop
            default: .pick
            }
            return RepositoryRebaseTodoItem(commitID: row.patch.commitID, subject: row.patch.subject, action: action)
        }
    }

    static func editNativeRebaseTodoRequest(todo: String, window: NSWindow) async -> String? {
        let (scroll, textView) = nativeRebaseTodoEditor(todo)
        let alert = NSAlert()
        alert.messageText = "Edit rebase todo"
        alert.informativeText = "Edit the remaining native Git todo. Merge labels, resets, merges, and update-ref directives are preserved."
        alert.addButton(withTitle: "Save todo")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = scroll
        guard await begin(alert: alert, for: window) == .alertFirstButtonReturn else { return nil }
        return textView.string
    }

    private static func begin(alert: NSAlert, for window: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    private static func nativeRebaseTodoEditor(_ text: String) -> (NSScrollView, NSTextView) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 430))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        let textView = NSTextView(frame: scroll.contentView.bounds)
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        scroll.documentView = textView
        return (scroll, textView)
    }

    private static func label(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 12)
        return field
    }

    private static func labeledControl(_ title: String, _ control: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let caption = NSTextField(labelWithString: title)
        caption.font = .systemFont(ofSize: 11)
        caption.alignment = .right
        caption.widthAnchor.constraint(equalToConstant: 105).isActive = true
        row.addArrangedSubview(caption)
        row.addArrangedSubview(control)
        return row
    }

    private static func checkbox(_ title: String, state: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.state = state ? .on : .off
        button.controlSize = .small
        return button
    }

    private static func commitMessage(_ commit: Commit?) -> String {
        guard let commit else { return "" }
        return commit.body.isEmpty ? commit.subject : "\(commit.subject)\n\n\(commit.body)"
    }

    private static func rebaseActionTitle(_ action: RepositoryRebaseTodoAction) -> String {
        switch action {
        case .pick: "pick"
        case .reword: "reword"
        case .edit: "edit"
        case .squash: "squash"
        case .fixup: "fixup"
        case .drop: "drop"
        }
    }

    private static func rebaseMessage(_ action: RepositoryRebaseTodoAction, fallback: String) -> String {
        if case .reword(let message) = action { return message }
        return fallback
    }
}
