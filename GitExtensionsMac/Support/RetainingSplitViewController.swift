import AppKit

class RetainingSplitViewController: NSViewController, NSSplitViewDelegate {
    enum ResizeBehavior {
        case fixedLeadingPane
        case proportional
    }

    private static let primaryLengthTolerance: CGFloat = 0.5
    private static let enclosingResizeSettleDelay: TimeInterval = 0.08

    let splitView = NSSplitView()
    private(set) var splitViewItems: [NSSplitViewItem] = []

    private let resizeBehavior: ResizeBehavior
    private var retainedPosition: CGFloat?
    private var retainedFraction: CGFloat?
    private var previousPrimaryLength: CGFloat = 0
    private var resizeSettleTimer: Timer?
    private var isApplyingRetainedPosition = false
    private var collapsedItems: Set<ObjectIdentifier> = []

    init(resizeBehavior: ResizeBehavior) {
        self.resizeBehavior = resizeBehavior
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        resizeSettleTimer?.invalidate()
    }

    override func loadView() {
        splitView.delegate = self
        splitView.autoresizingMask = [.width, .height]
        view = splitView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        previousPrimaryLength = primaryLength
    }

    func addSplitViewItem(_ item: NSSplitViewItem) {
        guard !splitViewItems.contains(where: { $0 === item }) else { return }
        splitViewItems.append(item)
        addChild(item.viewController)

        let itemView = item.viewController.view
        itemView.translatesAutoresizingMaskIntoConstraints = true
        itemView.autoresizingMask = [.width, .height]
        splitView.addSubview(itemView)
        applyHoldingPriorities()
        splitView.adjustSubviews()
        previousPrimaryLength = primaryLength
    }

    func removeSplitViewItem(_ item: NSSplitViewItem) {
        guard let index = splitViewItems.firstIndex(where: { $0 === item }) else { return }
        collapsedItems.remove(ObjectIdentifier(item))
        splitViewItems.remove(at: index)
        item.viewController.view.removeFromSuperview()
        item.viewController.removeFromParent()
        applyHoldingPriorities()
        splitView.adjustSubviews()
        previousPrimaryLength = primaryLength
    }

    func isCollapsed(_ item: NSSplitViewItem) -> Bool {
        collapsedItems.contains(ObjectIdentifier(item))
    }

    func setCollapsed(_ collapsed: Bool, for item: NSSplitViewItem) {
        guard let index = splitViewItems.firstIndex(where: { $0 === item }) else { return }
        let identifier = ObjectIdentifier(item)
        guard collapsed != collapsedItems.contains(identifier) else { return }

        if collapsed {
            if index == 0, let position = leadingPaneThickness {
                retain(position: position)
            }
            collapsedItems.insert(identifier)
            item.viewController.view.isHidden = true
        } else {
            collapsedItems.remove(identifier)
            item.viewController.view.isHidden = false
        }

        splitView.adjustSubviews()
        if !collapsed {
            restoreRetainedPosition()
        }
    }

    func setRetainedPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int = 0) {
        guard dividerIndex == 0 else { return }
        resizeSettleTimer?.invalidate()
        resizeSettleTimer = nil
        retain(position: position)
        applyRetainedPosition()
    }

    func restoreRetainedPosition() {
        scheduleRestoreAfterEnclosingResize()
    }

    private var primaryLength: CGFloat {
        splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
    }

    private var leadingPaneThickness: CGFloat? {
        guard let leadingView = splitView.arrangedSubviews.first else { return nil }
        return splitView.isVertical ? leadingView.frame.width : leadingView.frame.height
    }

    private var hasCollapsedItem: Bool {
        !collapsedItems.isEmpty
    }

    private func retain(position: CGFloat) {
        let length = primaryLength
        guard length > 0 else { return }

        switch resizeBehavior {
        case .fixedLeadingPane:
            retainedPosition = max(0, position)
        case .proportional:
            retainedFraction = min(max(position / length, 0), 1)
        }
        previousPrimaryLength = length
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        let length = primaryLength
        guard length > 0 else { return }

        let enclosingLengthChanged = previousPrimaryLength > 0
            && abs(length - previousPrimaryLength) > Self.primaryLengthTolerance
        previousPrimaryLength = length

        guard !isApplyingRetainedPosition, !hasCollapsedItem else { return }

        if currentEventIsDraggingDivider {
            resizeSettleTimer?.invalidate()
            resizeSettleTimer = nil
            if let position = leadingPaneThickness {
                retain(position: position)
            }
            return
        }

        if enclosingLengthChanged {
            scheduleRestoreAfterEnclosingResize()
        }
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex < splitViewItems.count else { return proposedMinimumPosition }
        return max(proposedMinimumPosition, splitViewItems[dividerIndex].minimumThickness)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let trailingIndex = dividerIndex + 1
        guard trailingIndex < splitViewItems.count else { return proposedMaximumPosition }
        let maximum = primaryLength - splitView.dividerThickness - splitViewItems[trailingIndex].minimumThickness
        return min(proposedMaximumPosition, max(0, maximum))
    }

    private func applyHoldingPriorities() {
        for (index, item) in splitViewItems.enumerated() {
            splitView.setHoldingPriority(item.holdingPriority, forSubviewAt: index)
        }
    }

    private var currentEventIsDraggingDivider: Bool {
        guard let event = NSApp.currentEvent,
              event.window === splitView.window,
              splitView.window?.inLiveResize != true,
              event.type == .leftMouseDown || event.type == .leftMouseDragged else { return false }
        let eventPoint = splitView.convert(event.locationInWindow, from: nil)
        return firstDividerRect.insetBy(dx: -4, dy: -4).contains(eventPoint)
    }

    private var firstDividerRect: NSRect {
        let frames = splitView.arrangedSubviews.prefix(2).map(\.frame)
        guard frames.count == 2 else { return .zero }

        if splitView.isVertical {
            let orderedFrames = frames.sorted { $0.minX < $1.minX }
            return NSRect(
                x: orderedFrames[0].maxX,
                y: splitView.bounds.minY,
                width: splitView.dividerThickness,
                height: splitView.bounds.height
            )
        }

        let orderedFrames = frames.sorted { $0.minY < $1.minY }
        return NSRect(
            x: splitView.bounds.minX,
            y: orderedFrames[0].maxY,
            width: splitView.bounds.width,
            height: splitView.dividerThickness
        )
    }

    private func scheduleRestoreAfterEnclosingResize() {
        resizeSettleTimer?.invalidate()
        let timer = Timer(timeInterval: Self.enclosingResizeSettleDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            resizeSettleTimer = nil
            if splitView.window?.inLiveResize == true {
                scheduleRestoreAfterEnclosingResize()
                return
            }
            applyRetainedPosition()
        }
        resizeSettleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func applyRetainedPosition() {
        guard splitViewItems.count > 1, !hasCollapsedItem else { return }
        let length = primaryLength
        guard length > 0 else { return }

        let requestedPosition: CGFloat
        switch resizeBehavior {
        case .fixedLeadingPane:
            guard let retainedPosition else { return }
            requestedPosition = retainedPosition
        case .proportional:
            guard let retainedFraction else { return }
            requestedPosition = length * retainedFraction
        }

        let minimumPosition = splitView.minPossiblePositionOfDivider(at: 0)
        let maximumPosition = splitView.maxPossiblePositionOfDivider(at: 0)
        guard maximumPosition >= minimumPosition else { return }
        let visiblePosition = min(max(requestedPosition, minimumPosition), maximumPosition)

        isApplyingRetainedPosition = true
        splitView.setPosition(visiblePosition, ofDividerAt: 0)
        isApplyingRetainedPosition = false
        previousPrimaryLength = primaryLength
    }
}
