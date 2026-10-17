import AppKit

@MainActor
final class SplitterManager {
    typealias FixedPanel = RetainingSplitViewController.ResizeBehavior

    private final class Splitter: @unchecked Sendable {
        let view: NSSplitView
        let name: String
        let fixedPanel: FixedPanel
        let defaultDistance: CGFloat?
        let minimum1: CGFloat
        let minimum2: CGFloat
        var fixedPanelSize: CGFloat?
        var applying = false
        var observer: NSObjectProtocol?

        init(view: NSSplitView, name: String, fixedPanel: FixedPanel, defaultDistance: CGFloat?, minimum1: CGFloat, minimum2: CGFloat) {
            self.view = view
            self.name = name
            self.fixedPanel = fixedPanel
            self.defaultDistance = defaultDistance
            self.minimum1 = minimum1
            self.minimum2 = minimum2
        }
    }

    private let settingsPath: String
    private let store: AppSettingsStore
    private var splitters: [Splitter] = []

    init(settingsPath: String, store: AppSettingsStore? = nil) {
        self.settingsPath = settingsPath
        self.store = store ?? .shared
    }

    func addSplitter(_ view: NSSplitView, name: String, fixedPanel: FixedPanel, defaultDistance: CGFloat? = nil, panel1MinSize: CGFloat = 25, panel2MinSize: CGFloat = 25) {
        let splitter = Splitter(view: view, name: name, fixedPanel: fixedPanel, defaultDistance: defaultDistance, minimum1: panel1MinSize, minimum2: panel2MinSize)
        splitters.append(splitter)
        Self.applyFixedPanel(fixedPanel, to: view)
        guard fixedPanel != .proportional else { return }
        splitter.observer = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: view, queue: .main) { [weak splitter] notification in
            let userDragged = notification.userInfo?["NSSplitViewDividerIndex"] != nil
            MainActor.assumeIsolated {
                guard let splitter else { return }
                Self.resized(splitter, userDragged: userDragged)
            }
        }
    }

    deinit {
        for splitter in splitters { if let observer = splitter.observer { NotificationCenter.default.removeObserver(observer) } }
    }

    static func fixedPanelSize(of view: NSSplitView, fixedPanel: FixedPanel) -> CGFloat? {
        switch fixedPanel {
        case .proportional: return nil
        case .fixedLeadingPane: return distance(of: view)
        case .fixedTrailingPane: return size(of: view) - distance(of: view) - view.dividerThickness
        }
    }

    static func positionRestoringFixedPanel(_ fixedSize: CGFloat, size: CGFloat, divider: CGFloat, fixedPanel: FixedPanel) -> CGFloat? {
        switch fixedPanel {
        case .proportional: return nil
        case .fixedLeadingPane: return fixedSize
        case .fixedTrailingPane: return size - divider - fixedSize
        }
    }

    private static func resized(_ splitter: Splitter, userDragged: Bool) {
        guard !splitter.applying, size(of: splitter.view) > 0, let current = fixedPanelSize(of: splitter.view, fixedPanel: splitter.fixedPanel) else { return }
        guard !userDragged, let wanted = splitter.fixedPanelSize else {
            splitter.fixedPanelSize = current
            return
        }
        guard current < wanted - 0.5,
              let position = positionRestoringFixedPanel(wanted, size: size(of: splitter.view), divider: splitter.view.dividerThickness, fixedPanel: splitter.fixedPanel) else { return }
        splitter.applying = true
        splitter.view.setPosition(position, ofDividerAt: 0)
        splitter.applying = false
    }

    private func setPosition(_ position: CGFloat, for splitter: Splitter) {
        splitter.applying = true
        splitter.view.setPosition(position, ofDividerAt: 0)
        splitter.applying = false
        splitter.fixedPanelSize = Self.fixedPanelSize(of: splitter.view, fixedPanel: splitter.fixedPanel)
    }

    static func applyFixedPanel(_ fixedPanel: FixedPanel, to view: NSSplitView) {
        guard view.arrangedSubviews.count == 2 else { return }
        switch fixedPanel {
        case .proportional:
            view.setHoldingPriority(.defaultLow, forSubviewAt: 0)
            view.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        case .fixedLeadingPane:
            view.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
            view.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        case .fixedTrailingPane:
            view.setHoldingPriority(.defaultLow, forSubviewAt: 0)
            view.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        }
    }

    static func size(of view: NSSplitView) -> CGFloat { view.isVertical ? view.bounds.width : view.bounds.height }

    static func distance(of view: NSSplitView) -> CGFloat {
        guard let first = view.arrangedSubviews.first else { return 0 }
        return view.isVertical ? first.frame.width : first.frame.height
    }

    static func restoredDistance(saved: SplitterSetting?, size: CGFloat, fixedPanel: FixedPanel) -> CGFloat? {
        BrowserLayoutPreferences.restoredDistance(saved, size: Double(size), fixed: fixedPanel).map { CGFloat($0) }
    }

    func restoreSplitters() {
        for splitter in splitters {
            let size = Self.size(of: splitter.view)
            guard size > 0 else { continue }
            let saved = store.splitterSetting(key(splitter))
            let valid: (CGFloat) -> Bool = { $0 > splitter.minimum1 && $0 < size - splitter.minimum2 - splitter.view.dividerThickness }
            if let distance = Self.restoredDistance(saved: saved, size: size, fixedPanel: splitter.fixedPanel) {
                if valid(distance) {
                    setPosition(distance, for: splitter)
                } else if let fallback = splitter.defaultDistance, valid(fallback) {
                    setPosition(fallback, for: splitter)
                }
            } else if saved == nil, let fallback = splitter.defaultDistance, valid(fallback) {
                setPosition(fallback, for: splitter)
            }
            if splitter.fixedPanelSize == nil { splitter.fixedPanelSize = Self.fixedPanelSize(of: splitter.view, fixedPanel: splitter.fixedPanel) }
        }
    }

    func saveSplitters() {
        for splitter in splitters where Self.size(of: splitter.view) > 0 {
            store.saveSplitterSetting(SplitterSetting(distance: Self.distance(of: splitter.view), size: Self.size(of: splitter.view)), for: key(splitter))
        }
    }

    private func key(_ splitter: Splitter) -> String { settingsPath + "." + splitter.name }
}
