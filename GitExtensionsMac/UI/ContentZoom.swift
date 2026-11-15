import AppKit
import Combine

/// Root view used when a dialog is wrapped for zoom. Code that sizes a dialog
/// from its controller's view still measures the dialog's own content in
/// design (100%) points: the fitting size is the wrapped content's, falling
/// back to the natural size for frame-based content.
private final class ContentZoomWrapperView: NSView {
    var naturalSize = CGSize.zero
    weak var content: NSView?
    override var fittingSize: NSSize {
        guard let size = content?.fittingSize, size.width > 1, size.height > 1 else { return naturalSize }
        return size
    }
    override var intrinsicContentSize: NSSize { naturalSize }
}

/// Application-wide zoom for the repository window.
///
/// The whole window content lives in an `NSScrollView`. Its document view is
/// laid out at `viewport / level` and the scroll view magnifies it back to the
/// viewport, so Auto Layout reflows the entire UI — toolbar, repository tree,
/// revision grid, diff, tabs and status bar — instead of only magnifying
/// pixels. The document view is resized and laid out again on every zoom
/// change, so content fills the window immediately without a manual resize.
///
/// Panes in secondary windows (file viewer, blame, impact graph and other
/// dialogs) zoom with their own `NSScrollView` magnification, because those
/// windows are sized to fixed frames and would otherwise clip.
///
/// The factor is persisted in `AppSettingsStore` and restored at launch.
@MainActor
final class ContentZoomController: ObservableObject {

    static let shared = ContentZoomController()

    /// Posted after the factor was persisted and applied to the zoom hosts.
    static let didChangeNotification = Notification.Name("GitExtensionsMac.contentZoomDidChange")

    enum Metrics {
        /// Discrete steps used by the Zoom In/Out commands, from 75% to 150%.
        /// Pinch gestures move continuously inside the same bounds.
        static let levels: [CGFloat] = [0.75, 1.0, 1.25, 1.5]
        static let minimum: CGFloat = levels[0]
        static let maximum: CGFloat = levels[levels.count - 1]
        static let identity: CGFloat = 1
    }

    /// The current zoom factor, clamped to `Metrics.minimum...Metrics.maximum`.
    /// Pinch gestures store continuous values; the View menu commands move
    /// between the discrete `Metrics.levels` steps.
    @Published private(set) var level: CGFloat

    private struct WeakBox<T: AnyObject> {
        weak var value: T?
    }


    private struct WrappedWindow {
        weak var window: NSWindow?
        weak var scrollView: NSScrollView?
        var naturalSize: CGSize
        /// The dialog's own size limits at 100%; they scale with the zoom so a
        /// dialog that pins its height or width can still grow.
        var minSize: CGSize
        var maxSize: CGSize
        /// The limits last written to the window, to notice when the dialog
        /// sets new ones (in design points) itself.
        var appliedMinSize: CGSize = .zero
        var appliedMaxSize: CGSize = .zero
        var hasAppliedLimits = false
    }

    private let store: AppSettingsStore
    private var contentScrollViews: [ObjectIdentifier: WeakBox<NSScrollView>] = [:]
    private var panes: [ObjectIdentifier: WeakBox<NSScrollView>] = [:]
    private var wrappedWindows: [ObjectIdentifier: WrappedWindow] = [:]
    private var wrappedScrollMap: [ObjectIdentifier: ObjectIdentifier] = [:]
    private var wrappedAutosaveNames: [ObjectIdentifier: String] = [:]
    private var resizingWrappedWindows = false
    private var frameObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private var observers: [NSObjectProtocol] = []

    init(store: AppSettingsStore = .shared) {
        self.store = store
        level = Self.clamped(CGFloat(store.contentZoomLevel))
        observeNotifications()
        observePresentedWindows()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        frameObservers.values.forEach(NotificationCenter.default.removeObserver)
    }

    /// The zoom factor as a whole percentage, e.g. `125`.
    var percent: Int { Int((level * 100).rounded()) }

    var canZoomIn: Bool { level < Metrics.maximum - 0.0001 }
    var canZoomOut: Bool { level > Metrics.minimum + 0.0001 }
    var isActualSize: Bool { abs(level - Metrics.identity) <= 0.0001 }

    /// Number of windows whose content scroll view is currently zoomed.
    var zoomedContentScrollViewCount: Int {
        pruneReleasedContentScrollViews()
        return contentScrollViews.count
    }

    /// Number of secondary-window panes currently registered for zoom.
    var zoomablePaneCount: Int {
        pruneReleasedPanes()
        return panes.count
    }

    /// Moves up to the next discrete zoom step, or to the maximum.
    func zoomIn() { step(forward: true) }

    /// Moves down to the previous discrete zoom step, or to the minimum.
    func zoomOut() { step(forward: false) }

    /// Restores the 100% factor.
    func resetZoom() { setLevel(Metrics.identity) }

    /// Sets the zoom factor, clamped, persists it and applies it to every zoom
    /// host and pane.
    func setLevel(_ newLevel: CGFloat) {
        applyLevel(Self.clamped(newLevel), persist: true)
    }

    /// Number of dialogs, forms, panels and sheets that follow the zoom.
    var zoomedDialogWindowCount: Int {
        pruneReleasedWrappedWindows()
        return wrappedWindows.count
    }

    // MARK: - Whole-window zoom

    /// Registers the repository window's content scroll view. The scroll view's
    /// document view must hold the entire window content and lay it out with
    /// Auto Layout. Call it when the content view appears; registration is
    /// idempotent and weakly held.
    func registerContentScrollView(_ scrollView: NSScrollView) {
        pruneReleasedContentScrollViews()
        guard contentScrollViews[ObjectIdentifier(scrollView)]?.value !== scrollView else {
            applyZoom(toContent: scrollView)
            updateMinimumSize(ofContentWindow: scrollView)
            return
        }
        contentScrollViews[ObjectIdentifier(scrollView)] = WeakBox(value: scrollView)
        configureContentScrollView(scrollView)
        observeFrame(of: scrollView)
        applyZoom(toContent: scrollView)
        updateMinimumSize(ofContentWindow: scrollView)
        // Panes inside the zoomed window must not magnify themselves on top.
        applyZoomToRegisteredPanes()
        // The scroll view can still be unsized when the view first appears.
        DispatchQueue.main.async { [weak self, weak scrollView] in
            MainActor.assumeIsolated {
                guard let self, let scrollView else { return }
                self.applyZoom(toContent: scrollView)
            }
        }
    }

    /// Makes a presented window — dialog, form, panel or sheet — follow the
    /// zoom factor. The window's content is moved into a magnifying scroll view
    /// while its content view controller identity is preserved. Registration is
    /// idempotent and weakly held.
    func zoomWindow(_ window: NSWindow) {
        pruneReleasedWrappedWindows()
        // A reused dialog that installed new content dropped the zoom wrapper;
        // forget the stale registration so the new content is wrapped again.
        let key = ObjectIdentifier(window)
        if let entry = wrappedWindows[key], entry.scrollView?.superview == nil || entry.scrollView?.superview !== window.contentView {
            if let name = wrappedAutosaveNames.removeValue(forKey: key), !name.isEmpty { window.setFrameAutosaveName(name) }
            window.contentMinSize = entry.minSize
            window.contentMaxSize = entry.maxSize
            // Unless the dialog sized the window for its new content, it still
            // has the zoomed size; start again from the design size.
            let scale = max(effectiveLevel(for: entry), Metrics.identity)
            let current = window.contentLayoutRect.size
            if scale > Metrics.identity,
               abs(current.width - entry.naturalSize.width * scale) < 2, abs(current.height - entry.naturalSize.height * scale) < 2 {
                resizingWrappedWindows = true
                setWindowContentSize(window, entry.naturalSize)
                resizingWrappedWindows = false
            }
            if let scrollView = entry.scrollView { wrappedScrollMap.removeValue(forKey: ObjectIdentifier(scrollView)) }
            wrappedWindows.removeValue(forKey: key)
        }
        guard isEligibleForZoom(window), let content = window.contentView else { return }
        let contentSize = window.contentLayoutRect.size
        guard contentSize.width > 1, contentSize.height > 1 else { return }

        // Moving the content out of the window resigns its first responder;
        // remember it so the dialog keeps the focus it set up.
        let focusedView: NSView? = {
            guard let responder = window.firstResponder as? NSView else { return nil }
            if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView { return field }
            return responder.isDescendant(of: content) ? responder : nil
        }()
        let scrollView = makeContentScrollView()
        let root = ContentZoomWrapperView(frame: NSRect(origin: .zero, size: contentSize))
        root.naturalSize = contentSize
        root.content = content
        scrollView.frame = root.bounds
        scrollView.autoresizingMask = [.width, .height]
        // Keep the original content in a frame-managed container: Auto Layout
        // then reflows inside it without fighting the document view's frame.
        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        content.frame = container.bounds
        container.addSubview(content)
        scrollView.documentView = container
        root.addSubview(scrollView)
        if let controller = window.contentViewController {
            // Keep the controller as the window's content view controller while
            // handing its view to the zoom wrapper.
            controller.view = root
        }
        window.contentView = root
        if let focusedView, focusedView.window === window, window.firstResponder !== focusedView {
            window.makeFirstResponder(focusedView)
        }

        wrappedWindows[ObjectIdentifier(window)] = WrappedWindow(
            window: window, scrollView: scrollView, naturalSize: contentSize,
            minSize: window.contentMinSize, maxSize: window.contentMaxSize)
        wrappedScrollMap[ObjectIdentifier(scrollView)] = ObjectIdentifier(window)
        observeFrame(of: scrollView)
        applyZoomToRegisteredWrappedWindows()
        // Panes inside the dialog must not magnify themselves on top of it.
        applyZoomToRegisteredPanes()
    }

    private func isEligibleForZoom(_ window: NSWindow) -> Bool {
        guard wrappedWindows[ObjectIdentifier(window)] == nil else { return false }
        guard window.styleMask.contains(.titled), !window.styleMask.contains(.fullScreen) else { return false }
        guard !isContentWindow(window) else { return false }
        guard let content = window.contentView, content.frame.width > 1, content.frame.height > 1 else { return false }
        guard !(content is NSScrollView) else { return false }
        // The SwiftUI-hosted repository window is handled by
        // `registerContentScrollView`; never wrap it like a dialog.
        // Match SwiftUI's generic hosting types only, not app classes that
        // merely mention hosting (e.g. the repository-hosting process dialog).
        if let controller = window.contentViewController,
           String(describing: type(of: controller)).hasPrefix("NSHostingController<") { return false }
        if String(describing: type(of: content)).contains("HostingView<") { return false }
        // Leave system panels and alerts to AppKit.
        if window is NSSavePanel || window is NSColorPanel || window is NSFontPanel { return false }
        // Alerts are dialogs too (several carry form fields, such as Create
        // tag), so they follow the zoom once AppKit has laid them out. Other
        // private AppKit windows, such as the glass backdrop drawn behind a
        // sheet, mirror another window and must never be re-parented.
        let windowName = String(describing: type(of: window))
        if windowName.hasPrefix("_") && !windowName.contains("AlertPanel") { return false }
        guard window.canBecomeKey else { return false }
        return true
    }

    private func isContentWindow(_ window: NSWindow) -> Bool {
        pruneReleasedContentScrollViews()
        for box in contentScrollViews.values where box.value?.window === window { return true }
        return false
    }

    private func applyZoomToRegisteredWrappedWindows() {
        pruneReleasedWrappedWindows()
        let entries = wrappedWindows
        for (key, entry) in entries {
            guard let window = entry.window else { continue }
            if level == Metrics.identity {
                // Back at 100%: let the window persist its natural geometry again.
                if let name = wrappedAutosaveNames.removeValue(forKey: key), !name.isEmpty {
                    window.setFrameAutosaveName(name)
                }
            } else if wrappedAutosaveNames[key] == nil, !window.frameAutosaveName.isEmpty {
                // While zoomed the frame is scaled; never autosave that.
                wrappedAutosaveNames[key] = window.frameAutosaveName
                window.setFrameAutosaveName("")
            }
            applyZoom(toWrappedWindow: entry)
        }
    }

    /// Sizes the dialog by the zoom factor (so its natural layout keeps its
    /// proportions) and lays the content out at viewport / zoom.
    private func applyZoom(toWrappedWindow original: WrappedWindow) {
        guard let window = original.window, let scrollView = original.scrollView else { return }
        var entry = original
        let magnification = effectiveLevel(for: entry)
        let scale = max(magnification, Metrics.identity)
        scaleSizeLimits(of: window, entry: &entry, by: scale)
        wrappedWindows[ObjectIdentifier(window)] = entry
        let target = CGSize(width: (entry.naturalSize.width * scale).rounded(), height: (entry.naturalSize.height * scale).rounded())
        if abs(window.contentLayoutRect.width - target.width) > 0.5 || abs(window.contentLayoutRect.height - target.height) > 0.5 {
            resizingWrappedWindows = true
            setWindowContentSize(window, target)
            resizingWrappedWindows = false
        }
        applyZoom(toContent: scrollView, magnification: magnification)
    }

    private func scaleSizeLimits(of window: NSWindow, entry: inout WrappedWindow, by scale: CGFloat) {
        func scaled(_ size: CGSize) -> CGSize {
            // `contentMaxSize` is "unlimited" as a huge value; leave that alone.
            CGSize(width: size.width >= 10_000 ? size.width : size.width * scale,
                   height: size.height >= 10_000 ? size.height : size.height * scale)
        }
        func differs(_ a: CGSize, _ b: CGSize) -> Bool { abs(a.width - b.width) > 0.5 || abs(a.height - b.height) > 0.5 }
        // Limits the dialog wrote itself are design sizes.
        if entry.hasAppliedLimits {
            if differs(window.contentMinSize, entry.appliedMinSize) { entry.minSize = window.contentMinSize }
            if differs(window.contentMaxSize, entry.appliedMaxSize) { entry.maxSize = window.contentMaxSize }
        }
        // The natural size always satisfies the dialog's own minimum.
        entry.naturalSize = CGSize(width: max(entry.naturalSize.width, entry.minSize.width),
                                   height: max(entry.naturalSize.height, entry.minSize.height))
        entry.appliedMinSize = scaled(entry.minSize)
        entry.appliedMaxSize = scaled(entry.maxSize)
        entry.hasAppliedLimits = true
        window.contentMinSize = entry.appliedMinSize
        window.contentMaxSize = entry.appliedMaxSize
    }

    /// Call after a dialog changed its own size limits or preferred size, in
    /// design points, without resizing its window.
    func dialogGeometryDidChange(_ window: NSWindow) {
        guard let entry = wrappedWindows[ObjectIdentifier(window)] else { return }
        applyZoom(toWrappedWindow: entry)
    }

    /// How much a dialog's content is magnified on screen: 1 for windows that
    /// do not follow the zoom. Dialogs that fix part of their own geometry use
    /// it to scale their design sizes.
    func windowScale(_ window: NSWindow) -> CGFloat {
        guard let entry = wrappedWindows[ObjectIdentifier(window)] else { return 1 }
        return max(effectiveLevel(for: entry), Metrics.identity)
    }

    /// The magnification a dialog actually uses. Above 100% a dialog grows with
    /// the zoom, but never past the screen: when the grown window would not
    /// fit, it magnifies only as far as its design size fits, so its layout is
    /// never squeezed below the size it was designed for.
    private func effectiveLevel(for entry: WrappedWindow) -> CGFloat {
        guard level > Metrics.identity, let window = entry.window,
              entry.naturalSize.width > 1, entry.naturalSize.height > 1 else { return level }
        let desired = CGSize(width: entry.naturalSize.width * level, height: entry.naturalSize.height * level)
        let available = cappedContentSize(desired, for: window)
        let fit = min(available.width / entry.naturalSize.width, available.height / entry.naturalSize.height)
        return max(Metrics.identity, min(level, fit))
    }

    private func effectiveLevel(for scrollView: NSScrollView) -> CGFloat {
        guard let key = wrappedScrollMap[ObjectIdentifier(scrollView)], let entry = wrappedWindows[key] else { return level }
        return effectiveLevel(for: entry)
    }

    /// The repository window keeps its frame, but dialogs grow with the zoom so
    /// their fixed layouts are never clipped.
    private func cappedContentSize(_ size: CGSize, for window: NSWindow) -> CGSize {
        guard let screen = window.screen ?? NSScreen.main else { return size }
        let frame = window.frame
        let content = window.contentLayoutRect
        let chrome = CGSize(width: frame.width - content.width, height: frame.height - content.height)
        let visible = screen.visibleFrame
        return CGSize(
            width: min(size.width, max(80, visible.width - chrome.width)),
            height: min(size.height, max(80, visible.height - chrome.height))
        )
    }

    private func setWindowContentSize(_ window: NSWindow, _ size: CGSize) {
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setContentSize(size)
        if !window.isSheet {
            window.setFrameOrigin(NSPoint(x: topLeft.x, y: topLeft.y - window.frame.height))
        }
    }

    private func makeContentScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        configureContentScrollView(scrollView)
        return scrollView
    }

    private func configureContentScrollView(_ scrollView: NSScrollView) {
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.minMagnification = Metrics.minimum
        scrollView.maxMagnification = Metrics.maximum
        scrollView.allowsMagnification = true
    }

    // MARK: - Secondary-window panes

    /// Makes a secondary-window pane zoomable and aligns it with the current
    /// factor. Safe to call more than once; panes are weakly referenced.
    func register(_ scrollView: NSScrollView) {
        pruneReleasedPanes()
        panes[ObjectIdentifier(scrollView)] = WeakBox(value: scrollView)
        applyZoom(toPane: scrollView)
        // Controllers register their scroll views from `loadView`, before the
        // view is attached to its window. Re-evaluate once that has happened so
        // a pane inside the zoomed window is not magnified twice.
        DispatchQueue.main.async { [weak self, weak scrollView] in
            MainActor.assumeIsolated {
                guard let self, let scrollView else { return }
                self.applyZoom(toPane: scrollView)
            }
        }
    }

    /// Stops applying zoom to a pane, e.g. after it left its window.
    func unregister(_ scrollView: NSScrollView) {
        panes.removeValue(forKey: ObjectIdentifier(scrollView))
    }

    /// Converts a size measured while zoomed back to the 100% design size, for
    /// dialogs that persist their window geometry.
    /// Pass the dialog's window so a dialog that zooms less than the factor,
    /// because it would not fit the screen, is converted by its own scale.
    func unzoomed(_ size: NSSize, in window: NSWindow? = nil) -> NSSize {
        var scale = max(level, Metrics.identity)
        if let window {
            // A window that does not follow the zoom is already at design size.
            scale = wrappedWindows[ObjectIdentifier(window)].map { max(effectiveLevel(for: $0), Metrics.identity) } ?? Metrics.identity
        }
        return NSSize(width: size.width / scale, height: size.height / scale)
    }

    /// How much a view is magnified on screen by the zoom of its window, e.g.
    /// `1.5` for a toolbar button in the repository window at 150%.
    nonisolated static func displayScale(of view: NSView) -> CGFloat {
        guard view.window != nil else { return 1 }
        let unit = view.convert(NSSize(width: 1, height: 1), to: nil)
        return abs(unit.width) > 0.001 ? abs(unit.width) : 1
    }

    /// Wraps fixed-size content, such as a popover's, so it is shown magnified
    /// by `scale`. The returned view has the magnified size.
    nonisolated static func magnifiedContent(_ content: NSView, scale: CGFloat) -> NSView {
        let natural = content.frame.size
        let size = NSSize(width: ceil(natural.width * scale), height: ceil(natural.height * scale))
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.minMagnification = min(scale, Metrics.minimum)
        scrollView.maxMagnification = max(scale, Metrics.maximum)
        scrollView.documentView = content
        scrollView.magnification = scale
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: content.isFlipped ? 0 : max(0, natural.height - scrollView.contentView.bounds.height)))
        return scrollView
    }

    /// Clamps a factor to the supported range. Invalid values fall back to 100%.
    static func clamped(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return Metrics.identity }
        return min(Metrics.maximum, max(Metrics.minimum, value))
    }

    // MARK: - Appliers

    private func applyLevel(_ value: CGFloat, persist: Bool) {
        guard abs(value - level) > 0.0001 else { return }
        level = value
        if persist { store.contentZoomLevel = Double(value) }
        wrapVisibleWindows()
        applyZoomToRegisteredContentScrollViews()
        for box in contentScrollViews.values { if let scrollView = box.value { updateMinimumSize(ofContentWindow: scrollView) } }
        applyZoomToRegisteredWrappedWindows()
        applyZoomToRegisteredPanes()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func applyZoomToRegisteredContentScrollViews() {
        pruneReleasedContentScrollViews()
        for box in contentScrollViews.values {
            guard let scrollView = box.value else { continue }
            applyZoom(toContent: scrollView)
        }
    }

    /// The window content is laid out in a frame-managed document view, so its
    /// Auto Layout minimum no longer reaches the window. Keep the window's
    /// minimum content size at the content's minimum, magnified.
    private func updateMinimumSize(ofContentWindow scrollView: NSScrollView) {
        guard let window = scrollView.window, let document = scrollView.documentView else { return }
        let minimum = document.subviews.reduce(CGSize.zero) { result, view in
            let size = view.fittingSize
            return CGSize(width: max(result.width, size.width), height: max(result.height, size.height))
        }
        guard minimum.width > 1, minimum.height > 1 else { return }
        var size = CGSize(width: ceil(minimum.width * level), height: ceil(minimum.height * level))
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size {
            size = CGSize(width: min(size.width, visible.width * 0.9), height: min(size.height, visible.height * 0.9))
        }
        window.contentMinSize = size
    }

    private func applyZoom(toContent scrollView: NSScrollView) {
        applyZoom(toContent: scrollView, magnification: effectiveLevel(for: scrollView))
    }

    private func applyZoom(toContent scrollView: NSScrollView, magnification level: CGFloat) {
        scrollView.minMagnification = Metrics.minimum
        scrollView.maxMagnification = Metrics.maximum
        scrollView.allowsMagnification = true
        guard let document = scrollView.documentView else { return }
        let viewport = scrollView.contentSize
        guard viewport.width > 1, viewport.height > 1 else { return }

        let target = NSSize(width: viewport.width / level, height: viewport.height / level)
        if abs(document.frame.width - target.width) > 0.5 || abs(document.frame.height - target.height) > 0.5 {
            document.setFrameSize(target)
            // Auto Layout sizes subviews from their superview's frame. Marking
            // the clip view dirty re-solves the constraints for the new frame
            // immediately, instead of only after the user resizes the window.
            scrollView.contentView.needsLayout = true
            scrollView.contentView.layoutSubtreeIfNeeded()
        }

        if abs(scrollView.magnification - level) > 0.0001 {
            let anchor = NSPoint(x: 0, y: document.isFlipped ? 0 : document.bounds.maxY)
            scrollView.setMagnification(level, centeredAt: anchor)
        }
        // The document always fits the viewport; keep the visible origin at the
        // top-left corner instead of wherever the magnification anchored it.
        let clipView = scrollView.contentView
        let origin = NSPoint(x: 0, y: document.isFlipped ? 0 : max(0, document.frame.height - clipView.bounds.height))
        if abs(clipView.bounds.minX - origin.x) > 0.5 || abs(clipView.bounds.minY - origin.y) > 0.5 {
            clipView.scroll(to: origin)
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    private func applyZoomToRegisteredPanes() {
        pruneReleasedPanes()
        for box in panes.values {
            guard let scrollView = box.value else { continue }
            applyZoom(toPane: scrollView)
        }
    }

    private func applyZoom(toPane scrollView: NSScrollView) {
        // Panes inside the zoomed window must stay at 100% so the window zoom
        // is not applied twice.
        // Every window now follows the zoom as a whole, so a pane only zooms
        // itself in a window that does not. A pane not in a window yet stays at
        // 100%: it may be attached to the zoomed window later without any
        // notification, and must not be magnified twice there.
        let zoomedByContent = scrollView.window == nil || isInsideZoomedContent(scrollView)
        scrollView.minMagnification = Metrics.minimum
        scrollView.maxMagnification = Metrics.maximum
        scrollView.allowsMagnification = !zoomedByContent
        let target: CGFloat = zoomedByContent ? Metrics.identity : level
        guard abs(scrollView.magnification - target) > 0.0001 else { return }
        let clipView = scrollView.contentView
        scrollView.setMagnification(target, centeredAt: NSPoint(x: clipView.bounds.midX, y: clipView.bounds.midY))
    }

    private func isInsideZoomedContent(_ pane: NSScrollView) -> Bool {
        pruneReleasedContentScrollViews()
        guard pane.window != nil else { return false }
        for box in contentScrollViews.values {
            guard let scrollView = box.value, let document = scrollView.documentView else { continue }
            if pane.isDescendant(of: document) { return true }
        }
        for entry in wrappedWindows.values {
            guard let document = entry.scrollView?.documentView else { continue }
            if pane.isDescendant(of: document) { return true }
        }
        return false
    }

    // MARK: - Observation

    private func observeFrame(of scrollView: NSScrollView) {
        let key = ObjectIdentifier(scrollView)
        guard frameObservers[key] == nil else { return }
        scrollView.postsFrameChangedNotifications = true
        frameObservers[key] = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView,
            queue: .main
        ) { [weak self, weak scrollView] _ in
            MainActor.assumeIsolated {
                guard let self, let scrollView else { return }
                self.applyZoom(toContent: scrollView)
            }
        }
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        // Pinching a zoom host or a secondary-window pane adopts the resulting
        // magnification as the shared factor.
        observers.append(center.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let scrollView = notification.object as? NSScrollView else { return }
                self.pruneReleasedPanes()
                self.pruneReleasedContentScrollViews()
                let key = ObjectIdentifier(scrollView)
                let isHost = self.contentScrollViews[key]?.value === scrollView
                let isPane = self.panes[key]?.value === scrollView
                let isDialog = self.wrappedScrollMap[key] != nil
                guard isHost || isPane || isDialog else { return }
                let value = Self.clamped(scrollView.magnification)
                guard abs(value - self.level) > 0.0001 else { return }
                self.applyLevel(value, persist: true)
            }
        })
        // Window resizes change the viewport; keep the document view in step.
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyZoomToRegisteredContentScrollViews()
                guard !self.resizingWrappedWindows, let window = notification.object as? NSWindow,
                      let key = self.wrappedWindows.first(where: { $0.value.window === window })?.key,
                      var entry = self.wrappedWindows[key] else { return }
                let scale = max(self.effectiveLevel(for: entry), Metrics.identity)
                let size = window.contentLayoutRect.size
                if window.inLiveResize || scale <= Metrics.identity {
                    // The user resized the zoomed dialog: that defines a new
                    // natural size.
                    let natural = CGSize(width: size.width / scale, height: size.height / scale)
                    if abs(natural.width - entry.naturalSize.width) > 1 || abs(natural.height - entry.naturalSize.height) > 1 {
                        entry.naturalSize = natural
                        self.wrappedWindows[key] = entry
                    }
                    if let scrollView = entry.scrollView { self.applyZoom(toContent: scrollView) }
                } else if abs(size.width - entry.naturalSize.width * scale) > 1 || abs(size.height - entry.naturalSize.height * scale) > 1 {
                    // The dialog resized itself in code, in design points (it
                    // does not know about the zoom): adopt that size and grow
                    // the window with the zoom again.
                    entry.naturalSize = size
                    self.wrappedWindows[key] = entry
                    self.applyZoom(toWrappedWindow: entry)
                }
            }
        })
    }

    /// Wraps every visible window that should follow the zoom. Used for windows
    /// that never become key (for example when the app is not active yet) and
    /// whenever the zoom changes while dialogs are open.
    private func wrapVisibleWindows() {
        guard Self.automaticWindowZoom else { return }
        guard let windows = NSApp?.windows else { return }
        for window in windows where window.isVisible {
            zoomWindow(window)
        }
    }

    /// Every presented dialog, form, panel and sheet follows the zoom setting.
    /// Only the real app enables this; test hosts create throwaway windows whose
    /// hierarchies must stay untouched.
    private func observePresentedWindows() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                // At 100% nothing needs wrapping; open dialogs are wrapped when
                // the zoom changes.
                guard let self, self.level != Metrics.identity, let window = notification.object as? NSWindow else { return }
                guard Self.automaticWindowZoom else { return }
                self.zoomWindow(window)
            }
        })
        // A window shown while the app is in the background never becomes key
        // and gets no update cycle; it still reports becoming visible.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.level != Metrics.identity, Self.automaticWindowZoom,
                      let window = notification.object as? NSWindow, window.isVisible else { return }
                self.zoomWindow(window)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.level != Metrics.identity else { return }
                self.wrapVisibleWindows()
            }
        })
    }

    private static var automaticWindowZoom: Bool {
        if let delegate = NSApp?.delegate, delegate is GitExtensionsApplicationDelegate { return true }
        let environment = ProcessInfo.processInfo.environment
        if let delegate = NSApp?.delegate, String(describing: type(of: delegate)).contains("Test") { return false }
        if environment["GITEXTENSIONS_TEST_SHOW_WINDOWS"] != nil { return false }
        if environment.keys.contains(where: { $0.hasPrefix("XCTest") }) { return false }
        return NSClassFromString("XCTestCase") == nil
    }

    // MARK: - Keyboard

    private static var keyMonitor: Any?

    /// The View menu shows Zoom In as ⌘+, but on most keyboard layouts "+" needs
    /// Shift. Accept ⌘= and ⌘+ (and the keypad's + and −) like other Mac apps.
    static func installKeyboardShortcuts() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command), flags.isDisjoint(with: [.control, .option]) else { return event }
            let keypadPlus: UInt16 = 69, keypadMinus: UInt16 = 78
            let key = event.charactersIgnoringModifiers ?? ""
            return MainActor.assumeIsolated {
                if key == "=" || key == "+" || event.keyCode == keypadPlus {
                    shared.zoomIn()
                    return nil
                }
                if event.keyCode == keypadMinus {
                    shared.zoomOut()
                    return nil
                }
                return event
            }
        }
    }

    // MARK: - Housekeeping

    private func step(forward: Bool) {
        let next: CGFloat
        if forward {
            next = Metrics.levels.first { $0 > level + 0.0001 } ?? Metrics.maximum
        } else {
            next = Metrics.levels.last { $0 < level - 0.0001 } ?? Metrics.minimum
        }
        setLevel(next)
    }

    private func pruneReleasedPanes() {
        panes = panes.filter { $0.value.value != nil }
    }

    private func pruneReleasedContentScrollViews() {
        contentScrollViews = contentScrollViews.filter { $0.value.value != nil }
        pruneFrameObservers()
    }

    private func pruneReleasedWrappedWindows() {
        for (key, entry) in wrappedWindows where entry.window == nil {
            wrappedWindows.removeValue(forKey: key)
            wrappedAutosaveNames.removeValue(forKey: key)
            if let scrollView = entry.scrollView {
                wrappedScrollMap.removeValue(forKey: ObjectIdentifier(scrollView))
            }
        }
        for (scrollKey, windowKey) in wrappedScrollMap where wrappedWindows[windowKey] == nil {
            wrappedScrollMap.removeValue(forKey: scrollKey)
        }
        pruneFrameObservers()
    }

    private func pruneFrameObservers() {
        let live = Set(contentScrollViews.keys).union(wrappedWindows.values.compactMap { $0.scrollView.map(ObjectIdentifier.init) })
        for key in frameObservers.keys where !live.contains(key) {
            if let token = frameObservers.removeValue(forKey: key) {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }
}
