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
    case settings
    case clearRecentRepositories
    case openRecentRepository(URL)

    case refresh
    case toggleRevisionTags
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
    case solveMergeConflicts
    case cherryPick
    case rebase

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

    @Published var canMerge = false
    @Published var canCreateBranch = false
    @Published var canDeleteBranch = false
    @Published var canCheckoutBranch = false
    @Published var canCheckoutRevision = false
    @Published var canCreateTag = false
    @Published var canDeleteTag = false

    private init() {}
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
