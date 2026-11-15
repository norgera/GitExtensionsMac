import AppKit
import ObjectiveC

@MainActor
final class ZoomedMenuController {

    static let shared = ZoomedMenuController()

    private struct MenuState {
        weak var menu: NSMenu?
        let font: NSFont?
    }

    private struct ItemState {
        weak var item: NSMenuItem?
        let image: NSImage?
        let attributedTitle: NSAttributedString?
    }

    private final class Session {
        weak var root: NSMenu?
        let scale: CGFloat
        let keepsFirstItem: Bool
        var menus: [ObjectIdentifier: MenuState] = [:]
        var items: [ObjectIdentifier: ItemState] = [:]

        init(root: NSMenu, scale: CGFloat, keepsFirstItem: Bool) {
            self.root = root
            self.scale = scale
            self.keepsFirstItem = keepsFirstItem
        }
    }

    private var session: Session?
    private var observers: [NSObjectProtocol] = []
    private static var hookedContextMenus = false

    var activeScale: CGFloat? { session?.root == nil ? nil : session?.scale }

    func install() {
        Self.installContextMenuHook()
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSPopUpButton.willPopUpNotification, object: nil, queue: nil) { [weak self] note in
            MainActor.assumeIsolated {
                guard let button = note.object as? NSPopUpButton, let menu = button.menu else { return }
                self?.prepare(menu, for: button, keepsFirstItem: button.pullsDown)
            }
        })
        observers.append(center.addObserver(forName: NSComboBox.willPopUpNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                guard let comboBox = note.object as? NSComboBox else { return }
                Self.zoomDropDown(of: comboBox)
                RunLoop.main.perform(inModes: [.common, .eventTracking, .modalPanel]) {
                    MainActor.assumeIsolated { Self.zoomDropDown(of: comboBox) }
                }
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { [weak self] note in
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu else { return }
                self?.finish(menu)
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: nil) { [weak self] note in
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu, let index = note.userInfo?["NSMenuItemIndex"] as? Int else { return }
                self?.menu(menu, didAddItemAt: index)
            }
        })
    }

    func uninstall() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        restore()
    }

    static func installContextMenuHook() {
        guard !hookedContextMenus else { return }
        hookedContextMenus = true
        guard let original = class_getInstanceMethod(NSView.self, #selector(NSView.willOpenMenu(_:with:))),
              let replacement = class_getInstanceMethod(NSView.self, #selector(NSView.gitExtensionsZoomedWillOpenMenu(_:with:)))
        else { return }
        method_exchangeImplementations(original, replacement)
    }

    func prepare(_ menu: NSMenu, for view: NSView, keepsFirstItem: Bool = false) {
        prepare(menu, scale: ContentZoomController.displayScale(of: view), keepsFirstItem: keepsFirstItem)
    }

    func prepare(_ menu: NSMenu, scale: CGFloat, keepsFirstItem: Bool = false) {
        if let session, session.root === menu, abs(session.scale - scale) < 0.001 { return }
        restore()
        guard scale.isFinite, scale > 0, abs(scale - 1) > 0.001 else { return }
        session = Session(root: menu, scale: scale, keepsFirstItem: keepsFirstItem)
        apply(to: menu)
    }

    func finish(_ menu: NSMenu) {
        guard let session, session.root === menu || session.root == nil else { return }
        restore()
    }

    func restore() {
        guard let session else { return }
        self.session = nil
        for state in session.items.values {
            guard let item = state.item else { continue }
            item.image = state.image
            if let title = state.attributedTitle { item.attributedTitle = title }
        }
        for state in session.menus.values {
            state.menu?.font = state.font
        }
    }

    private func menu(_ menu: NSMenu, didAddItemAt index: Int) {
        guard let session, session.menus[ObjectIdentifier(menu)]?.menu === menu,
              index >= 0, index < menu.numberOfItems else { return }
        apply(to: menu.items[index], in: menu)
    }

    private func apply(to menu: NSMenu) {
        guard let session, session.menus[ObjectIdentifier(menu)]?.menu !== menu else { return }
        let font: NSFont? = menu.font
        session.menus[ObjectIdentifier(menu)] = MenuState(menu: menu, font: font)
        menu.font = Self.resized(font ?? NSFont.menuFont(ofSize: 0), by: session.scale)
        for item in menu.items { apply(to: item, in: menu) }
    }

    private func apply(to item: NSMenuItem, in menu: NSMenu) {
        guard let session, session.items[ObjectIdentifier(item)]?.item !== item else { return }
        if session.keepsFirstItem, menu === session.root, menu.index(of: item) == 0 { return }
        session.items[ObjectIdentifier(item)] = ItemState(item: item, image: item.image, attributedTitle: item.attributedTitle)
        if let image = item.image, let copy = image.copy() as? NSImage {
            copy.size = NSSize(width: image.size.width * session.scale, height: image.size.height * session.scale)
            item.image = copy
        }
        if let title = item.attributedTitle {
            item.attributedTitle = Self.scaled(title, by: session.scale, fallback: menu.font ?? NSFont.menuFont(ofSize: 0))
        }
        if let submenu = item.submenu { apply(to: submenu) }
    }

    static func dropDownList(of comboBox: NSComboBox) -> NSScrollView? {
        for window in comboBox.window?.childWindows ?? [] where String(describing: type(of: window)).hasPrefix("NSComboBox") {
            if let content = window.contentView, let list = listScrollView(in: content) { return list }
        }
        return nil
    }

    static func zoomDropDown(of comboBox: NSComboBox) {
        guard let list = dropDownList(of: comboBox) else { return }
        magnify(list, by: ContentZoomController.displayScale(of: comboBox))
    }

    static func magnify(_ list: NSScrollView, by scale: CGFloat) {
        guard scale.isFinite, scale > 0, let table = list.documentView as? NSTableView else { return }
        if abs(list.magnification - scale) > 0.001 {
            list.minMagnification = min(list.minMagnification, scale)
            list.maxMagnification = max(list.maxMagnification, scale)
            list.magnification = scale
        }
        fitWidth(of: table, in: list)
        observeWidth(of: table, in: list)
        list.contentView.scroll(to: .zero)
        list.reflectScrolledClipView(list.contentView)
        if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
    }

    private struct WidthObserver {
        weak var table: NSTableView?
        let token: NSObjectProtocol
    }

    private static var widthObservers: [ObjectIdentifier: WidthObserver] = [:]

    private static func fitWidth(of table: NSTableView, in list: NSScrollView) {
        let width = list.contentView.bounds.width
        guard abs(table.frame.width - width) > 0.5 else { return }
        table.setFrameSize(NSSize(width: width, height: table.frame.height))
        table.sizeLastColumnToFit()
        list.contentView.scroll(to: NSPoint(x: 0, y: list.contentView.bounds.minY))
    }

    private static func observeWidth(of table: NSTableView, in list: NSScrollView) {
        for (key, observer) in widthObservers where observer.table == nil {
            NotificationCenter.default.removeObserver(observer.token)
            widthObservers.removeValue(forKey: key)
        }
        guard widthObservers[ObjectIdentifier(table)] == nil else { return }
        table.postsFrameChangedNotifications = true
        let token = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: table, queue: nil
        ) { [weak table, weak list] _ in
            MainActor.assumeIsolated {
                guard let table, let list else { return }
                fitWidth(of: table, in: list)
            }
        }
        widthObservers[ObjectIdentifier(table)] = WidthObserver(table: table, token: token)
    }

    private static func listScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView, scrollView.documentView is NSTableView { return scrollView }
        for subview in view.subviews {
            if let found = listScrollView(in: subview) { return found }
        }
        return nil
    }

    static func resized(_ font: NSFont, by scale: CGFloat) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? NSFont.menuFont(ofSize: font.pointSize * scale)
    }

    static func scaled(_ title: NSAttributedString, by scale: CGFloat, fallback: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: title)
        let whole = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.font, in: whole) { value, range, _ in
            let font = (value as? NSFont).map { resized($0, by: scale) } ?? fallback
            result.addAttribute(.font, value: font, range: range)
        }
        return result
    }
}

extension NSView {
    @objc fileprivate func gitExtensionsZoomedWillOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        ZoomedMenuController.shared.prepare(menu, for: self)
        gitExtensionsZoomedWillOpenMenu(menu, with: event)
    }
}

extension NSMenu {
    @MainActor @discardableResult
    func popUpZoomed(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool {
        if let view { ZoomedMenuController.shared.prepare(self, for: view) }
        defer { ZoomedMenuController.shared.finish(self) }
        return popUp(positioning: item, at: location, in: view)
    }
}
