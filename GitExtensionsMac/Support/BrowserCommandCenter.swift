import AppKit

extension Notification.Name {
    static let browserPlaceholderAction = Notification.Name("GitExtensionsMac.browserPlaceholderAction")
}

enum BrowserCommandCenter {
    static func perform(_ title: String) {
        NotificationCenter.default.post(
            name: .browserPlaceholderAction,
            object: nil,
            userInfo: ["title": title]
        )
    }
}

final class PlaceholderMenuTarget: NSObject {
    static let shared = PlaceholderMenuTarget()

    @objc func perform(_ sender: NSMenuItem) {
        BrowserCommandCenter.perform(sender.title.replacingOccurrences(of: "…", with: ""))
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
