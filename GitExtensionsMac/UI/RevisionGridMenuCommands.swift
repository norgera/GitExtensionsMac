import AppKit
import GitCommands
import GitExtensionsCore



struct RevisionGridMenuCommand: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case command, header, separator }
    var kind: Kind = .command
    var id = ""
    var title = ""
    var checked: Bool?
    var enabled = true
    static let separator = RevisionGridMenuCommand(kind: .separator)
    static func header(_ title: String) -> Self { .init(kind: .header, title: title) }
}

enum RevisionGridMenuModel {
    struct State: Equatable, Sendable {
        var filter = RevisionGridFilter()
        var preferences = RevisionGridPreferences()
        var sortOrder: RevisionSortOrder = .gitDefault
        var showTags = true
        var nonRelativesGray = true
        var buildIcon = true
        var buildText = false
        var canNavigateBackward = false
        var canNavigateForward = false
    }

    static func navigate(_ state: State) -> [RevisionGridMenuCommand] {
        [.init(id: "revision.navigate.toggleArtificial", title: "Toggle between artificial and HEAD commits"),
         .init(id: "revision.navigate.current", title: "Go to current revision"),
         .init(id: "revision.navigate.commit", title: "Go to commit…"),
         .separator,
         .init(id: "revision.navigate.child", title: "Go to child commit"),
         .init(id: "revision.navigate.parent", title: "Go to parent commit"),
         .init(id: "revision.navigate.firstParent", title: "Go to first parent commit"),
         .init(id: "revision.navigate.lastParent", title: "Go to last parent commit"),
         .init(id: "revision.navigate.mergeBase", title: "Go to common ancestor (merge base)"),
         .separator,
         .init(id: "revision.navigate.backward", title: "Navigate backward", enabled: state.canNavigateBackward),
         .init(id: "revision.navigate.forward", title: "Navigate forward", enabled: state.canNavigateForward),
         .separator,
         .init(id: "revision.search.help", title: "Quick search"),
         .init(id: "revision.search.previous", title: "Quick search previous"),
         .init(id: "revision.search.next", title: "Quick search next")]
    }

    static func view(_ state: State) -> [RevisionGridMenuCommand] {
        let preferences = state.preferences
        return [.header("Branches"),
                .init(id: "revision.branches.all", title: "Show all branches", checked: state.filter.isShowAllBranchesChecked),
                .init(id: "revision.branches.current", title: "Show current branch only", checked: state.filter.isShowCurrentBranchOnlyChecked),
                .init(id: "revision.branches.filtered", title: "Show filtered branches", checked: state.filter.isShowFilteredBranchesChecked),
                .init(id: "revision.other.reflog", title: "Show reflog references", checked: state.filter.showReflogReferences),
                .separator,
                .init(id: "revision.filter.advanced", title: "Advanced filter…"),
                .separator,
                .init(id: "revision.view.nonRelativesGray", title: "Draw non relatives gray", checked: state.nonRelativesGray),
                .init(id: "revision.view.highlightBranch", title: "Highlight selected branch (until refresh)"),
                .separator,
                .header("Commits"),
                .init(id: "revision.view.artificial", title: "Show artificial commits", checked: preferences.showArtificialCommits),
                .init(id: "revision.view.stashes", title: "Show stashes", checked: preferences.showStashes),
                .init(id: "revision.view.gitNotes", title: "Show git notes", checked: preferences.showGitNotes),
                .init(id: "revision.view.sessionRefs", title: "Show session checkpoints", checked: preferences.showSessionRefs),
                .separator,
                .header("Grid labels"),
                .init(id: "revision.view.remoteBranches", title: "Show remote branches", checked: preferences.showRemoteBranches),
                .init(id: "revision.view.tags", title: "Show tags", checked: state.showTags),
                .init(id: "revision.view.superprojectTags", title: "Show superproject tags", checked: preferences.showSuperprojectTags),
                .init(id: "revision.view.superprojectRemoteBranches", title: "Show superproject remote branches", checked: preferences.showSuperprojectRemoteBranches),
                .init(id: "revision.view.superprojectBranches", title: "Show superproject branches", checked: preferences.showSuperprojectBranches),
                .separator,
                .header("Grid info"),
                .init(id: "revision.view.buildIcon", title: "Show build status icon", checked: state.buildIcon),
                .init(id: "revision.view.buildText", title: "Show build status text", checked: state.buildText),
                .init(id: "revision.view.commitBody", title: "Show commit message body", checked: preferences.showCommitBody),
                .init(id: "revision.view.authorDate", title: "Show author date", checked: preferences.showAuthorDate),
                .init(id: "revision.view.relativeDate", title: "Show relative date", checked: preferences.relativeDate),
                .separator,
                .header("Columns"),
                .init(id: "revision.column.graph", title: "Show revision graph column", checked: preferences.showGraphColumn),
                .init(id: "revision.column.notes", title: "Show Git notes column", checked: preferences.showNotesColumn),
                .init(id: "revision.column.avatar", title: "Show author avatar column", checked: preferences.showAuthorAvatarColumn),
                .init(id: "revision.column.author", title: "Show author name column", checked: preferences.showAuthorNameColumn),
                .init(id: "revision.column.date", title: "Show date column", checked: preferences.showDateColumn),
                .init(id: "revision.column.id", title: "Show SHA-1 column", checked: preferences.showObjectIDColumn),
                .separator,
                .header("Sorting"),
                .init(id: "revision.sort.authorDate", title: "Sort commits by author date", checked: state.sortOrder == .authorDate),
                .init(id: "revision.sort.topo", title: "Arrange commits by topo order (ancestor order)", checked: state.sortOrder == .topology),
                .separator,
                .header("Settings persistence"),
                .init(id: "revision.view.saveDefaults", title: "Save current view settings as default")]
    }


    static let images: [String: String] = [
        "revision.navigate.toggleArtificial": "WorkingDirChanges", "revision.navigate.current": "GotoCurrentRevision",
        "revision.navigate.commit": "GotoCommit", "revision.navigate.child": "GoToChildCommit",
        "revision.navigate.parent": "GoToParentCommit", "revision.navigate.firstParent": "GoToFirstParentCommit",
        "revision.navigate.lastParent": "GoToLastParentCommit", "revision.navigate.mergeBase": "GoToMergeBaseCommit",
        "revision.navigate.backward": "NavigateBackward", "revision.navigate.forward": "NavigateForward",
        "revision.branches.all": "BranchLocal", "revision.branches.current": "BranchFilter",
        "revision.branches.filtered": "BranchFilter", "revision.other.reflog": "Book", "revision.filter.advanced": "EditFilter"
    ]


    @MainActor static func fill(_ menu: NSMenu, _ commands: [RevisionGridMenuCommand], target: AnyObject, action: Selector) {
        menu.autoenablesItems = false
        for command in commands {
            switch command.kind {
            case .separator: menu.addItem(.separator())
            case .header:
                let item = NSMenuItem(title: command.title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.attributedTitle = NSAttributedString(string: command.title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)])
                menu.addItem(item)
            case .command:
                let item = NSMenuItem(title: command.title, action: action, keyEquivalent: "")
                item.target = target
                item.identifier = NSUserInterfaceItemIdentifier(command.id)
                item.representedObject = command.id
                item.isEnabled = command.enabled
                item.state = command.checked == true ? .on : .off
                if let image = images[command.id] { item.image = AppKitFactory.resourceImage(image) }
                if let chord = ApplicationHotkeys.shared.chord(for: command.id), let equivalent = chord.key.first {
                    item.keyEquivalent = String(equivalent)
                    item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: chord.modifiers)
                }
                menu.addItem(item)
            }
        }
    }
}
