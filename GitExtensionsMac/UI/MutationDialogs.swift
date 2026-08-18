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
        let includeUntracked = checkbox("Include untracked files", state: false)
        let keepIndex = checkbox("Keep staged changes in the index", state: false)
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
        return RepositoryStashCreateRequest(
            message: message.stringValue,
            includeUntracked: includeUntracked.state == .on,
            keepIndex: keepIndex.state == .on,
            stagedOnly: false
        )
    }

    static func confirmDrop(stash: Stash, window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Drop stash?"
        alert.informativeText = "Drop \(stash.selector): \(stash.subject)\n\nThis action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Drop")
        alert.addButton(withTitle: "Cancel")
        return await begin(alert: alert, for: window) == .alertFirstButtonReturn
    }

    static func cherryPickRequest(
        commits: [Commit],
        history: [Commit],
        window: NSWindow
    ) async -> RepositoryCherryPickRequest? {
        guard !commits.isEmpty else { return nil }
        let alert = NSAlert()
        alert.messageText = commits.count == 1 ? "Cherry pick commit" : "Cherry pick \(commits.count) commits"
        alert.informativeText = "Commits will be applied from oldest to newest in the order shown."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Cherry pick")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        var mainlineControls: [String: NSPopUpButton] = [:]
        for (index, commit) in commits.enumerated() {
            let row = label("\(index + 1). \(commit.shortID): \(commit.subject)")
            row.lineBreakMode = .byTruncatingTail
            row.widthAnchor.constraint(lessThanOrEqualToConstant: 510).isActive = true
            stack.addArrangedSubview(row)
            if commit.isMerge {
                let parent = NSPopUpButton()
                let titles = commit.parentIDs.enumerated().map { parentIndex, parentID in
                    let parentCommit = history.first(where: { $0.id == parentID })
                    let description = parentCommit.map { "\($0.shortID): \($0.subject)" } ?? String(parentID.prefix(8))
                    return "Parent \(parentIndex + 1) — \(description)"
                }
                parent.addItems(withTitles: titles)
                parent.controlSize = .small
                stack.addArrangedSubview(labeledControl("Mainline:", parent))
                mainlineControls[commit.id] = parent
            }
        }

        let automaticallyCommit = checkbox("Automatically create a commit", state: false)
        let addReference = checkbox("Add commit reference to commit message (-x)", state: false)
        stack.addArrangedSubview(automaticallyCommit)
        stack.addArrangedSubview(addReference)

        let scroll = NSScrollView()
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 540).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: min(330, CGFloat(110 + commits.count * 31))).isActive = true
        alert.accessoryView = scroll

        let response = await begin(alert: alert, for: window)
        guard response == .alertFirstButtonReturn else { return nil }
        let items = commits.map { commit in
            RepositoryCherryPickItem(
                commitID: commit.id,
                mainlineParent: mainlineControls[commit.id].map { $0.indexOfSelectedItem + 1 }
            )
        }
        return RepositoryCherryPickRequest(
            items: items,
            options: RepositoryCherryPickOptions(
                automaticallyCommit: automaticallyCommit.state == .on,
                addReference: addReference.state == .on
            )
        )
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

    static func confirmAbortMerge(window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Abort merge?"
        alert.informativeText = "Git will restore the working tree and index to their state before the current merge began."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Abort")
        alert.addButton(withTitle: "Cancel")
        return await begin(alert: alert, for: window) == .alertFirstButtonReturn
    }

    static func rebaseRequest(target: Commit, window: NSWindow) async -> RepositoryRebaseRequest? {
        let alert = NSAlert()
        alert.messageText = "Rebase current branch?"
        alert.informativeText = "Rebase the current branch on \(target.shortID): \(target.subject). This rewrites commit history."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Rebase")
        alert.addButton(withTitle: "Cancel")
        let autoStash = checkbox("Automatically stash and reapply local changes", state: AppSettingsStore.shared.preferences.autoStashDuringRebase)
        alert.accessoryView = autoStash
        guard await begin(alert: alert, for: window) == .alertFirstButtonReturn else { return nil }
        return RepositoryRebaseRequest(upstream: target.id, autoStash: autoStash.state == .on)
    }

    static func interactiveRebaseRequest(
        target: Commit,
        plan: [RepositoryRebaseTodoItem],
        initialActions: [String: RepositoryRebaseTodoAction] = [:],
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

        let autoStash = checkbox("Automatically stash and reapply local changes", state: AppSettingsStore.shared.preferences.autoStashDuringRebase)
        stack.addArrangedSubview(autoStash)
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
            upstream: target.id,
            items: items,
            autoStash: autoStash.state == .on
        )
    }

    static func confirmAbortRebase(window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Abort rebase?"
        alert.informativeText = "Git will restore the branch and working tree to their state before this rebase began."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Abort")
        alert.addButton(withTitle: "Cancel")
        return await begin(alert: alert, for: window) == .alertFirstButtonReturn
    }

    private static func begin(alert: NSAlert, for window: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
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
