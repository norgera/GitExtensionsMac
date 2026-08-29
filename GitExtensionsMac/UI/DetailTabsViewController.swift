import GitExtensionsCore
import GitCommands
import AppKit

final class DetailTabsViewController: NSViewController {
    var onSelectionChanged: ((Int) -> Void)?

    private let tabStack = NSStackView()
    private let contentView = NSView()
    private var controllers: [NSViewController] = []
    private var tabButtons: [DetailTabButton] = []
    private var selectedIndex = 0

    var selectedTabIndex: Int { selectedIndex }

    func configure(items: [(String, String, NSViewController)], selectedIndex: Int) {
        controllers.forEach { $0.removeFromParent() }
        controllers = items.map(\.2)
        self.selectedIndex = min(max(0, selectedIndex), max(0, items.count - 1))
        controllers.forEach(addChild)

        tabButtons.forEach {
            tabStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        tabButtons = items.enumerated().map { index, item in
            let button = DetailTabButton(
                title: item.0,
                imageName: item.1,
                target: self,
                action: #selector(changeTab(_:))
            )
            button.tag = index
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: Self.tabWidth(for: item.0, showsIcon: true)).isActive = true
            tabStack.addArrangedSubview(button)
            return button
        }
        updateTabSelection()

        if isViewLoaded {
            showController(at: self.selectedIndex)
        }
    }

    override func loadView() {
        let root = NSView()
        let tabBar = NSVisualEffectView()
        tabBar.material = .headerView
        tabBar.blendingMode = .withinWindow
        tabBar.state = .active
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        tabStack.orientation = .horizontal
        tabStack.alignment = .bottom
        tabStack.spacing = 0
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let bottomBorder = NSBox()
        bottomBorder.boxType = .separator
        bottomBorder.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(bottomBorder)
        tabBar.addSubview(tabStack)
        root.addSubview(tabBar)
        root.addSubview(contentView)

        let tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 21)
        tabBarHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBarHeight,
            bottomBorder.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
            tabStack.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor),
            tabStack.topAnchor.constraint(equalTo: tabBar.topAnchor),
            tabStack.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
        showController(at: selectedIndex)
    }

    @objc private func changeTab(_ sender: DetailTabButton) {
        guard sender.tag != selectedIndex else { return }
        showController(at: sender.tag)
        onSelectionChanged?(selectedIndex)
    }

    private func showController(at index: Int) {
        guard index >= 0, index < controllers.count else { return }
        selectedIndex = index
        updateTabSelection()
        contentView.subviews.forEach { $0.removeFromSuperview() }
        let controllerView = controllers[index].view
        controllerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(controllerView)
        NSLayoutConstraint.activate([
            controllerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            controllerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            controllerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            controllerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    private func updateTabSelection() {
        for (index, button) in tabButtons.enumerated() {
            button.isSelectedTab = index == selectedIndex
        }
    }

    private static func tabWidth(for title: String, showsIcon: Bool) -> CGFloat {
        let textWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
        let iconAndGap: CGFloat = showsIcon ? 20 : 0
        return max(44, ceil(textWidth) + iconAndGap + 14)
    }
}

private final class DetailTabButton: NSButton {
    private let tabImage: NSImage?

    var isSelectedTab = false {
        didSet { needsDisplay = true }
    }

    init(title: String, imageName: String, target: AnyObject?, action: Selector?) {
        tabImage = AppKitFactory.resourceImage(imageName, accessibilityDescription: title)
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        font = .systemFont(ofSize: 11)
        setButtonType(.momentaryChange)
        self.title = title
        self.target = target
        self.action = action
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        if isSelectedTab {
            NSColor.controlBackgroundColor.setFill()
            bounds.fill()
        } else if isHighlighted {
            NSColor.selectedControlColor.withAlphaComponent(0.12).setFill()
            rect.fill()
        }

        NSColor.separatorColor.setStroke()
        let border = NSBezierPath()
        border.move(to: NSPoint(x: rect.minX, y: rect.minY))
        border.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        border.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        border.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        if !isSelectedTab { border.line(to: NSPoint(x: rect.minX, y: rect.minY)) }
        border.lineWidth = 1
        border.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor
        ]
        let size = title.size(withAttributes: attributes)
        let imageSize = tabImage == nil ? NSSize.zero : NSSize(width: 16, height: 16)
        let gap: CGFloat = tabImage == nil ? 0 : 4
        let contentWidth = imageSize.width + gap + size.width
        let contentX = floor((bounds.width - contentWidth) / 2)
        if let tabImage {
            let imageRect = NSRect(
                x: contentX,
                y: floor((bounds.height - imageSize.height) / 2),
                width: imageSize.width,
                height: imageSize.height
            )
            tabImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        title.draw(
            at: NSPoint(x: contentX + imageSize.width + gap, y: floor((bounds.height - size.height) / 2)),
            withAttributes: attributes
        )
    }
}
