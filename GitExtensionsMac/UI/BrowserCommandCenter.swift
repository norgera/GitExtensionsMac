import GitExtensionsCore
import GitCommands
import AppKit

import Combine

extension Notification.Name {
    static let browserCommand = Notification.Name("GitExtensionsMac.browserCommand")
}

enum BrowserCommand: Equatable, Sendable {
    case openRepository
    case closeToDashboard
    case cloneRepository
    case initializeRepository
    case settings
    case repositorySettings
    case scripts
    case plugins
    case viewHostedPullRequests
    case createHostedPullRequest
    case forkHostedRepository
    case addHostedUpstream
    case executePlugin(UUID)
    case clearRecentRepositories
    case openRecentRepository(URL)
    case openRepositoryAtRevisions(URL, [RevisionID])

    case refresh
    case toggleRevisionTags
    case toggleBuildStatusIcon
    case toggleBuildStatusText
    case commit
    case pullFetch
    case pull
    case openPullDialog
    case pullMerge
    case pullRebase
    case push
    case fetch
    case fetchAll
    case fetchAndPruneAll
    case remoteRepositories
    case mergeBranches
    case createBranch
    case deleteBranch
    case checkoutBranch
    case checkoutRevision
    case createTag
    case deleteTag
    case manageStashes
    case resetChanges
    case cleanRepository
    case bisect
    case reflog
    case formatPatch
    case archiveRevision
    case applyPatch
    case viewPatch
    case manageWorktrees
    case manageSubmodules
    case updateSubmodules
    case synchronizeSubmodules
    case solveMergeConflicts
    case cherryPick
    case rebase

    case undoLastCommit
    case openFileExplorer
    case openTerminal
    case deleteIndexLock
    case compressGitDatabase

    case editGitIgnore
    case editGitInfoExclude
    case editGitAttributes
    case editMailMap
    case editGitConfig

    case sparseWorkingCopy

    case recoverLostObjects
    case toggleLeftPanel
    case outputHistory
    case toggleSplitViewLayout
    case commitInfoPosition(Int)
    case toolbarVisibility(String)
    case toolbarItemVisibility(String)
    case stash
    case stashPop
    case stashStaged
    case quickPull
    case quickFetch
    case quickPush
    case quickPullOrFetch
    case focusFilter
    case focusNextTab(Bool)
    case goToSuperproject
    case goToSubmodule
    case revisionGridRestoringFileFocus(String)


    case revisionGrid(String)



    case addNotes

    case fileListCommand(String)
    case refreshDashboard
    case recentRepositoriesSettings

    case gitGui
    case gitK

    case showStatus(String)
    case unavailable(String)
}

private final class BrowserCommandPayload: NSObject {
    let command: BrowserCommand

    init(_ command: BrowserCommand) {
        self.command = command
    }
}

enum BrowserCommandCenter {
    static func perform(_ command: BrowserCommand) {
        NotificationCenter.default.post(
            name: .browserCommand,
            object: BrowserCommandPayload(command)
        )
    }

    static func command(from notification: Notification) -> BrowserCommand? {
        (notification.object as? BrowserCommandPayload)?.command
    }

    static func assign(_ command: BrowserCommand, to menuItem: NSMenuItem) {
        menuItem.representedObject = BrowserCommandPayload(command)
    }

    static func command(from menuItem: NSMenuItem?) -> BrowserCommand? {
        (menuItem?.representedObject as? BrowserCommandPayload)?.command
    }
}

@MainActor
final class BrowserCommandAvailability: ObservableObject {
    static let shared = BrowserCommandAvailability()
    struct PluginEntry: Identifiable {
        let id: UUID
        let title: String
        let icon: NSImage?
    }
    @Published var plugins: [PluginEntry] = []

    @Published var canMerge = false
    @Published var showBuildStatusIcon = AppSettingsStore.shared.showBuildStatusIconColumn
    @Published var showBuildStatusText = AppSettingsStore.shared.showBuildStatusTextColumn
    @Published var canCreateBranch = false
    @Published var canDeleteBranch = false
    @Published var canCheckoutBranch = false
    @Published var canCheckoutRevision = false
    @Published var canCreateTag = false
    @Published var canDeleteTag = false
    @Published var canReset = false
    @Published var canClean = false
    @Published var canBisect = false
    @Published var canReflog = false
    @Published var canPatch = false
    @Published var canArchive = false
    @Published var canManageWorktrees = false
    @Published var canManageSubmodules = false

    @Published var toolbars: [BrowserToolbarState] = []

    @Published var layout = BrowserLayoutPreferences()

    @Published var hasRepository = false

    @Published var isDashboard = false
    @Published var isBareRepository = false

    @Published var selectionEligibility = BrowserCommandEligibility()

    @Published var gridMenuState: RevisionGridMenuModel.State?

    private init() {}
}

extension BrowserCommand {

    static func browseHotkey(_ identifier: String) -> BrowserCommand? {
        switch identifier {
        case "stash": .stash
        case "stashPop": .stashPop
        case "stashStaged": .stashStaged
        case "quickPull": .quickPull
        case "quickFetch": .quickFetch
        case "quickPullOrFetch": .quickPullOrFetch
        case "quickPush": .quickPush
        case "toggleLeftPanel": .toggleLeftPanel
        case "gitBash": .openTerminal
        case "focusFilter": .focusFilter
        case "focusNextTab": .focusNextTab(true)
        case "focusPrevTab": .focusNextTab(false)
        case "goToSuperproject": .goToSuperproject
        case "goToSubmodule": .goToSubmodule
        case "goToChild": .revisionGridRestoringFileFocus("revision.navigate.child")
        case "goToParent": .revisionGridRestoringFileFocus("revision.navigate.parent")
        case "toggleArtificialAndHead": .revisionGrid("revision.navigate.toggleArtificial")
        case "openCommitsWithDifftool": .revisionGrid("revision.compare.difftool")
        case "addNotes": .addNotes
        case "openWithDifftool", "openWithDifftoolFirstToLocal", "openWithDifftoolSelectedToLocal",
             "openAsTempFile", "openAsTempFileWith", "findFileInSelectedCommit", "editFile": .fileListCommand(identifier)
        default: nil
        }
    }
}


struct BrowserToolbarState: Equatable, Sendable, Identifiable {
    struct Item: Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        var isVisible: Bool
    }
    let id: String
    var isVisible: Bool
    var items: [Item]
}


struct BrowserCommandEligibility: Equatable, Sendable {

    var singleNormalCommitNotBare = false

    var rebase = false

    var singleNormalCommit = false

    var notBare = false

    static func make(selected: [Commit], isBare: Bool) -> Self {
        let single = selected.count == 1 && !selected[0].isArtificial
        var eligibility = Self()
        eligibility.singleNormalCommit = single
        eligibility.singleNormalCommitNotBare = single && !isBare
        eligibility.rebase = (1...2).contains(selected.count) && selected.allSatisfy { !$0.isArtificial } && !isBare
        eligibility.notBare = !isBare
        return eligibility
    }
}

final class PlaceholderMenuTarget: NSObject {
    static let shared = PlaceholderMenuTarget()

    @objc func perform(_ sender: NSMenuItem) {
        BrowserCommandCenter.perform(
            .unavailable(sender.title.replacingOccurrences(of: "…", with: ""))
        )
    }
}

func placeholderMenuItem(_ title: String, keyEquivalent: String = "") -> NSMenuItem {
    let item = NSMenuItem(
        title: title,
        action: #selector(PlaceholderMenuTarget.perform(_:)),
        keyEquivalent: keyEquivalent
    )
    item.target = PlaceholderMenuTarget.shared
    return item
}

func populatePlaceholderMenu(_ menu: NSMenu, with entries: [ContextMenuEntry]) {
    menu.removeAllItems()
    menu.autoenablesItems = false

    for entry in entries {
        switch entry {
        case .separator:
            menu.addItem(.separator())

        case .command(let id, let title, let isEnabled):
            let item = placeholderMenuItem(title)
            item.identifier = NSUserInterfaceItemIdentifier(id)
            item.representedObject = id
            item.isEnabled = isEnabled
            menu.addItem(item)

        case .submenu(let id, let title, let isEnabled, let children):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            item.representedObject = id
            item.isEnabled = isEnabled
            let childMenu = NSMenu(title: title)
            populatePlaceholderMenu(childMenu, with: children)
            item.submenu = childMenu
            menu.addItem(item)
        }
    }
}

func menuItem(withIdentifier identifier: String, in menu: NSMenu) -> NSMenuItem? {
    for item in menu.items {
        if item.identifier?.rawValue == identifier { return item }
        if let submenu = item.submenu,
           let nested = menuItem(withIdentifier: identifier, in: submenu) {
            return nested
        }
    }
    return nil
}

func retargetMenuItems(
    in menu: NSMenu,
    where predicate: (String) -> Bool,
    target: AnyObject,
    action: Selector
) {
    for item in menu.items {
        if let identifier = item.identifier?.rawValue, predicate(identifier) {
            item.target = target
            item.action = action
        }
        if let submenu = item.submenu {
            retargetMenuItems(in: submenu, where: predicate, target: target, action: action)
        }
    }
}
