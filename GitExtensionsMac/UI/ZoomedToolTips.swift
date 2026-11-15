import AppKit

@MainActor
protocol ZoomedToolTipSource: AnyObject {
    func zoomedToolTip(at point: NSPoint) -> String?
}

@MainActor
final class ZoomedToolTipController {

    static let shared = ZoomedToolTipController()

    enum Metrics {
        static let baseFontSize: CGFloat = 11
        static let initialDelay: TimeInterval = 1.0
        static let quickDelay: TimeInterval = 0.05
        static let quickWindow: TimeInterval = 0.6
        static let pollInterval: TimeInterval = 0.1
        static let maximumWidth: CGFloat = 480
        static let horizontalPadding: CGFloat = 6
        static let verticalPadding: CGFloat = 4
        static let cursorOffset: CGFloat = 20
        static let screenMargin: CGFloat = 4
        static let systemDelaySuppression = 86_400_000
    }

    struct Hit: Equatable {
        let text: String
        let scale: CGFloat
        let region: NSRect
        weak var view: NSView?

        static func == (lhs: Hit, rhs: Hit) -> Bool {
            lhs.text == rhs.text && lhs.view === rhs.view && lhs.region == rhs.region && abs(lhs.scale - rhs.scale) < 0.001
        }
    }

    private(set) var panel: NSPanel?
    private(set) var label: NSTextField?
    private(set) var shown: Hit?
    private var pending: Hit?
    private var pendingSince: Date?
    private var hiddenAt: Date?
    private var pollTimer: Timer?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    nonisolated static func suppressSystemToolTips() {
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": Metrics.systemDelaySuppression])
    }

    func install() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel, .leftMouseDragged]
        ) { [weak self] event in
            self?.hide()
            self?.pending = nil
            return event
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startPolling() }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopPolling()
                self?.hide()
            }
        })
        observers.append(center.addObserver(forName: ContentZoomController.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        })
        if NSApp.isActive { startPolling() }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: Metrics.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pending = nil
    }

    private func poll() {
        guard NSEvent.pressedMouseButtons == 0 else {
            hide()
            pending = nil
            return
        }
        let location = NSEvent.mouseLocation
        guard let hit = hit(atScreenPoint: location) else {
            hide()
            pending = nil
            return
        }
        if hit == shown { return }
        if hit != pending {
            hide()
            pending = hit
            pendingSince = Date()
            return
        }
        let quick = hiddenAt.map { Date().timeIntervalSince($0) < Metrics.quickWindow } ?? false
        let delay = quick ? Metrics.quickDelay : Metrics.initialDelay
        guard let since = pendingSince, Date().timeIntervalSince(since) >= delay else { return }
        show(hit, atScreenPoint: location)
    }

    func hit(atScreenPoint point: NSPoint) -> Hit? {
        var number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        if let panel, panel.isVisible, number == panel.windowNumber {
            number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: panel.windowNumber)
        }
        guard let window = NSApp.window(withWindowNumber: number), window !== panel, window.isVisible else { return nil }
        return hit(in: window, atScreenPoint: point)
    }

    func hit(in window: NSWindow, atScreenPoint point: NSPoint) -> Hit? {
        guard let content = window.contentView else { return nil }
        let root = content.superview ?? content
        let windowPoint = window.convertPoint(fromScreen: point)
        guard let target = root.hitTest(root.superview?.convert(windowPoint, from: nil) ?? windowPoint) else { return nil }
        var view = deepestDescendant(of: target, containing: windowPoint)
        while true {
            if !view.isHiddenOrHasHiddenAncestor, let hit = hit(on: view, windowPoint: windowPoint) { return hit }
            guard let parent = view.superview else { return nil }
            view = parent
        }
    }

    private func deepestDescendant(of view: NSView, containing windowPoint: NSPoint) -> NSView {
        var current = view
        while let child = current.subviews.reversed().first(where: {
            !$0.isHidden && $0.alphaValue > 0 && $0.bounds.contains($0.convert(windowPoint, from: nil))
        }) {
            current = child
        }
        return current
    }

    private func hit(on view: NSView, windowPoint: NSPoint) -> Hit? {
        let local = view.convert(windowPoint, from: nil)
        let scale = ContentZoomController.displayScale(of: view)
        if let source = view as? ZoomedToolTipSource, let text = source.zoomedToolTip(at: local), !text.isEmpty {
            return Hit(text: text, scale: scale, region: view.bounds, view: view)
        }
        if let segmented = view as? NSSegmentedControl, let segment = segmentIndex(in: segmented, at: local),
           let text = segmented.toolTip(forSegment: segment), !text.isEmpty {
            return Hit(text: text, scale: scale, region: NSRect(x: CGFloat(segment), y: 0, width: 0, height: 0), view: view)
        }
        if let text = view.toolTip, !text.isEmpty {
            return Hit(text: text, scale: scale, region: view.bounds, view: view)
        }
        return nil
    }

    private func segmentIndex(in control: NSSegmentedControl, at point: NSPoint) -> Int? {
        guard control.segmentCount > 0, control.bounds.contains(point) else { return nil }
        let widths = (0..<control.segmentCount).map { control.width(forSegment: $0) }
        let fixed = widths.filter { $0 > 0 }.reduce(0, +)
        let automatic = widths.filter { $0 <= 0 }.count
        let share = automatic > 0 ? max(0, control.bounds.width - fixed) / CGFloat(automatic) : 0
        var edge: CGFloat = 0
        let x = control.userInterfaceLayoutDirection == .rightToLeft ? control.bounds.width - point.x : point.x
        for (index, width) in widths.enumerated() {
            edge += width > 0 ? width : share
            if x < edge { return index }
        }
        return control.segmentCount - 1
    }

    func show(_ hit: Hit, atScreenPoint point: NSPoint) {
        let panel = self.panel ?? makePanel()
        guard let label else { return }
        let scale = max(hit.scale, 0.1)
        label.font = NSFont.toolTipsFont(ofSize: Metrics.baseFontSize * scale)
        label.stringValue = hit.text
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let padding = NSSize(width: Metrics.horizontalPadding * scale, height: Metrics.verticalPadding * scale)
        let widthLimit = min(Metrics.maximumWidth * scale, visible.width - 2 * Metrics.screenMargin) - 2 * padding.width
        label.preferredMaxLayoutWidth = widthLimit
        let measured = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: widthLimit, height: .greatestFiniteMagnitude)) ?? .zero
        let size = NSSize(width: ceil(min(measured.width, widthLimit) + 2 * padding.width), height: ceil(measured.height + 2 * padding.height))
        var origin = NSPoint(x: point.x, y: point.y - Metrics.cursorOffset - size.height)
        origin.x = min(max(origin.x, visible.minX + Metrics.screenMargin), visible.maxX - Metrics.screenMargin - size.width)
        if origin.y < visible.minY + Metrics.screenMargin { origin.y = point.y + Metrics.cursorOffset / 2 }
        origin.y = min(origin.y, visible.maxY - Metrics.screenMargin - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        label.frame = NSRect(x: padding.width, y: padding.height, width: size.width - 2 * padding.width, height: size.height - 2 * padding.height)
        panel.orderFront(nil)
        shown = hit
        pending = nil
    }

    func hide() {
        guard shown != nil else { return }
        panel?.orderOut(nil)
        shown = nil
        hiddenAt = Date()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 5
        background.layer?.masksToBounds = true
        panel.contentView = background
        let label = NSTextField(wrappingLabelWithString: "")
        label.textColor = .labelColor
        label.isSelectable = false
        label.setAccessibilityElement(false)
        background.addSubview(label)
        self.panel = panel
        self.label = label
        return panel
    }
}
