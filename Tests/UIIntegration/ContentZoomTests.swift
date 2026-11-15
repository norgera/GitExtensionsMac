import AppKit
import Foundation
import SwiftUI
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("Content zoom", .serialized)
    enum ContentZoomTests {

        @Test("Discrete zoom steps") private static func testDiscreteZoomSteps() {
            withFreshController { controller, _, _ in
                #expect(abs(controller.level - ContentZoomController.Metrics.identity) < 0.0001, "fresh zoom starts at 100%")
                #expect(controller.isActualSize)
                #expect(controller.percent == 100)
                controller.zoomIn()
                #expect(abs(controller.level - 1.25) < 0.0001, "zoom in moves to the next discrete step")
                #expect(controller.percent == 125)
                #expect(controller.canZoomIn && controller.canZoomOut)
                controller.zoomOut()
                #expect(abs(controller.level - ContentZoomController.Metrics.identity) < 0.0001, "zoom out returns to 100%")
                #expect(controller.isActualSize)
                var zoomOutSteps = 0
                while controller.canZoomOut && zoomOutSteps < 20 {
                    controller.zoomOut()
                    zoomOutSteps += 1
                }
                #expect(abs(controller.level - ContentZoomController.Metrics.minimum) < 0.0001, "repeated zoom out reaches 75%")
                #expect(!controller.canZoomOut)
                #expect(controller.percent == 75)
                controller.zoomOut()
                #expect(abs(controller.level - ContentZoomController.Metrics.minimum) < 0.0001, "zoom out stops at the minimum")
                var zoomInSteps = 0
                while controller.canZoomIn && zoomInSteps < 20 {
                    controller.zoomIn()
                    zoomInSteps += 1
                }
                #expect(abs(controller.level - ContentZoomController.Metrics.maximum) < 0.0001, "repeated zoom in reaches 150%")
                #expect(!controller.canZoomIn)
                #expect(controller.percent == 150)
                controller.zoomIn()
                #expect(abs(controller.level - ContentZoomController.Metrics.maximum) < 0.0001, "zoom in stops at the maximum")
                controller.resetZoom()
                #expect(abs(controller.level - ContentZoomController.Metrics.identity) < 0.0001, "reset restores 100%")
                #expect(controller.isActualSize)
                #expect(controller.percent == 100)
            }
        }

        @Test("Zoom clamping") private static func testZoomClamping() {
            withFreshController { controller, store, _ in
                #expect(ContentZoomController.clamped(0.01) == ContentZoomController.Metrics.minimum)
                #expect(ContentZoomController.clamped(99) == ContentZoomController.Metrics.maximum)
                #expect(ContentZoomController.clamped(.nan) == ContentZoomController.Metrics.identity, "invalid values fall back to 100%")
                #expect(ContentZoomController.clamped(0) == ContentZoomController.Metrics.identity)
                #expect(ContentZoomController.clamped(-3) == ContentZoomController.Metrics.identity)
                #expect(ContentZoomController.clamped(.infinity) == ContentZoomController.Metrics.identity)
                #expect(ContentZoomController.clamped(1.25) == 1.25, "values inside the range are preserved")
                controller.setLevel(99)
                #expect(abs(controller.level - ContentZoomController.Metrics.maximum) < 0.0001, "setLevel clamps to 150%")
                #expect(store.contentZoomLevel == 1.5)
                #expect(!controller.canZoomIn)
                controller.setLevel(0.01)
                #expect(abs(controller.level - ContentZoomController.Metrics.minimum) < 0.0001, "setLevel clamps to 75%")
                #expect(!controller.canZoomOut)
            }
        }

        @Test("Zoom persistence") private static func testZoomPersistence() {
            withFreshController { controller, store, defaults in
                controller.setLevel(1.25)
                #expect(abs(controller.level - 1.25) < 0.0001)
                #expect(store.contentZoomLevel == 1.25, "the zoom factor is persisted")
                #expect(AppSettingsStore(defaults: defaults).contentZoomLevel == 1.25, "a fresh store reads the persisted factor")
                let reloaded = ContentZoomController(store: AppSettingsStore(defaults: defaults))
                #expect(abs(reloaded.level - 1.25) < 0.0001, "a new controller starts at the persisted factor")
                #expect(reloaded.percent == 125)
                #expect(!reloaded.isActualSize && reloaded.canZoomIn && reloaded.canZoomOut)
            }
        }

        @Test("Content scroll view reflows its hierarchy") private static func testContentScrollViewReflow() {
            withFreshController { controller, _, _ in
                let setup = makeContentSetup()
                defer { setup.window.close() }
                controller.setLevel(1.5)
                controller.registerContentScrollView(setup.scrollView)
                settle()
                let viewport = setup.scrollView.contentSize
                #expect(abs(setup.document.frame.width - viewport.width / 1.5) < 1, "the document lays out at viewport / zoom")
                #expect(abs(setup.document.frame.height - viewport.height / 1.5) < 1)
                #expect(abs(setup.container.frame.width - setup.document.frame.width) < 1, "Auto Layout reflows to the smaller frame")
                #expect(abs(setup.container.frame.height - setup.document.frame.height) < 1)
                let scale = setup.document.convert(NSSize(width: 100, height: 100), to: nil)
                #expect(abs(scale.width - 150) < 1, "100 points render at 150 points: the content is magnified")
                #expect(abs(scale.height - 150) < 1)
                #expect(abs(setup.scrollView.magnification - 1.5) < 0.001, "the scroll view magnifies the document back to the viewport")

                controller.setLevel(0.75)
                settle()
                #expect(abs(setup.document.frame.width - viewport.width / 0.75) < 1, "zooming out lays out a larger document")
                #expect(abs(setup.container.frame.width - setup.document.frame.width) < 1, "and reflows it to fill that document")
                let smallScale = setup.document.convert(NSSize(width: 100, height: 100), to: nil)
                #expect(abs(smallScale.width - 75) < 1, "100 points render at 75 points")

                controller.resetZoom()
                settle()
                #expect(abs(setup.document.frame.width - viewport.width) < 1, "actual size restores the natural document size")
                #expect(abs(setup.container.frame.width - setup.document.frame.width) < 1)
            }
        }

        @Test("Content scroll view reflows after a window resize") private static func testContentScrollViewResize() {
            withFreshController { controller, _, _ in
                let setup = makeContentSetup()
                defer { setup.window.close() }
                controller.setLevel(1.5)
                controller.registerContentScrollView(setup.scrollView)
                settle()
                setup.window.setFrame(NSRect(x: 0, y: 0, width: 1500, height: 1000), display: true)
                settle()
                let viewport = setup.scrollView.contentSize
                #expect(abs(setup.document.frame.width - viewport.width / 1.5) < 1, "the document follows the new viewport")
                #expect(abs(setup.container.frame.width - setup.document.frame.width) < 1, "content reflows for the new viewport")
            }
        }

        @Test("Panes inside the zoomed window are not magnified twice") private static func testContentPanesStayUnmagnified() {
            withFreshController { controller, _, _ in
                let setup = makeContentSetup()
                defer { setup.window.close() }
                let pane = makeScrollView()
                setup.container.addSubview(pane)
                controller.setLevel(1.5)
                controller.register(pane)
                settle()
                #expect(abs(pane.magnification - 1.5) < 0.001, "a pane outside the zoomed content magnifies itself")
                controller.registerContentScrollView(setup.scrollView)
                settle()
                #expect(!pane.allowsMagnification, "the window zoom owns the factor, so the pane stops magnifying")
                #expect(abs(pane.magnification - 1) < 0.001, "the pane must not apply the factor a second time")
                controller.setLevel(1.25)
                settle()
                #expect(abs(pane.magnification - 1) < 0.001, "later zoom changes never double-magnify the pane")
            }
        }

        @Test("Secondary-window pane registration") private static func testPaneRegistration() {
            withFreshController { controller, _, _ in
                let first = makeScrollView()
                let second = makeScrollView()
                controller.setLevel(1.5)
                controller.register(first)
                #expect(first.allowsMagnification)
                #expect(first.minMagnification == ContentZoomController.Metrics.minimum)
                #expect(first.maxMagnification == ContentZoomController.Metrics.maximum)
                #expect(abs(first.magnification - 1.5) < 0.001, "a registered pane adopts the current factor")
                #expect(controller.zoomablePaneCount == 1)
                controller.setLevel(1.25)
                #expect(abs(first.magnification - 1.25) < 0.001, "registered panes follow later zoom changes")
                controller.register(second)
                #expect(abs(second.magnification - 1.25) < 0.001, "later registration inherits the current factor")
                #expect(abs(first.magnification - 1.25) < 0.001)
                #expect(controller.zoomablePaneCount == 2)
                controller.register(first)
                #expect(controller.zoomablePaneCount == 2, "registering a pane twice does not duplicate it")
                controller.unregister(second)
                #expect(controller.zoomablePaneCount == 1)
                controller.unregister(first)
                #expect(controller.zoomablePaneCount == 0)
            }
        }

        @Test("Pinch completion") private static func testPinchCompletion() {
            withFreshController { controller, _, _ in
                let first = makeScrollView()
                let second = makeScrollView()
                controller.setLevel(1.0)
                controller.register(first)
                controller.register(second)
                first.magnification = 1.25
                NotificationCenter.default.post(name: NSScrollView.didEndLiveMagnifyNotification, object: first)
                if abs(controller.level - 1.25) >= 0.0001 {
                    settle(0.05)
                }
                #expect(abs(controller.level - 1.25) < 0.0001, "the pinch result becomes the shared factor")
                #expect(controller.percent == 125)
                #expect(abs(first.magnification - 1.25) < 0.001)
                #expect(abs(second.magnification - 1.25) < 0.001, "the other registered pane follows the pinch result")
            }
        }

        @Test("Repository window reflows when zoom changes") private static func testRepositoryWindowReflow() {
            withFreshController { controller, _, _ in
                let appHost = ApplicationHostViewController(launch: .dashboard)
                let hosting = NSHostingView(rootView: TestHostWrapper(controller: appHost))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = hosting
                defer { window.close() }
                appHost.view.layoutSubtreeIfNeeded()
                settle(0.2)
                guard let dashboard = appHost.activeController?.view,
                      let document = appHost.contentScrollView.documentView else {
                    Issue.record("dashboard did not load")
                    return
                }
                controller.setLevel(1.5)
                controller.registerContentScrollView(appHost.contentScrollView)
                settle()
                let viewport = appHost.contentScrollView.contentSize
                #expect(viewport.width > 100, "the window content view is sized")
                #expect(abs(appHost.contentScrollView.magnification - 1.5) < 0.001, "the window content is magnified")
                #expect(abs(document.frame.width - viewport.width / 1.5) < 1, "the document is laid out at viewport / zoom")
                #expect(abs(dashboard.frame.width - document.frame.width) < 1, "the dashboard reflows to fill the document")
                #expect(abs(dashboard.frame.height - document.frame.height) < 1)

                // The reported bug: after changing zoom the content only filled
                // the window after a manual resize. It must reflow immediately.
                controller.setLevel(0.75)
                settle()
                #expect(abs(appHost.contentScrollView.magnification - 0.75) < 0.001)
                #expect(abs(document.frame.width - appHost.contentScrollView.contentSize.width / 0.75) < 1)
                #expect(abs(dashboard.frame.width - document.frame.width) < 1, "zooming out reflows without a window resize")
                #expect(abs(dashboard.frame.height - document.frame.height) < 1)
            }
        }

        @Test("Dialogs follow the zoom level") private static func testDialogZoom() {
            withFreshController { controller, _, _ in
                let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
                let child = NSView()
                child.translatesAutoresizingMaskIntoConstraints = false
                content.addSubview(child)
                NSLayoutConstraint.activate([
                    child.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                    child.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                    child.topAnchor.constraint(equalTo: content.topAnchor),
                    child.bottomAnchor.constraint(equalTo: content.bottomAnchor)
                ])
                let dialogController = NSViewController(nibName: nil, bundle: nil)
                dialogController.view = content
                let window = NSWindow(contentViewController: dialogController)
                window.styleMask = [.titled, .closable, .resizable]
                window.setContentSize(NSSize(width: 420, height: 320))
                window.orderFront(nil)
                defer { window.close() }
                settle()
                controller.setLevel(1.5)
                controller.zoomWindow(window)
                settle()

                #expect(controller.zoomedDialogWindowCount == 1, "the dialog is registered for zoom")
                #expect(window.contentViewController === dialogController, "the dialog content controller is preserved")
                guard let scroll = firstScrollView(in: window.contentView),
                      let document = scroll.documentView else {
                    Issue.record("dialog content was not wrapped in a magnifying scroll view")
                    return
                }
                #expect(document.subviews.contains(content), "the original dialog content becomes the scroll document")
                #expect(abs(document.frame.width - scroll.contentSize.width / 1.5) < 1, "the dialog content lays out at viewport / zoom")
                #expect(abs(child.frame.width - document.frame.width) < 1, "the dialog hierarchy reflows")
                #expect(abs(scroll.magnification - 1.5) < 0.001, "the dialog content is magnified")
                let scale = document.convert(NSSize(width: 100, height: 100), to: nil)
                #expect(abs(scale.width - 150) < 1, "dialog controls render 1.5x")
                #expect(abs(window.contentLayoutRect.width - 630) < 2, "the dialog window grows with the zoom")
                #expect(abs(window.contentLayoutRect.height - 480) < 2)

                controller.setLevel(0.75)
                settle()
                #expect(abs(document.frame.width - scroll.contentSize.width / 0.75) < 1, "later zoom changes reflow the dialog")
                #expect(abs(child.frame.width - document.frame.width) < 1)
                #expect(abs(window.contentLayoutRect.width - 420) < 2, "zooming out returns the dialog to its design size")

                controller.resetZoom()
                settle()
                #expect(abs(scroll.magnification - 1) < 0.001)
                #expect(abs(document.frame.width - scroll.contentSize.width) < 1, "reset restores the dialog")
                #expect(abs(window.contentLayoutRect.width - 420) < 2)
            }
        }

        @Test("Dialogs larger than the screen zoom only as far as they fit") private static func testDialogFitsScreen() {
            withFreshController { controller, _, _ in
                guard let screen = NSScreen.main else { return }
                // A dialog that nearly fills the screen cannot grow by 150%.
                let natural = NSSize(width: floor(screen.visibleFrame.width * 0.8), height: floor(screen.visibleFrame.height * 0.8))
                let content = NSView(frame: NSRect(origin: .zero, size: natural))
                let dialogController = NSViewController(nibName: nil, bundle: nil)
                dialogController.view = content
                let window = NSWindow(contentViewController: dialogController)
                window.styleMask = [.titled, .closable, .resizable]
                window.isReleasedWhenClosed = false
                window.setContentSize(natural)
                window.setFrameOrigin(screen.visibleFrame.origin)
                window.orderFront(nil)
                defer { window.close() }
                settle()
                controller.setLevel(1.5)
                controller.zoomWindow(window)
                settle()
                guard let scroll = firstScrollView(in: window.contentView), let document = scroll.documentView else {
                    Issue.record("dialog content was not wrapped")
                    return
                }
                #expect(window.frame.width <= screen.visibleFrame.width + 1 && window.frame.height <= screen.visibleFrame.height + 1,
                        "the zoomed dialog stays on screen")
                #expect(scroll.magnification < 1.5 - 0.01 && scroll.magnification >= 1, "the dialog magnifies only as far as it fits")
                #expect(document.frame.width >= natural.width - 1 && document.frame.height >= natural.height - 1,
                        "the dialog layout is never squeezed below its design size \(document.frame.size) vs \(natural)")
                let unzoomed = controller.unzoomed(window.contentLayoutRect.size, in: window)
                #expect(abs(unzoomed.width - natural.width) < 2 && abs(unzoomed.height - natural.height) < 2,
                        "persisted geometry uses the dialog's own scale")
            }
        }

        @Test("Wrapping a dialog keeps its keyboard focus") private static func testDialogKeepsFocus() {
            withFreshController { controller, _, _ in
                let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
                let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
                content.addSubview(field)
                let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = content
                window.makeKeyAndOrderFront(nil)
                defer { window.close() }
                window.makeFirstResponder(field)
                settle()
                controller.setLevel(1.25)
                controller.zoomWindow(window)
                settle()
                #expect(controller.zoomedDialogWindowCount == 1)
                let editor = window.firstResponder as? NSTextView
                #expect(editor?.isFieldEditor == true && editor?.delegate as? NSTextField === field,
                        "the focused field is still being edited after the content moved into the zoom wrapper")
            }
        }

        @Test("Windows that never become key are not wrapped") private static func testNonKeyWindowsAreNotWrapped() {
            final class BackdropWindow: NSWindow {
                override var canBecomeKey: Bool { false }
            }
            withFreshController { controller, _, _ in
                let window = BackdropWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                            styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
                window.contentView = content
                window.orderFront(nil)
                defer { window.close() }
                controller.setLevel(1.25)
                controller.zoomWindow(window)
                #expect(controller.zoomedDialogWindowCount == 0, "helper windows such as sheet backdrops are left alone")
                #expect(window.contentView === content)
            }
        }

        @Test("A pane without a window is not magnified") private static func testDetachedPaneStaysUnmagnified() {
            withFreshController { controller, _, _ in
                controller.setLevel(1.5)
                let pane = makeScrollView(inWindow: false)
                controller.register(pane)
                settle()
                #expect(abs(pane.magnification - 1) < 0.001, "a pane attached to the zoomed window later must not be zoomed twice")
            }
        }

        @Test("Dialogs that resize themselves keep their zoom") private static func testProgrammaticDialogResize() {
            withFreshController { controller, _, _ in
                let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
                let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = content
                window.orderFront(nil)
                defer { window.close() }
                controller.setLevel(1.25)
                controller.zoomWindow(window)
                settle()
                #expect(abs(window.contentLayoutRect.width - 500) < 2)
                // Dialog code that does not know about the zoom sizes itself in design points.
                window.setContentSize(NSSize(width: 480, height: 320))
                settle()
                #expect(abs(window.contentLayoutRect.width - 600) < 2 && abs(window.contentLayoutRect.height - 400) < 2,
                        "a programmatic resize is a new design size, grown by the zoom \(window.contentLayoutRect.size)")
                #expect(abs(controller.unzoomed(window.contentLayoutRect.size, in: window).width - 480) < 2)
                // A design minimum set by the dialog is honoured at the zoomed size.
                window.contentMinSize = NSSize(width: 520, height: 340)
                controller.dialogGeometryDidChange(window)
                settle()
                #expect(window.contentLayoutRect.width >= 650 - 2 && window.contentMinSize.width >= 650 - 2,
                        "the dialog's own minimum is scaled with the zoom")
            }
        }

        @Test("Reused dialogs are wrapped again without compounding the zoom") private static func testReusedDialogRewrap() {
            withFreshController { controller, _, _ in
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
                window.orderFront(nil)
                defer { window.close() }
                controller.setLevel(1.5)
                controller.zoomWindow(window)
                settle()
                #expect(abs(window.contentLayoutRect.width - 600) < 2)
                for _ in 0..<2 {
                    // The dialog installs fresh content, dropping the wrapper.
                    window.contentView = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
                    controller.zoomWindow(window)
                    settle()
                }
                #expect(abs(window.contentLayoutRect.width - 600) < 2, "the zoom is applied once, not per content swap \(window.contentLayoutRect.size)")
                #expect(firstScrollView(in: window.contentView) != nil, "the new content is wrapped")
            }
        }

        @Test("Geometry of windows that do not zoom is left as is") private static func testUnzoomedForPlainWindows() {
            withFreshController { controller, _, _ in
                controller.setLevel(1.5)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let size = controller.unzoomed(NSSize(width: 400, height: 300), in: window)
                #expect(abs(size.width - 400) < 0.5, "a window that is not wrapped is already at its design size")
            }
        }

        @Test("Popover content follows the zoom of its anchor") private static func testMagnifiedPopoverContent() {
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
            let zoomed = ContentZoomController.magnifiedContent(content, scale: 1.25)
            #expect(abs(zoomed.frame.width - 250) < 1 && abs(zoomed.frame.height - 125) < 1, "the popover grows with the zoom")
            #expect(abs(((zoomed as? NSScrollView)?.magnification ?? 0) - 1.25) < 0.001, "the content is magnified, not relaid out")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
            window.contentView?.addSubview(anchor)
            #expect(abs(ContentZoomController.displayScale(of: anchor) - 1) < 0.001, "an unzoomed anchor reports 100%")
        }

        @Test("Sheet dialogs follow the zoom level") private static func testSheetDialogZoom() {
            withFreshController { controller, _, _ in
                let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                parent.isReleasedWhenClosed = false
                parent.center()
                parent.orderFront(nil)
                defer { parent.close() }
                let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 260))
                let sheetController = NSViewController(nibName: nil, bundle: nil)
                sheetController.view = content
                let sheet = NSWindow(contentViewController: sheetController)
                sheet.styleMask = [.titled]
                sheet.setContentSize(NSSize(width: 400, height: 260))
                parent.beginSheet(sheet)
                settle(0.2)
                controller.setLevel(1.5)
                controller.zoomWindow(sheet)
                settle()
                #expect(controller.zoomedDialogWindowCount == 1, "the sheet is registered for zoom")
                #expect(parent.attachedSheet === sheet, "the sheet stays attached")
                guard let scroll = firstScrollView(in: sheet.contentView), let document = scroll.documentView else {
                    Issue.record("sheet content was not wrapped")
                    parent.endSheet(sheet)
                    return
                }
                #expect(document.subviews.contains(content))
                #expect(abs(document.frame.width - scroll.contentSize.width / 1.5) < 1, "the sheet content reflows")
                #expect(abs(scroll.magnification - 1.5) < 0.001)
                #expect(abs(sheet.contentLayoutRect.width - 600) < 2, "the sheet grows with the zoom")
                parent.endSheet(sheet)
            }
        }

        @Test("Panes inside a zoomed dialog are not magnified twice") private static func testDialogPanesStayUnmagnified() {
            withFreshController { controller, _, _ in
                let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
                let pane = makeScrollView()
                pane.frame = NSRect(x: 10, y: 10, width: 200, height: 150)
                content.addSubview(pane)
                let dialogController = NSViewController(nibName: nil, bundle: nil)
                dialogController.view = content
                let window = NSWindow(contentViewController: dialogController)
                window.styleMask = [.titled, .closable]
                window.setContentSize(NSSize(width: 420, height: 320))
                window.orderFront(nil)
                defer { window.close() }
                controller.setLevel(1.5)
                controller.register(pane)
                settle()
                #expect(abs(pane.magnification - 1.5) < 0.001)
                controller.zoomWindow(window)
                settle()
                #expect(!pane.allowsMagnification, "the dialog wrapper owns the zoom")
                #expect(abs(pane.magnification - 1) < 0.001, "the pane inside the dialog is not magnified twice")
                controller.setLevel(1.25)
                settle()
                #expect(abs(pane.magnification - 1) < 0.001)
            }
        }

        @Test("Plain windows follow the zoom level") private static func testPlainWindowZoom() {
            withFreshController { controller, _, _ in
                let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = content
                defer { window.close() }
                controller.setLevel(1.5)
                controller.zoomWindow(window)
                settle()
                #expect(controller.zoomedDialogWindowCount == 1)
                guard let scroll = firstScrollView(in: window.contentView), let document = scroll.documentView else {
                    Issue.record("plain window content was not wrapped")
                    return
                }
                #expect(document.subviews.contains(content))
                #expect(abs(scroll.magnification - 1.5) < 0.001)
                #expect(abs(window.contentLayoutRect.width - 450) < 2, "plain windows grow with the zoom")
            }
        }

        @Test("Persisted dialog geometry is stored unzoomed") private static func testUnzoomedGeometry() {
            withFreshController { controller, _, _ in
                controller.setLevel(1.5)
                let zoomed = controller.unzoomed(NSSize(width: 630, height: 480))
                #expect(abs(zoomed.width - 420) < 0.5 && abs(zoomed.height - 320) < 0.5, "geometry saved while zoomed is divided by the factor")
                controller.setLevel(0.75)
                let unzoomed = controller.unzoomed(NSSize(width: 420, height: 320))
                #expect(abs(unzoomed.width - 420) < 0.5, "zoom-out geometry is unchanged because dialogs do not shrink below their design size")
            }
        }

        @Test("Zoomed dialogs do not autosave their scaled frame") private static func testDialogAutosaveProtection() {
            withFreshController { controller, _, _ in
                let autosaveName = "ContentZoomTests.\(UUID().uuidString)"
                defer { UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(autosaveName)") }
                let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = content
                window.setFrameAutosaveName(autosaveName)
                defer { window.close() }
                controller.setLevel(1.5)
                controller.zoomWindow(window)
                settle()
                #expect(window.frameAutosaveName.isEmpty, "the scaled frame is not autosaved")
                controller.resetZoom()
                settle()
                #expect(window.frameAutosaveName == autosaveName, "the autosave name returns at 100%")
            }
        }

        @Test("The repository window is not wrapped as a dialog") private static func testRepositoryWindowIsNotADialog() {
            withFreshController { controller, _, _ in
                let setup = makeContentSetup()
                defer { setup.window.close() }
                controller.registerContentScrollView(setup.scrollView)
                controller.setLevel(1.5)
                settle()
                controller.zoomWindow(setup.window)
                settle()
                #expect(controller.zoomedDialogWindowCount == 0, "the repository window is handled by its content scroll view")
                #expect(setup.window.contentView === setup.scrollView)
            }
        }

        @Test("Alerts follow the zoom level") private static func testAlertsFollowZoom() {
            withFreshController { controller, _, _ in
                let alert = NSAlert()
                alert.messageText = "Zoom test"
                alert.addButton(withTitle: "OK")
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
                alert.accessoryView = field
                alert.layout()
                let alertWindow = alert.window
                defer { alertWindow.close() }
                let natural = alertWindow.contentLayoutRect.size
                controller.setLevel(1.5)
                controller.zoomWindow(alertWindow)
                settle()
                #expect(controller.zoomedDialogWindowCount == 1, "alerts, including ones with form fields, follow the zoom")
                #expect(abs(alertWindow.contentLayoutRect.width - natural.width * 1.5) < 2, "the alert grows with the zoom")
                #expect(field.window === alertWindow, "the accessory view stays in the alert")
                #expect(abs(field.convert(NSSize(width: 100, height: 100), to: nil).width - 150) < 1, "alert controls render 1.5x")
            }
        }

        // MARK: - Helpers

        private struct ContentSetup {
            let window: NSWindow
            let scrollView: NSScrollView
            let document: NSView
            let container: NSView
        }

        /// Mimics the repository window: a scroll view whose document view holds
        /// an Auto Layout hierarchy that must reflow with the document size.
        private static func makeContentSetup() -> ContentSetup {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            window.contentView = scrollView
            let document = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
            scrollView.documentView = document
            let container = NSView(frame: .zero)
            container.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: document.trailingAnchor),
                container.topAnchor.constraint(equalTo: document.topAnchor),
                container.bottomAnchor.constraint(equalTo: document.bottomAnchor)
            ])
            window.orderFront(nil)
            return ContentSetup(window: window, scrollView: scrollView, document: document, container: container)
        }

        /// Windows that host test panes; panes only zoom themselves while they
        /// are in a window that does not follow the zoom as a whole.
        nonisolated(unsafe) private static var paneWindows: [NSWindow] = []

        private static func makeScrollView(inWindow: Bool = true) -> NSScrollView {
            let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 640, height: 880))
            table.rowHeight = 22
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Zoom.Pane"))
            column.width = 320
            table.addTableColumn(column)
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
            scrollView.documentView = table
            if inWindow {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView?.addSubview(scrollView)
                paneWindows.append(window)
            }
            return scrollView
        }


        @Test("Checkbox and radio titles survive pixel snapping in zoomed dialogs") private static func testToggleTitlesSurviveZoomSnapping() {
            let titles = ["Keep dialog open", "Show password input", "Force with lease", "Squash", "Manage remotes", "Fetch all tags",
                          "Sign-off", "No fast-forward", "Add to .gitignore", "Solve conflicts", "Recursive submodules", "Merge"]
            for level in [1.1, 1.25, 1.38, 1.5] as [CGFloat] {
                withFreshController { controller, _, _ in
                    controller.setLevel(level)
                    let rows = NSStackView()
                    rows.orientation = .vertical
                    rows.alignment = .leading
                    let checkboxes = titles.map { PixelSnapTolerantButton(checkboxWithTitle: $0, target: nil, action: nil) }
                    let radios = titles.map { PixelSnapTolerantButton(radioButtonWithTitle: $0, target: nil, action: nil) }
                    for group in [checkboxes, radios] {
                        let row = NSStackView(views: group)
                        row.orientation = .horizontal
                        row.spacing = 7
                        rows.addArrangedSubview(row)
                    }
                    let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
                    rows.translatesAutoresizingMaskIntoConstraints = false
                    content.addSubview(rows)
                    NSLayoutConstraint.activate([
                        rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 13),
                        rows.topAnchor.constraint(equalTo: content.topAnchor, constant: 11)
                    ])
                    let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = content
                    window.orderFront(nil)
                    defer { window.close() }
                    controller.zoomWindow(window)
                    settle(0.2)
                    window.contentView?.layoutSubtreeIfNeeded()
                    for button in checkboxes + radios {
                        let titleWidth = (button.cell as! NSButtonCell).titleRect(forBounds: button.bounds).width
                        #expect(titleWidth + 0.01 >= button.attributedTitle.size().width,
                                "'\(button.title)' keeps its full title at \(Int(level * 100))%: frame \(button.frame.width), title rect \(titleWidth)")
                    }
                }
            }
        }

        @Test("Process dialog keeps the Keep dialog open title at every zoom level") private static func testProcessDialogKeepOpenTitle() async throws {
            let root = try RepositoryWorkflowTests.temporaryDirectory("zoom-process-footer")
            defer { try? FileManager.default.removeItem(at: root) }
            let repository = root.appendingPathComponent("repository")
            let remote = root.appendingPathComponent("remote.git")
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            _ = try RepositoryWorkflowTests.git(["init", "-q", "-b", "main"], in: repository)
            _ = try RepositoryWorkflowTests.git(["init", "-q", "--bare", remote.path], in: root)
            _ = try RepositoryWorkflowTests.git(["remote", "add", "origin", remote.path], in: repository)
            let source = GitRepositoryModule(repositoryURL: repository)
            let preferences = AppSettingsStore.shared.pullPreferences
            var keepOpen = preferences
            keepOpen.closeProcessOnSuccess = false
            AppSettingsStore.shared.savePullPreferences(keepOpen)
            let zoom = ContentZoomController.shared
            let savedLevel = zoom.level
            defer {
                AppSettingsStore.shared.savePullPreferences(preferences)
                zoom.setLevel(savedLevel)
            }
            for level in ContentZoomController.Metrics.levels {
                zoom.setLevel(level)
                let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                owner.isReleasedWhenClosed = false
                owner.makeKeyAndOrderFront(nil)
                defer { owner.close() }
                let run = Task { await PullProcessDialog.runPrune(remote: "origin", source: source, parent: owner) }
                try await RepositoryWorkflowTests.waitUntil("process sheet") { owner.attachedSheet != nil }
                let sheet = try #require(owner.attachedSheet)
                func button(_ title: String) -> NSButton? {
                    DialogBehaviorTests.allSubviews(sheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title }
                }
                try await RepositoryWorkflowTests.waitUntil("process completed") { button("OK")?.isEnabled == true }
                zoom.zoomWindow(sheet)
                settle(0.2)
                sheet.contentView?.layoutSubtreeIfNeeded()
                let checkbox = try #require(button("Keep dialog open"))
                let titleWidth = (checkbox.cell as! NSButtonCell).titleRect(forBounds: checkbox.bounds).width
                #expect(titleWidth + 0.01 >= checkbox.attributedTitle.size().width,
                        "Keep dialog open is not truncated at \(Int(level * 100))%: frame \(checkbox.frame.width), title rect \(titleWidth)")
                button("OK")?.performClick(nil)
                _ = await run.value
            }
        }


        @Test("Tooltips follow the zoom of the view they describe") private static func testZoomedToolTips() {
            withFreshController { controller, _, _ in
                let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
                let plain = NSButton(title: "Fetch", target: nil, action: nil)
                plain.frame = NSRect(x: 10, y: 10, width: 120, height: 30)
                plain.toolTip = "Fetch from the remote"
                let segmented = NSSegmentedControl(labels: ["Stash", "More"], trackingMode: .momentary, target: nil, action: nil)
                segmented.frame = NSRect(x: 150, y: 10, width: 200, height: 30)
                segmented.setToolTip("Manage stashes", forSegment: 0)
                segmented.setToolTip("Stash actions", forSegment: 1)
                let lanes = LaneToolTipView(frame: NSRect(x: 10, y: 60, width: 160, height: 40))
                let hidden = NSView(frame: NSRect(x: 200, y: 60, width: 100, height: 40))
                hidden.toolTip = "Not shown"
                hidden.isHidden = true
                for view in [plain, segmented, lanes, hidden] as [NSView] { content.addSubview(view) }
                let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = content
                window.orderFront(nil)
                defer { window.close() }
                let tips = ZoomedToolTipController()
                defer { tips.hide() }
                func screenPoint(_ view: NSView, _ x: CGFloat? = nil) -> NSPoint {
                    let local = NSPoint(x: x ?? view.bounds.midX, y: view.bounds.midY)
                    return window.convertPoint(toScreen: view.convert(local, to: nil))
                }
                #expect(tips.hit(in: window, atScreenPoint: screenPoint(plain))?.text == "Fetch from the remote")
                #expect(abs((tips.hit(in: window, atScreenPoint: screenPoint(plain))?.scale ?? 0) - 1) < 0.001, "unzoomed windows use 100%")
                controller.setLevel(1.5)
                controller.zoomWindow(window)
                settle(0.2)
                let hit = try? #require(tips.hit(in: window, atScreenPoint: screenPoint(plain)))
                #expect(hit?.text == "Fetch from the remote")
                #expect(abs((hit?.scale ?? 0) - 1.5) < 0.001, "the tooltip scale is the view's zoom")
                #expect(tips.hit(in: window, atScreenPoint: screenPoint(segmented, 40))?.text == "Manage stashes", "segment tooltips are per segment")
                #expect(tips.hit(in: window, atScreenPoint: screenPoint(segmented, 160))?.text == "Stash actions")
                #expect(tips.hit(in: window, atScreenPoint: screenPoint(lanes, 10))?.text == "lane 0", "custom sources describe the point")
                #expect(tips.hit(in: window, atScreenPoint: screenPoint(lanes, 30))?.text == "lane 1")
                #expect(tips.hit(in: window, atScreenPoint: screenPoint(hidden)) == nil, "hidden views show no tooltip")
                guard let hit else { return }
                tips.show(hit, atScreenPoint: screenPoint(plain))
                #expect(tips.panel?.isVisible == true)
                #expect(abs((tips.label?.font?.pointSize ?? 0) - ZoomedToolTipController.Metrics.baseFontSize * 1.5) < 0.01,
                        "tooltip text is drawn at the zoomed size")
                let unzoomedWidth = (NSAttributedString(string: hit.text, attributes: [.font: NSFont.toolTipsFont(ofSize: ZoomedToolTipController.Metrics.baseFontSize)]).size().width)
                #expect((tips.panel?.frame.width ?? 0) > unzoomedWidth * 1.4, "the tooltip window grows with the zoom")
                controller.setLevel(0.75)
                settle(0.2)
                let small = try? #require(tips.hit(in: window, atScreenPoint: screenPoint(plain)))
                #expect(abs((small?.scale ?? 0) - 0.75) < 0.001, "tooltips also shrink below 100%")
                tips.hide()
                #expect(tips.panel?.isVisible == false)
            }
        }

        @Test("Menus follow the zoom of the control they open from") private static func testZoomedMenus() {
            withFreshController { controller, _, _ in
                let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
                let popUp = NSPopUpButton(frame: NSRect(x: 10, y: 10, width: 120, height: 26), pullsDown: true)
                popUp.addItem(withTitle: "")
                let icon = NSImage(size: NSSize(width: 16, height: 16))
                popUp.itemArray[0].image = icon
                popUp.addItem(withTitle: "Show untracked files")
                popUp.itemArray[1].image = icon
                let hidden = NSMenuItem(title: "hidden-branch", action: nil, keyEquivalent: "")
                hidden.attributedTitle = NSAttributedString(string: "hidden-branch", attributes: [.foregroundColor: NSColor.secondaryLabelColor])
                popUp.menu?.addItem(hidden)
                let toolbar = NSMenuItem(title: "Toolbar", action: nil, keyEquivalent: "")
                toolbar.submenu = NSMenu(title: "Toolbar")
                toolbar.submenu?.addItem(withTitle: "Show labels", action: nil, keyEquivalent: "")
                popUp.menu?.addItem(toolbar)
                let anchor = NSView(frame: NSRect(x: 200, y: 10, width: 100, height: 40))
                content.addSubview(popUp)
                content.addSubview(anchor)
                let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = content
                window.orderFront(nil)
                defer { window.close() }
                let menus = ZoomedMenuController()
                menus.install()
                defer { menus.uninstall() }
                guard let menu = popUp.menu else {
                    Issue.record("pop-up button has no menu")
                    return
                }
                let designSize = (menu.font ?? NSFont.menuFont(ofSize: 0)).pointSize

                NotificationCenter.default.post(name: NSPopUpButton.willPopUpNotification, object: popUp)
                #expect(menus.activeScale == nil, "menus of an unzoomed window stay at 100%")
                #expect(abs((menu.font?.pointSize ?? 0) - designSize) < 0.01)

                controller.setLevel(1.5)
                controller.zoomWindow(window)
                settle(0.2)
                NotificationCenter.default.post(name: NSPopUpButton.willPopUpNotification, object: popUp)
                #expect(abs((menus.activeScale ?? 0) - 1.5) < 0.001, "a pop-up menu opens at the zoom of its button")
                #expect(abs((menu.font?.pointSize ?? 0) - designSize * 1.5) < 0.01, "menu text is drawn at the zoomed size")
                #expect(abs((toolbar.submenu?.font?.pointSize ?? 0) - designSize * 1.5) < 0.01, "submenus follow the zoom")
                #expect(abs((popUp.itemArray[1].image?.size.width ?? 0) - 24) < 0.01, "item images grow with the zoom")
                #expect(abs(icon.size.width - 16) < 0.01, "shared images are not resized in place")
                #expect(popUp.itemArray[0].image === icon, "the pull-down button's face keeps its size")
                let hiddenFont = hidden.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                #expect(abs((hiddenFont?.pointSize ?? 0) - designSize * 1.5) < 0.01, "attributed titles follow the zoom")
                let late = NSMenuItem(title: "main", action: nil, keyEquivalent: "")
                late.image = icon
                menu.addItem(late)
                #expect(abs((late.image?.size.width ?? 0) - 24) < 0.01, "items added while the menu opens are scaled too")

                NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
                #expect(menus.activeScale == nil, "closing the menu ends the zoom session")
                #expect(abs((menu.font?.pointSize ?? 0) - designSize) < 0.01, "the design font is restored")
                #expect(popUp.itemArray[1].image === icon && late.image === icon, "the design images are restored")
                #expect(hidden.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) == nil, "attributed titles are restored")

                let context = NSMenu(title: "Context")
                context.addItem(withTitle: "Copy commit hash", action: nil, keyEquivalent: "")
                let contextSize = (context.font ?? NSFont.menuFont(ofSize: 0)).pointSize
                ZoomedMenuController.installContextMenuHook()
                let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                if let event { anchor.willOpenMenu(context, with: event) }
                #expect(abs((context.font?.pointSize ?? 0) - contextSize * 1.5) < 0.01, "context menus open at the zoom of their view")
                ZoomedMenuController.shared.finish(context)
                #expect(abs((context.font?.pointSize ?? 0) - contextSize) < 0.01)

                controller.setLevel(0.75)
                settle(0.2)
                menus.prepare(menu, for: popUp, keepsFirstItem: true)
                #expect(abs((menu.font?.pointSize ?? 0) - designSize * 0.75) < 0.01, "menus also shrink below 100%")
                menus.restore()
                #expect(abs((menu.font?.pointSize ?? 0) - designSize) < 0.01)
            }
        }

        @Test("Combo box drop-down lists follow the zoom of their combo box") private static func testZoomedComboBoxLists() {
            withFreshController { controller, _, _ in
                let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
                let comboBox = NSComboBox(frame: NSRect(x: 20, y: 180, width: 200, height: 26))
                comboBox.addItems(withObjectValues: (1...30).map { "branch-\($0)" })
                comboBox.numberOfVisibleItems = 5
                content.addSubview(comboBox)
                let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = content
                window.makeKeyAndOrderFront(nil)
                defer { window.close() }
                let menus = ZoomedMenuController()
                menus.install()
                defer { menus.uninstall() }
                controller.setLevel(1.5)
                controller.zoomWindow(window)
                settle(0.2)
                window.makeFirstResponder(comboBox)
                comboBox.cell?.perform(NSSelectorFromString("popUp:"), with: nil)
                settle(0.3)
                defer { comboBox.cell?.perform(NSSelectorFromString("dismissPopUp:"), with: nil) }
                guard let list = ZoomedMenuController.dropDownList(of: comboBox) else {
                    Issue.record("the combo box did not open its drop-down list")
                    return
                }
                #expect(abs(list.magnification - 1.5) < 0.001, "the drop-down list is magnified like its combo box")
                let table = list.documentView as? NSTableView
                #expect(abs((table?.frame.width ?? 0) - list.contentView.bounds.width) < 1, "rows fill the list without scrolling sideways")
                #expect(abs(list.contentView.bounds.minX) < 0.5 && abs(list.contentView.bounds.minY) < 0.5, "the list opens scrolled to its first row")
                let rowHeight = (table?.rowHeight ?? 0) + (table?.intercellSpacing.height ?? 0)
                let visibleRows = list.contentView.bounds.height / max(rowHeight, 1)
                #expect(visibleRows >= 4 && visibleRows <= 7, "the zoomed list shows about as many rows as at 100% (\(visibleRows))")
                ZoomedMenuController.magnify(list, by: 1)
                #expect(abs(list.magnification - 1) < 0.001, "a reused drop-down list returns to 100%")
            }
        }

        @Test("System tooltips are replaced") private static func testSystemToolTipSuppression() {
            ZoomedToolTipController.suppressSystemToolTips()
            #expect(UserDefaults.standard.integer(forKey: "NSInitialToolTipDelay") == ZoomedToolTipController.Metrics.systemDelaySuppression,
                    "AppKit's own tooltip delay is pushed out so only the zoomed tooltips appear")
        }


        @Test("Tooltips of table and outline cells are found") private static func testTableCellToolTips() {
            let fixture = TableToolTipFixture()
            let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Message")))
            table.tableColumns[0].width = 280
            table.dataSource = fixture
            table.delegate = fixture
            let scroll = NSScrollView(frame: NSRect(x: 10, y: 10, width: 300, height: 200))
            scroll.documentView = table
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 240))
            content.addSubview(scroll)
            let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = content
            window.orderFront(nil)
            defer { window.close() }
            table.reloadData()
            table.layoutSubtreeIfNeeded()
            settle(0.2)
            let rowRect = table.rect(ofRow: 1)
            let point = window.convertPoint(toScreen: table.convert(NSPoint(x: rowRect.midX, y: rowRect.midY), to: nil))
            #expect(ZoomedToolTipController().hit(in: window, atScreenPoint: point)?.text == "Commit 1 details",
                    "a table cell's tooltip is found even though the table answers the hit test itself")
        }

        private static func firstScrollView(in view: NSView?) -> NSScrollView? {
            guard let view else { return nil }
            if let scrollView = view as? NSScrollView { return scrollView }
            for subview in view.subviews {
                if let found = firstScrollView(in: subview) { return found }
            }
            return nil
        }

        private static func settle(_ seconds: TimeInterval = 0.1) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
        }

        private static func withFreshController(_ body: (ContentZoomController, AppSettingsStore, UserDefaults) -> Void) {
            let suite = "GitExtensionsMac.ContentZoomTests.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else {
                Issue.record("Could not create defaults suite")
                return
            }
            defaults.removePersistentDomain(forName: suite)
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = AppSettingsStore(defaults: defaults)
            body(ContentZoomController(store: store), store, defaults)
        }
    }
}

@MainActor
private final class TableToolTipFixture: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { 5 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "Commit \(row)")
        label.frame = NSRect(x: 2, y: 0, width: 200, height: 17)
        cell.addSubview(label)
        cell.textField = label
        cell.toolTip = "Commit \(row) details"
        return cell
    }
}

@MainActor
private final class LaneToolTipView: NSView, ZoomedToolTipSource {
    func zoomedToolTip(at point: NSPoint) -> String? { "lane \(Int(point.x / 20))" }
}

private struct TestHostWrapper: NSViewControllerRepresentable {
    let controller: ApplicationHostViewController
    func makeNSViewController(context: Context) -> ApplicationHostViewController { controller }
    func updateNSViewController(_ controller: ApplicationHostViewController, context: Context) {}
}

typealias ContentZoomTests = UIIntegrationTests.ContentZoomTests
