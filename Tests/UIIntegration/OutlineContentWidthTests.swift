import AppKit
import Testing

@testable import GitUI

extension UIIntegrationTests {
    @Suite("Outline content width")
    @MainActor
    enum OutlineContentWidthTests {
        final class Source: NSObject, NSOutlineViewDataSource {
            var items: [String] = []
            func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? items.count : 0 }
            func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { items[index] }
            func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
        }

        private static func settle() async throws { try await Task.sleep(for: .milliseconds(80)) }

        @Test("Scrollable outlines keep full row width instead of shrinking to the viewport")
        static func keepsContentWidth() async throws {
            let source = Source()
            let outline = NSOutlineView()
            let column = NSTableColumn(identifier: .init("File"))
            column.width = 330
            outline.addTableColumn(column)
            outline.outlineTableColumn = column
            outline.dataSource = source
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            scroll.documentView = outline
            scroll.hasHorizontalScroller = true
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            defer { window.close() }
            let font = NSFont.systemFont(ofSize: 11)
            var keepsFullWidth = true
            let fitter = OutlineContentWidthFitter(outline: outline, chrome: 25) { ($0 as? String).map { ($0, font) } }
            fitter.fitsContent = { keepsFullWidth }
            outline.reloadData()
            fitter.setNeedsUpdate()
            try await settle()
            #expect(outline.frame.width == scroll.contentView.bounds.width, "empty list fills the viewport")
            window.setContentSize(NSSize(width: 300, height: 200))
            try await settle()
            #expect(outline.frame.width == scroll.contentView.bounds.width, "narrowing does not leave a stale wider column")

            let long = "src/very/deeply/nested/directory/AnExtremelyLongFileNameThatMustRemainScrollable.swift"
            source.items = [long, "short.txt"]
            outline.reloadData()
            fitter.setNeedsUpdate()
            try await settle()
            let textWidth = ceil((long as NSString).size(withAttributes: [.font: font]).width)
            #expect(column.width >= textWidth + 25, "column keeps the full width of the longest row")
            #expect(outline.frame.width > scroll.contentView.bounds.width, "content is wider than the viewport, so it scrolls horizontally")
            scroll.contentView.scroll(to: NSPoint(x: outline.frame.width - scroll.contentView.bounds.width, y: 0))
            #expect(scroll.contentView.bounds.maxX == outline.frame.width, "horizontal scrolling reaches the end of the row")

            window.setContentSize(NSSize(width: 1200, height: 200))
            try await settle()
            #expect(outline.frame.width == scroll.contentView.bounds.width, "widening fills the viewport again")
            window.setContentSize(NSSize(width: 300, height: 200))
            try await settle()
            #expect(column.width >= textWidth + 25, "narrowing again restores the full content width")

            scroll.scrollerStyle = .legacy
            scroll.autohidesScrollers = true
            scroll.hasVerticalScroller = true
            source.items = (0..<60).map { "File\($0).swift" }
            outline.reloadData()
            fitter.setNeedsUpdate()
            try await settle()
            #expect(scroll.hasVerticalScroller && outline.frame.height > scroll.contentView.bounds.height, "list needs a vertical scrollbar")
            #expect(outline.frame.width <= scroll.contentView.bounds.width + 0.5, "short rows never need a horizontal scrollbar, even next to a legacy vertical scroller: outline \(outline.frame.width) clip \(scroll.contentView.bounds.width)")

            keepsFullWidth = false
            fitter.setNeedsUpdate()
            try await settle()
            #expect(outline.frame.width <= scroll.contentView.bounds.width + 0.5, "truncating path modes fit the visible width")

            for style in [NSTableView.Style.automatic, .inset, .fullWidth, .plain] {
                outline.style = style
                source.items = []
                outline.reloadData()
                fitter.setNeedsUpdate()
                try await settle()
                #expect(outline.frame.width <= scroll.contentView.bounds.width + 0.5, "empty \(style.rawValue)-style list has no horizontal overflow: outline \(outline.frame.width) clip \(scroll.contentView.bounds.width)")
            }
        }
    }
}
